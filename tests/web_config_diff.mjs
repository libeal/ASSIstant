import assert from "node:assert/strict";

import {
  collectEditableConfigValues,
  configInputId,
  normalizeConfigFieldValue,
  pendingConfigChanges,
  remoteSecretTransmissionBlocked,
} from "../web/static/modules/config-utils.js";
import {
  CONFIG_GROUPS,
  syncApprovalScopeFields,
} from "../web/static/modules/policy-config.js";

const fieldBool = { key: "agent_loop.thinking_trace_enabled", type: "boolean" };
assert.equal(normalizeConfigFieldValue(fieldBool, 1), true);
assert.equal(normalizeConfigFieldValue({ key: "n", type: "number" }, "12"), 12);

const config = {
  provider: "OpenAI_Compatible",
  agent_loop: { thinking_trace_enabled: true, max_iterations: 8 },
  web: { port: 8765 },
};
const values = collectEditableConfigValues(config);
assert.equal(values.provider, "openai_compatible");
assert.equal(values["agent_loop.thinking_trace_enabled"], true);

const draft = { ...values, "agent_loop.max_iterations": 9 };
const changes = pendingConfigChanges(draft, values);
assert.deepEqual(changes, { "agent_loop.max_iterations": 9 });
assert.deepEqual(pendingConfigChanges(draft, values, new Set(["agent_loop.max_iterations"])), {});
assert.equal(configInputId("agent_loop.thinking_trace_enabled"), "config-agent_loop-thinking_trace_enabled");
assert.equal(remoteSecretTransmissionBlocked({ remote: { enabled: true } }), true);
assert.equal(remoteSecretTransmissionBlocked({ remote: { enabled: true, allow_api_key_transmission: true } }), false);
assert.equal(remoteSecretTransmissionBlocked({ remote: { enabled: false } }), false);

syncApprovalScopeFields({
  approvals: {
    auto: { package_scope: false },
    scope_catalog: ["package_scope", "another_scope", "invalid-scope"],
  },
});
const approvalGroup = CONFIG_GROUPS.find((group) => group.title === "自动批准能力");
assert.ok(approvalGroup);
assert.equal(approvalGroup.fields.filter((field) => field.key === "approvals.auto.package_scope").length, 1);
assert.equal(approvalGroup.fields.filter((field) => field.key === "approvals.auto.another_scope").length, 1);
assert.equal(approvalGroup.fields.some((field) => field.key === "approvals.auto.invalid-scope"), false);
syncApprovalScopeFields({ approvals: { auto: {}, scope_catalog: ["package_scope"] } });
assert.equal(approvalGroup.fields.filter((field) => field.key === "approvals.auto.package_scope").length, 1);
assert.equal(approvalGroup.fields.some((field) => field.key === "approvals.auto.another_scope"), false);

console.log("web_config_diff: ok");
