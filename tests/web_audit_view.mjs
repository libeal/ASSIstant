import assert from "node:assert/strict";

import {
  auditSummaryText,
  filteredAuditEvents,
  filteredAuditSessions,
} from "../web/static/modules/audit-view-utils.js";

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
assert.equal(filteredAuditEvents(events, { limit: 2 }).length, 2);
assert.equal(auditSummaryText(events[0]), "queued");

console.log("web_audit_view: ok");
