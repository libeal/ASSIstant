import assert from "node:assert/strict";

import {
  auditSummaryText,
  filteredAuditEvents,
  filteredAuditSessions,
  nextAuditRenderBatch,
} from "../web/static/modules/audit-view-utils.js";
import { createAuditView } from "../web/static/modules/view-audit.js";

const sessions = [
  { session_id: "web_a", status: "ok", summary: "work run" },
  { session_id: "cli_b", status: "failed", summary: "terminal" },
];
assert.equal(filteredAuditSessions(sessions, { query: "web" }).length, 1);
assert.equal(filteredAuditSessions(sessions, { status: "failed" })[0].session_id, "cli_b");

const events = [
  { stage: "job_start", summary: "queued" },
  { stage: "observer_enabled", summary: "auditd" },
  { stage: "job_done", summary: "ok" },
];
assert.equal(filteredAuditEvents(events, { category: "observer" }).length, 1);
assert.equal(auditSummaryText(events[0]), "queued");

const largeTimeline = Array.from({ length: 422 }, (_unused, index) => ({ stage: `event_${index}` }));
const rendered = [];
let cursor = 0;
let batchCount = 0;
do {
  const batch = nextAuditRenderBatch(largeTimeline, cursor, 40);
  rendered.push(...batch.events);
  cursor = batch.nextIndex;
  batchCount += 1;
  if (batch.done) break;
} while (true);
assert.equal(batchCount, 11);
assert.equal(rendered.length, largeTimeline.length);
assert.deepEqual(rendered, largeTimeline);
assert.equal(filteredAuditEvents(largeTimeline).length, largeTimeline.length);

function fakeContainer() {
  const container = {
    children: [],
    appendChild(child) {
      if (child.isFragment) this.children.push(...child.children);
      else this.children.push(child);
    },
  };
  Object.defineProperty(container, "innerHTML", {
    get() { return ""; },
    set() { container.children = []; },
  });
  return container;
}

const auditList = fakeContainer();
const observerSummary = fakeContainer();
const controls = {
  auditList,
  auditObserverSummary: observerSummary,
  auditEventFilter: { value: "" },
  auditLimitInput: { value: "40" },
};
const frames = [];
globalThis.window = {
  requestAnimationFrame(callback) { frames.push(callback); },
};
globalThis.document = {
  createDocumentFragment() {
    return {
      isFragment: true,
      children: [],
      appendChild(child) { this.children.push(child); },
    };
  },
  createElement() { return { className: "", innerHTML: "" }; },
};

const state = {
  auditEvents: largeTimeline,
  auditSessions: [],
  currentAuditSession: "large",
};
const auditProtocol = {
  auditEventDisplay(event) {
    return { stage: event.stage, title: event.stage, status: "", summary: event.stage, details: [], badges: [] };
  },
  auditEventMatchesCategory(event, category) { return !category || event.stage.includes(category); },
  auditEventName(event) { return event.stage; },
  auditEventTime() { return ""; },
  auditEventSummary(event) { return event.stage; },
  compactAuditTime() { return "--"; },
};
const view = createAuditView({
  state,
  request() {},
  $(id) { return controls[id] || null; },
  pretty: JSON.stringify,
  escapeHtml: String,
  emptyEvent(message) { return { message }; },
  auditProtocol,
  statusKind() { return ""; },
}, {});

view.renderAuditEventTimeline();
while (frames.length) frames.shift()();
assert.equal(auditList.children.length, largeTimeline.length);
assert.match(auditList.children.at(-1).innerHTML, /event_421/);

controls.auditEventFilter.value = "event_1";
view.renderAuditEventTimeline();
while (frames.length) frames.shift()();
const matchingEvents = largeTimeline.filter((event) => event.stage.includes("event_1"));
assert.ok(matchingEvents.length > 40);
assert.equal(auditList.children.length, matchingEvents.length);
assert.match(auditList.children.at(-1).innerHTML, new RegExp(matchingEvents.at(-1).stage));
controls.auditEventFilter.value = "";

state.auditEvents = Array.from({ length: 90 }, (_unused, index) => ({ stage: `old_${index}` }));
view.renderAuditEventTimeline();
state.auditEvents = Array.from({ length: 55 }, (_unused, index) => ({ stage: `new_${index}` }));
view.renderAuditEventTimeline();
while (frames.length) frames.shift()();
assert.equal(auditList.children.length, 55);
assert.match(auditList.children.at(-1).innerHTML, /new_54/);

const report = view.renderAuditReadableReport({ session_id: "large", events: largeTimeline });
assert.match(report, /422\. -- event_421 - event_421/);
assert.match(report, /完整 JSONL 事件:/);
assert.match(report, /"stage":"event_421"/);
const brokenReport = view.renderAuditReadableReport({
  session_id: "broken",
  events: [],
  integrity_ok: false,
  integrity: { ok: false, breaks: [{ line: 2, reason: "hash_mismatch" }] },
});
assert.match(brokenReport, /完整性: 失败/);
assert.match(brokenReport, /2:hash_mismatch/);

console.log("web_audit_view: ok");
