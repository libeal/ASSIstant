import assert from "node:assert/strict";

import { normalizeExecutionEntries } from "../web/static/modules/timeline.js";

const emptyEntries = normalizeExecutionEntries("根级执行结果", {
  ok: true,
  status: "succeeded",
  step_id: "root-must-not-become-a-step",
  timeline: [],
});
assert.deepEqual(
  emptyEntries,
  [],
  "an empty authoritative timeline must not synthesize a step from root ok/status",
);

const domainTimeline = [
  {
    id: "execution-i2-3-domain-step",
    kind: "execution",
    status: "approval_required",
    step_id: "domain-step-3",
    title: "权威步骤",
    output_blocks: [],
  },
];
const domainEntries = normalizeExecutionEntries("根级标题", {
  ok: false,
  status: "failed",
  timeline: domainTimeline,
});

assert.equal(domainEntries.length, 1);
assert.equal(domainEntries[0].status, "approval_required");
assert.equal(domainEntries[0].output.status, "approval_required");
assert.equal(domainEntries[0].output.step_id, "domain-step-3");
assert.equal(domainTimeline[0].status, "approval_required");
assert.equal(domainTimeline[0].step_id, "domain-step-3");

console.log("web_timeline: ok");
