// 仲裁核心：决定某个窗口的某次开/关动画该由哪个特效播放。
//
// 本文件会被注入器整体内联进 19 个特效的 contents/code/main.js，因此：
//   1. 不得出现 import / export（KWin effect 上下文无模块系统）；
//   2. 只能以 function 声明定义，避免依赖模块作用域的提升行为差异；
//   3. 不得引用本文件之外的任何符号（bmwShouldPlay 需自带抽签逻辑）。
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

// 返回 true 表示本次由 myEffectId 播放动画。
// 第一个执行的特效抽签并写入 window；后续特效读到已有 winner 后直接比较。
function bmwShouldPlay(window, roleId, myEffectId, pool, blacklist, rng) {
  // KWin 的 window.data() 对未设置 role 的返回值未实测确认，故用宽松比较
  // 同时兼容 null 与 undefined，避免把"未设置"误判为已有 winner。
  let winner = window.data(roleId);
  if (winner == null) {
    const eligible = pool.filter(function (id) {
      return blacklist.indexOf(id) === -1;
    });
    if (eligible.length === 0) {
      // 空池：不写入任何 winner，让后续特效也走到同一条分支
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
