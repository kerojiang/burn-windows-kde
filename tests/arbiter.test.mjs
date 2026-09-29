// 仲裁核心单元测试 —— 使用 node:test 运行：node --test tests/arbiter.test.mjs
//
// 加载方式说明：lib/arbiter.js 最终会被注入进 KWin effect 上下文（无模块系统、
// 无 import/export），因此这里不用 import，而是把源码当作文本求值执行 —— 这同时
// 验证了该文件确实不含模块语法依赖，能被注入器安全内联。
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const src = readFileSync(new URL("../lib/arbiter.js", import.meta.url), "utf8");
const { bmwPickWinner, bmwShouldPlay, bmwCleanup } = new Function(
  `${src}\n;return { bmwPickWinner, bmwShouldPlay, bmwCleanup };`,
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
