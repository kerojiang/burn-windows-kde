// 仲裁核心单元测试 —— 使用 node:test 运行：node --test tests/arbiter.test.mjs
//
// 加载方式说明：lib/arbiter.js 最终会被注入进 KWin effect 上下文（无模块系统、
// 无 import/export），因此这里不用 import，而是把源码当作文本求值执行 —— 这同时
// 验证了该文件确实不含模块语法依赖，能被注入器安全内联。
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const src = readFileSync(new URL("../lib/arbiter.js", import.meta.url), "utf8");
const { bmwPickWinner, bmwShouldPlay, bmwCleanup, bmwPreviewTarget } = new Function(
  `${src}\n;return { bmwPickWinner, bmwShouldPlay, bmwCleanup, bmwPreviewTarget };`,
)();

// 构造一个模拟 KWin window 对象：data/setData 存于普通 Map。
// data() 对未设置的 role 返回 null（"无 winner"）。
function fakeWindow() {
  const store = new Map();
  return {
    data: (role) => (store.has(role) ? store.get(role) : null),
    setData: (role, value) => {
      store.set(role, value);
    },
  };
}

// 依次返回给定值的 rng，用于确定性地控制抽签结果。
function sequence(...values) {
  let i = 0;
  return () => values[Math.min(i++, values.length - 1)];
}

const OPEN_ROLE = 424242; // 打开动画的仲裁 role
const CLOSE_ROLE = 424243; // 关闭动画的仲裁 role（与 OPEN_ROLE 隔离）

test("黑名单过滤：被剔除的特效不会当选", () => {
  const winner = bmwPickWinner(["a", "b", "c"], ["b"], () => 0.99);
  assert.notEqual(winner, "b");
});

test("先过滤再取索引：rng=0.5 时从 ['a','c'] 选中 'c' 而非原数组的 'b'", () => {
  assert.equal(bmwPickWinner(["a", "b", "c"], ["b"], () => 0.5), "c");
});

test("先到先得：第二个调用者复用第一个抽的 winner", () => {
  const w = fakeWindow();
  const rng = sequence(0.0, 0.0); // 第一次抽第 1 项
  assert.equal(bmwShouldPlay(w, OPEN_ROLE, "a", ["a", "b"], [], rng), true);
  assert.equal(bmwShouldPlay(w, OPEN_ROLE, "b", ["a", "b"], [], rng), false); // 不再抽签
});

test("open/close role 隔离：关闭时用 424243 重新抽签", () => {
  const w = fakeWindow();
  bmwShouldPlay(w, OPEN_ROLE, "a", ["a", "b"], [], sequence(0.0));
  assert.equal(w.data(CLOSE_ROLE), null); // 424242 的结果不影响 424243
});

test("空池：返回 null，任何特效都不播放", () => {
  const w = fakeWindow();
  assert.equal(bmwPickWinner([], [], () => 0.5), null);
  assert.equal(bmwShouldPlay(w, OPEN_ROLE, "a", [], [], () => 0.5), false);
  assert.equal(w.data(OPEN_ROLE), null); // 同一个 w，断言未写入有效 winner
});

test("全量黑名单等价于空池", () => {
  assert.equal(bmwPickWinner(["a", "b"], ["a", "b"], () => 0.5), null);
});

test("cleanup 后重新抽签", () => {
  const w = fakeWindow();
  bmwShouldPlay(w, OPEN_ROLE, "a", ["a", "b"], [], sequence(0.0));
  bmwCleanup(w, OPEN_ROLE);
  assert.equal(w.data(OPEN_ROLE), null);
});

test("残留 winner 已被拉黑：不复用，重新抽签", () => {
  // 审查 M-4：注入点位于上游 `if (effects.hasActiveFullScreenEffect) return;`
  // 之前，winner 抽出后若因该判断提前 return 就没有动画、也没有 animationEnded
  // 触发 cleanupForcedRoles，winner 会留到窗口销毁；期间 --apply-config 只重写
  // 文件并 reload 特效，不清除 window 的 role 数据。
  const w = fakeWindow();
  w.setData(OPEN_ROLE, "b"); // 残留 winner = b
  // 池含 a/b/c，b 已入黑名单 → 不得继续复用 b
  const plays = bmwShouldPlay(w, OPEN_ROLE, "a", ["a", "b", "c"], ["b"], sequence(0.0));
  assert.notEqual(w.data(OPEN_ROLE), "b", "已被拉黑的 winner 不得被复用");
  assert.equal(plays, true, "重抽后应由 eligible 中的特效播放");
});

test("残留 winner + 池清空：返回 false（不复用旧结果）", () => {
  // 空池（黑名单全选）路径必须对残留 winner 同样生效
  const w = fakeWindow();
  w.setData(OPEN_ROLE, "a");
  assert.equal(bmwShouldPlay(w, OPEN_ROLE, "a", [], [], () => 0.5), false);
});

test("开关闸：enabled=false 不播放且不写 winner", () => {
  // 占位特效未加载（开关关闭）时：直接返回 false，且不得留下任何残留 winner，
  // 否则开关重开后会复用关闭期抽出的陈旧结果。
  const w = fakeWindow();
  assert.equal(bmwShouldPlay(w, OPEN_ROLE, "a", ["a", "b"], [], sequence(0), false), false);
  assert.equal(w.data(OPEN_ROLE), null);
});

test("开关闸：enabled=true 正常抽签", () => {
  const w = fakeWindow();
  assert.equal(bmwShouldPlay(w, OPEN_ROLE, "a", ["a", "b"], [], sequence(0), true), true);
  assert.equal(w.data(OPEN_ROLE), "a");
});

test("开关关→开：关闭态未写 winner，开启后按 rng 重新抽", () => {
  const w = fakeWindow();
  const rng = sequence(0.5); // 关闭态早退不消费 rng；开启态消费首值 0.5 → 索引 1
  bmwShouldPlay(w, OPEN_ROLE, "a", ["a", "b"], [], rng, false);
  assert.equal(w.data(OPEN_ROLE), null, "关闭态不写 winner");
  assert.equal(bmwShouldPlay(w, OPEN_ROLE, "b", ["a", "b"], [], rng, true), true);
  assert.equal(w.data(OPEN_ROLE), "b");
});

test("兼容 window.data 未设置时返回 undefined 与 null 两种情况", () => {
  // KWin 真实返回值未实测确认，两种都必须被当作"未设置"并触发抽签。
  const wUndefined = {
    data: () => undefined,
    setData: () => {},
  };
  const wNull = {
    data: () => null,
    setData: () => {},
  };
  assert.equal(
    bmwShouldPlay(wUndefined, OPEN_ROLE, "a", ["a", "b"], [], sequence(0.0)),
    true,
  );
  assert.equal(
    bmwShouldPlay(wNull, OPEN_ROLE, "a", ["a", "b"], [], sequence(0.0)),
    true,
  );
});

// ---- 预览协议（BMW_PREVIEW 标题 → 强制指定 winner）----
// spec §8「动画预览」：KWin 无 playEffect API（org.kde.kwin.Effects.xml:3-42
// 仅 9 方法、全源码 0 命中、qdbus6 实测一致），只能靠真实窗口开/关事件 +
// 窗口标题携带目标 id。协议格式 BMW_PREVIEW:<effectId>，KCM 与 e2e 按此拼。

test("预览协议：caption=BMW_PREVIEW:kwin6_effect_fire 时 fire 必当选（即使 rng 指向别处）", () => {
  const w = fakeWindow();
  w.caption = "BMW_PREVIEW:kwin6_effect_fire";
  // rng 恒返回 0.99 → 无协议时必选末项(doom)，此处必须被协议覆盖
  assert.equal(
    bmwShouldPlay(
      w,
      OPEN_ROLE,
      "kwin6_effect_fire",
      ["kwin6_effect_fire", "kwin6_effect_doom"],
      [],
      () => 0.99,
    ),
    true,
  );
  assert.equal(w.data(OPEN_ROLE), "kwin6_effect_fire");
});

test("预览协议：目标不在 pool 内 → 视为非法，回落随机", () => {
  const w = fakeWindow();
  w.caption = "BMW_PREVIEW:kwin6_effect_not_in_pool";
  assert.equal(bmwPreviewTarget(w.caption, ["kwin6_effect_fire"]), null);
});

test("预览协议：非 BMW_PREVIEW 前缀 → null（用户窗口不误触发）", () => {
  assert.equal(bmwPreviewTarget("kwin6_effect_fire", ["kwin6_effect_fire"]), null);
  assert.equal(bmwPreviewTarget(null, ["kwin6_effect_fire"]), null);
});

test("预览协议：目标在 blacklist 内仍强制播放（绕过 eligible 校验）", () => {
  // 调研结论：arbiter.js:47 的 eligible.indexOf(winner) 复用校验会把出池
  // winner 踢回随机，预览一个已剔除的特效必须绕过它
  const w = fakeWindow();
  w.caption = "BMW_PREVIEW:kwin6_effect_fire";
  assert.equal(
    bmwShouldPlay(
      w,
      OPEN_ROLE,
      "kwin6_effect_fire",
      ["kwin6_effect_fire"],
      ["kwin6_effect_fire"],
      () => 0.5,
    ),
    true,
  );
});

test("预览协议：同 caption 对 OPEN/CLOSE 两个 role 均命中", () => {
  // 两个 role 各自调用 bmwShouldPlay，只处理一个会导致只播一段动画
  const w = fakeWindow();
  w.caption = "BMW_PREVIEW:kwin6_effect_fire";
  bmwShouldPlay(w, OPEN_ROLE, "kwin6_effect_fire", ["kwin6_effect_fire", "a"], [], () => 0.99);
  assert.equal(
    bmwShouldPlay(w, CLOSE_ROLE, "kwin6_effect_fire", ["kwin6_effect_fire", "a"], [], () => 0.99),
    true,
  );
  assert.equal(w.data(CLOSE_ROLE), "kwin6_effect_fire");
});
