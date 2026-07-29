import assert from "node:assert/strict";

import { createSkillsView } from "../web/static/modules/view-skills.js";

const calls = [];
const scriptSelect = {
  children: [],
  appendChild(child) { this.children.push(child); },
};
Object.defineProperty(scriptSelect, "innerHTML", {
  get() { return ""; },
  set() { scriptSelect.children = []; },
});

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

console.log("web_skills_view: ok");
