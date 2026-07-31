import assert from "node:assert/strict";

import { createPolicyView } from "../web/static/modules/view-policy.js";

class FakeElement {
  constructor() {
    this.children = [];
    this.disabled = false;
    this.hidden = false;
    this.value = "";
    this.textContent = "";
    this.title = "";
  }

  appendChild(child) {
    this.children.push(child);
    return child;
  }

  set innerHTML(value) {
    this.html = value;
    this.children = [];
  }

  get innerHTML() {
    return this.html || "";
  }
}

globalThis.document = {
  createElement() { return new FakeElement(); },
};

const controls = Object.fromEntries([
  "policyFileSelect",
  "policyEditor",
  "policySaveBtn",
  "policyLockPill",
  "policyEditMode",
  "policyBoundaryOptions",
  "policyGuardToggleBtn",
  "policyFilePreview",
  "riskRulesSummary",
  "policyBoundaryList",
  "policyBoundaryOptionsList",
  "policyVaultSummary",
  "policyOutput",
].map((id) => [id, new FakeElement()]));

const state = {
  configSnapshot: { web: { sensitive_edits_enabled: true } },
  currentPolicyPath: "audit-boundaries.json",
  policyFiles: [{ path: "audit-boundaries.json" }],
  commandGuardEnabled: true,
};
const output = [];
const toasts = [];
let response = {
  ok: false,
  status: "read_failed",
  code: "read_failed",
  message: "policy overlay is invalid",
};
const app = {
  state,
  $(id) { return controls[id] || null; },
  async api(path) {
    assert.equal(path, "/api/policies");
    return response;
  },
  request() {},
  setStatus(id, text) { if (controls[id]) controls[id].textContent = text; },
  setText(id, text) { if (controls[id]) controls[id].textContent = text; },
  showToast(message) { toasts.push(message); },
  printOutput(id, value) { output.push([id, value]); },
  pretty: JSON.stringify,
  escapeHtml: String,
};

const result = await createPolicyView(app).loadPolicies();
assert.equal(result, response);
assert.deepEqual(state.policyFiles, []);
assert.equal(state.currentPolicyPath, "");
assert.equal(controls.policyEditor.value, "");
assert.deepEqual(output, [["policyOutput", response]]);
assert.equal(toasts.at(-1), "policy overlay is invalid");
assert.match(controls.riskRulesSummary.children[0].innerHTML, /未加载/);
assert.match(controls.policyBoundaryList.innerHTML, /未加载/);
assert.match(controls.policyVaultSummary.innerHTML, /未加载/);

state.currentPolicyPath = "audit-boundaries.json";
response = {
  ok: true,
  status: "listed",
  files: [],
  capabilities: {
    deployment_mode: "source",
    sensitive_edits_enabled: true,
    policy_write: {
      available: false,
      allowed: false,
      method: "direct",
      code: "policy_write_failed",
      reason: "策略 overlay 对当前 Web 用户不可写",
    },
    command_guard_write: {
      available: true,
      allowed: true,
      method: "direct",
      code: "",
      reason: "",
    },
  },
};

await createPolicyView(app).loadPolicies();
assert.equal(state.currentPolicyPath, "");
assert.equal(controls.policySaveBtn.disabled, true);
assert.equal(controls.policyLockPill.textContent, "不可保存");
assert.equal(controls.policyEditMode.textContent, "策略 overlay 对当前 Web 用户不可写");
assert.equal(controls.policyGuardToggleBtn.disabled, false);

console.log("web_policy_view: ok");
