import assert from "node:assert/strict";

import {
  contextMetaByTurn,
  contextTurnCapacity,
  createSessionTurn,
  entryStepKey,
  normalizeRestoredTurn,
  upsertSessionTurn,
  workPlanMarkdown,
} from "../web/static/modules/workbench-turns.js";
import { createWorkbenchView } from "../web/static/modules/view-workbench.js";

const turn = createSessionTurn("work", {
  ok: true,
  status: "executed",
  timeline: [{ id: "s1", step_id: "s1", title: "检查", status: "succeeded", stdout: "ok" }],
}, "检查磁盘", { order: 2, number: 2, timestamp: 1000, now: "2026-01-01T00:00:00Z" });
assert.equal(turn.id, "turn-2-1000");
assert.equal(turn.entries.length, 1);
assert.equal(entryStepKey(turn.entries[0]), "s1");
assert.equal(turn.contextEligible, true);

const restored = normalizeRestoredTurn({
  id: "persisted-1",
  number: 7,
  mode: "terminal",
  status: "succeeded",
  context_eligible: false,
  input: "printf ok",
  result: { ok: true, status: "succeeded" },
}, 0);
assert.equal(restored.id, "persisted-1");
assert.equal(restored.number, 7);
assert.equal(restored.contextEligible, false);
assert.equal(restored.mode, "terminal");

assert.equal(contextTurnCapacity({ context_turns: 2.8 }, { context_turns: 6 }), 2);
assert.equal(contextTurnCapacity(null, { context_turns: 0 }), 0);
const turns = [
  { id: "a", order: 1, mode: "work", contextEligible: true },
  { id: "b", order: 2, mode: "terminal", contextEligible: false },
  { id: "c", order: 3, mode: "work", contextEligible: true },
  { id: "d", order: 4, mode: "work", contextEligible: true },
];
const meta = contextMetaByTurn(turns, 2);
assert.equal(meta.get("d").label, "上下文 最新");
assert.equal(meta.get("c").included, true);
assert.equal(meta.get("a").label, "不在上下文");
assert.equal(meta.get("b").label, "不加入上下文");

const viewApp = {
  state: {
    sessionTurns: turns,
    sessionInfo: { context_turns: 2 },
  },
  sessionTurnCounter: 0,
  contextMetaByTurnPure: contextMetaByTurn,
};
const viewMeta = createWorkbenchView(viewApp).contextMetaByTurn();
assert.equal(viewMeta.get("d").label, "上下文 最新");
assert.equal(viewMeta.get("a").label, "不在上下文");

assert.deepEqual(upsertSessionTurn([{ id: "one", value: 1 }], { id: "one", value: 2 }), [{ id: "one", value: 2 }]);
assert.match(workPlanMarkdown({ response_type: "work_plan", steps: [{ id: "s1", title: "检查", executor_type: "shell", risk_level: "low" }] }), /s1: 检查/);

console.log("web_workbench_turns: ok");
