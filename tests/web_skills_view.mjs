import assert from "node:assert/strict";

import { createSkillsView } from "../web/static/modules/view-skills.js";
import {
  skillExecutionPresentation,
  skillMaterializationPresentation,
  skillOriginPresentation,
} from "../web/static/modules/skill-catalog.js";

// --- 权限列：执行类 · capability ------------------------------------------
const helper = skillExecutionPresentation({ execution_class: "host_helper", capability: "firewall.apply" });
assert.equal(helper.label, "host_helper");
assert.equal(helper.capability, "firewall.apply");
assert.equal(helper.kind, "exec-helper");
// host_helper 必须有独立药丸，不得复用 risk high 样式。
assert.doesNotMatch(helper.kind, /risk|high/);
assert.match(helper.title, /execution/, "文案要指回标题栏的真实隔离身份");

const runner = skillExecutionPresentation({ execution_class: "runner", capability: "" });
assert.equal(runner.label, "runner");
assert.equal(runner.kind, "exec-runner");
assert.equal(runner.capability, "");
assert.notEqual(runner.kind, helper.kind, "runner 与 host_helper 在界面上必须可区分");

// `/api/tools` 用 "invalid" 表示包没有声明合法执行类。
assert.equal(skillExecutionPresentation({ execution_class: "invalid" }).kind, "exec-unknown");
assert.equal(skillExecutionPresentation({}).label, "invalid");

// --- 来源 -----------------------------------------------------------------
assert.equal(skillOriginPresentation({ origin: "builtin" }).label, "builtin");
assert.equal(skillOriginPresentation({ origin: "user" }).label, "user");
assert.equal(skillOriginPresentation({}).label, "unknown");

// --- 物化状态 -------------------------------------------------------------
const ready = skillMaterializationPresentation({ materialization: "ready" });
assert.equal(ready.actionable, false);
assert.equal(ready.busy, false);
assert.equal(ready.label, "ready");

const available = skillMaterializationPresentation({ materialization: "available" });
assert.equal(available.actionable, true);
assert.equal(available.label, "加载 Skill");

const failed = skillMaterializationPresentation({ materialization: "failed" });
assert.equal(failed.actionable, true);
assert.equal(failed.label, "重试加载");

const busy = skillMaterializationPresentation({ materialization: "materializing" });
assert.equal(busy.busy, true);
assert.equal(busy.actionable, false, "物化进行中不得再次触发");

// `/api/tools` 从不返回 local——缺字段时按 unknown 呈现，不伪造可点入口。
const missing = skillMaterializationPresentation({});
assert.equal(missing.state, "unknown");
assert.equal(missing.actionable, false);

const scriptSelect = {
  children: [],
  value: "",
  appendChild(child) { this.children.push(child); },
};
Object.defineProperty(scriptSelect, "innerHTML", {
  get() { return ""; },
  set() { scriptSelect.children = []; },
});

// renderScriptSelect builds real <option>/<optgroup> nodes, so the view needs a
// minimal document. Everything else stays null so rendering short-circuits.
globalThis.document = {
  createElement(tag) {
    return {
      tag,
      value: "",
      textContent: "",
      label: "",
      children: [],
      appendChild(child) { this.children.push(child); },
    };
  },
};

const calls = [];

const state = {
  configSnapshot: { web: { sensitive_edits_enabled: true } },
  tools: [],
};
const app = {
  state,
  request() {},
  $(id) { return id === "scriptSelect" ? scriptSelect : null; },
  showToast() {},
  riskKind() { return "low"; },
  async api(path) {
    calls.push(path);
    if (path === "/api/skills/materialize") {
      return { ok: true, status: "skill_materialized" };
    }
    if (path === "/api/tools") return { ok: true, scripts: [] };
    if (path === "/api/skills/tree") return { ok: false };
    throw new Error(`Unexpected API request: ${path}`);
  },
  async loadSkillWebComponents() {
    calls.push("loadSkillWebComponents");
  },
};

const view = createSkillsView(app);
await view.materializeSkill("database-inspect");

assert.deepEqual(calls, [
  "/api/skills/materialize",
  "/api/tools",
  "/api/skills/tree",
  "loadSkillWebComponents",
]);

// 空目录时给出占位项，而不是留下一个空的 <select>。
assert.equal(scriptSelect.children.length, 1);
assert.equal(scriptSelect.children[0].tag, "option");
assert.equal(scriptSelect.children[0].textContent, "连接后加载 skill");

// 有工具时按 `category / skill` 生成 optgroup。
state.tools = [
  { ref: "ops-basic/disk-hotspots", skill: "ops-basic", category: "system", description: "磁盘热点" },
  { ref: "ops-basic/log-search", skill: "ops-basic", category: "system", description: "日志检索" },
  { ref: "container-inspect/container-inspect", skill: "container-inspect", category: "container", description: "容器" },
];
view.renderScriptSelect();
assert.deepEqual(
  scriptSelect.children.map((child) => [child.tag, child.label]),
  [["optgroup", "container / container-inspect"], ["optgroup", "system / ops-basic"]],
);
assert.equal(scriptSelect.children[1].children.length, 2);
assert.equal(scriptSelect.children[1].children[0].value, "ops-basic/disk-hotspots");

console.log("web_skills_view: ok");
