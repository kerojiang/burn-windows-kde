// 仲裁核心：决定某个窗口的某次开/关动画该由哪个特效播放。
//
// 本文件会被注入器整体内联进 19 个特效的 contents/code/main.js，因此：
//   1. 不得出现 import / export（KWin effect 上下文无模块系统）；
//   2. 只能以 function 声明定义，避免依赖模块作用域的提升行为差异；
//   3. 不得引用本文件之外的任何符号（bmwShouldPlay 需自带抽签逻辑，
//      开关态也经第 7 参 enabled 传入，不直接读 KWin 全局）。
//
// 运行模型：同一信号（窗口打开 / 窗口关闭）会被 19 个特效同步依次回调，
// 因此用 window.setData(role, winner) 在它们之间做"先到先得"的唯一抽签 ——
// 第一个执行到的特效负责抽签，后续特效复用同一结果，从而保证只有一个特效
// 认为自己是 winner。打开与关闭使用不同的 role，各自独立随机。

// 黑名单过滤后再取索引：只有先剔除才能保证参与随机的特效被均匀选取。
// 之所以用 indexOf 而非 includes，是因为 effect JS 引擎的内置方法覆盖范围
// 未经实测确认，indexOf 属于必定可用的子集。
function bmwPickWinner(pool, blacklist, rng) {
  const eligible = pool.filter(function (id) {
    return blacklist.indexOf(id) === -1;
  });
  if (eligible.length === 0) {
    // 池为空（全部特效被剔除）→ 不产生 winner → 所有特效都不播放
    return null;
  }
  return eligible[Math.floor(rng() * eligible.length)];
}

// 预览协议：窗口标题形如 "BMW_PREVIEW:<effectId>" 时返回该目标 id，否则 null。
// spec §8「动画预览」：KWin 无 playEffect/previewEffect API（v6.7.5 源码
// org.kde.kwin.Effects.xml:3-42 仅 9 方法、全源码 0 命中、qdbus6 实测一致），
// 只能靠真实窗口开/关事件 + 标题携带目标 id。
// 合法性 = 前缀严格匹配 + id ∈ pool（两者缺一即回落随机，防止用户窗口标题
// 恰好含前缀而误触发）。
// 字符串方法取舍沿用本文件既有约定（见 bmwPickWinner 注释）：indexOf/slice
// 属必定可用子集，不使用 startsWith/includes 等未实测方法。
function bmwPreviewTarget(caption, pool) {
  if (typeof caption !== "string") {
    // fakeWindow 未设 caption、KWin 窗口无标题时为 undefined/null → 不触发
    return null;
  }
  const prefix = "BMW_PREVIEW:";
  if (caption.indexOf(prefix) !== 0) {
    return null;
  }
  // Qt 会把 applicationDisplayName 追加到窗口 title（KCM 实测 caption 为
  // "BMW_PREVIEW:kwin6_effect_fire — 系统设置"，systemsettings 进程
  // setApplicationDisplayName("系统设置") 所致），因此不能 slice 后整串校验，
  // 改为按池成员做前缀匹配；rest 需为 id 边界（空或非 [A-Za-z0-9_]），
  // 保证池 id 互为前缀时（fire / fire_extra）不误配。
  for (let i = 0; i < pool.length; i++) {
    const pid = pool[i];
    if (caption.indexOf(prefix + pid) !== 0) {
      continue;
    }
    const rest = caption.charAt(prefix.length + pid.length);
    if (rest === "" || !/[A-Za-z0-9_]/.test(rest)) {
      return pid;
    }
  }
  // 前缀合法但没有任何池成员命中 → 目标不在池内，非法协议回落随机
  return null;
}

// 返回 true 表示本次由 myEffectId 播放动画。
// 第一个执行的特效抽签并写入 window；后续特效读到已有 winner 后直接比较。
function bmwShouldPlay(window, roleId, myEffectId, pool, blacklist, rng, enabled) {
  // 开关闸：占位特效（总开关）未加载时直接不播放。
  // 用显式 false 比较而非真值判断：调用方漏传 enabled 时保持"播放"方向，
  // 避免漏传导致动画整体失效；关闭方向的正确性由注入产物断言与 e2e 关态用例锁定。
  // 早退必须在读/写 window.data 之前，保证关闭态不产生任何残留 winner。
  if (enabled === false) {
    return false;
  }
  // 预览协议拦截：必须在 eligible 抽签与 winner 复用校验之前 —— 命中时直接
  // 写入目标并返回，不进入随机，也不受 eligible.indexOf(winner) 复用校验约束
  // （否则预览一个已被拉黑/出池的特效会被踢回随机，见 arbiter.test.mjs
  // 「绕过 eligible 校验」用例）。open/close 两个 role 各自命中同一标题，
  // 两段动画都是目标特效。
  const previewTarget = bmwPreviewTarget(window.caption, pool);
  if (previewTarget !== null) {
    window.setData(roleId, previewTarget);
    return previewTarget === myEffectId;
  }
  // 先算出本次真正有资格的集合：既用于抽签，也用于校验已存在的 winner。
  const eligible = pool.filter(function (id) {
    return blacklist.indexOf(id) === -1;
  });
  // KWin 的 window.data() 对未设置 role 的返回值未实测确认，故用宽松比较
  // 同时兼容 null 与 undefined，避免把"未设置"误判为已有 winner。
  let winner = window.data(roleId);
  // 残留 winner 必须重新校验：注入点在上游 `if (effects.hasActiveFullScreenEffect)
  // return;` 之前，winner 抽出后若因该判断提前 return 就没有动画、也就没有
  // animationEnded 触发 bmwCleanup，winner 会留到窗口销毁；期间 --apply-config
  // 只重写文件并 reload 特效，不清除 window 的 role 数据 —— 不校验的话，
  // 被拉黑或已出池的特效仍会继续播放，且不再参与随机。
  if (winner == null || eligible.indexOf(winner) === -1) {
    if (eligible.length === 0) {
      // 空池（全部被剔除）：不写入任何 winner，让后续特效也走到同一条分支
      return false;
    }
    winner = eligible[Math.floor(rng() * eligible.length)];
    window.setData(roleId, winner);
  }
  return winner === myEffectId;
}

// 动画结束后清除该 role 上的 winner，避免同一窗口的下一次事件复用旧结果。
function bmwCleanup(window, roleId) {
  window.setData(roleId, null);
}
