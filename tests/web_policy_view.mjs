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
const response = {
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
  setStatus() {},
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

console.log("web_policy_view: ok");
