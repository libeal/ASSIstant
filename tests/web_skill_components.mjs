import assert from "node:assert/strict";

import {
  createSkillComponentLoader,
  normalizeComponentFinding,
  normalizeRegistrationFailure,
} from "../web/static/modules/skill-components.js";

// --- 归一化 ---------------------------------------------------------------
assert.deepEqual(
  normalizeComponentFinding({
    severity: "warning",
    code: "SKILL_WEB_COMPONENT_INVALID",
    skill: "database-inspect",
    message: "duplicate Skill Web route: /api/db",
  }),
  {
    component: "database-inspect",
    severity: "warning",
    stage: "manifest",
    code: "SKILL_WEB_COMPONENT_INVALID",
    message: "duplicate Skill Web route: /api/db",
  },
);

// 没有 skill 字段时退到 code，再退到 unknown；severity 只保留 error/warning 两档。
assert.equal(normalizeComponentFinding({ code: "SKILL_PENDING_COMPONENT_INVALID" }).component, "SKILL_PENDING_COMPONENT_INVALID");
assert.equal(normalizeComponentFinding({}).component, "unknown");
assert.equal(normalizeComponentFinding({ severity: "error" }).severity, "error");
assert.equal(normalizeComponentFinding({ severity: "critical" }).severity, "warning");
assert.equal(normalizeComponentFinding(null).message, "Skill Web 组件被拒绝加载。");

const failure = normalizeRegistrationFailure("database-inspect", new Error("boom"));
assert.deepEqual(failure, {
  component: "database-inspect",
  severity: "error",
  stage: "register",
  code: "SKILL_WEB_COMPONENT_REGISTER_FAILED",
  message: "boom",
});
assert.equal(normalizeRegistrationFailure("", "plain string").message, "plain string");
assert.equal(normalizeRegistrationFailure("", "plain string").component, "unknown");

// --- 加载器把 findings 写进集中状态并触发渲染 -----------------------------
// installFragment 在 screen 已存在时提前返回，installNavigation 在没有 #nav
// 时提前返回，因此这个最小 stub 足以把失败点收敛到动态 import。
globalThis.document = {
  getElementById(id) {
    return id === "screen-demo" ? {} : null;
  },
};

const component = {
  name: "demo-component",
  navigation: { screen: "demo" },
  fragment_url: "/skill-components/demo/fragment.html",
  frontend_url: "/skill-components/demo/does-not-exist.js",
};

let renderCalls = 0;
const consoleErrors = [];
console.error = (...args) => consoleErrors.push(args[1]);
const state = { skillComponentFindings: [] };
const app = {
  state,
  titles: {},
  async api() {
    return {
      ok: true,
      status: "listed",
      components: [component],
      findings: [{ severity: "warning", code: "SKILL_WEB_COMPONENT_INVALID", skill: "broken", message: "bad manifest" }],
    };
  },
  renderSkillComponentFindings() {
    renderCalls += 1;
  },
};

const loader = createSkillComponentLoader(app);
await loader.loadSkillWebComponents();

assert.equal(renderCalls, 1, "加载后必须刷新用户可见的告警条");
assert.equal(state.skillComponentFindings.length, 2, "API finding 与注册异常都要落进状态");

const manifestFinding = state.skillComponentFindings.find((item) => item.stage === "manifest");
assert.equal(manifestFinding.component, "broken");
assert.equal(manifestFinding.message, "bad manifest");

const registerFinding = state.skillComponentFindings.find((item) => item.stage === "register");
assert.equal(registerFinding.component, "demo-component");
assert.equal(registerFinding.severity, "error");
assert.ok(registerFinding.message.length > 0, "注册异常必须带上可读原因");

// --- 重新加载替换旧结果，不累积 -------------------------------------------
await loader.loadSkillWebComponents();
assert.equal(renderCalls, 2);
assert.equal(state.skillComponentFindings.length, 2, "重新加载必须替换而不是追加");

// --- 无 finding 时状态清空 -------------------------------------------------
app.api = async () => ({ ok: true, status: "listed", components: [], findings: [] });
await loader.loadSkillWebComponents();
assert.deepEqual(state.skillComponentFindings, []);
assert.equal(renderCalls, 3);

assert.deepEqual(consoleErrors, ["demo-component", "demo-component"], "注册失败仍应保留 console 诊断");

console.log("web_skill_components: ok");
