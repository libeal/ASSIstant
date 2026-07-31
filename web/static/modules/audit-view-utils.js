/** @typedef {import("./types.js").AuditEvent} AuditEvent */

/** @param {Array<Record<string, any>>} sessions @param {{query?: string, status?: string}} [filters] @returns {Array<Record<string, any>>} */
export function filteredAuditSessions(sessions, { query = "", status = "all" } = {}) {
  const q = String(query || "").trim().toLowerCase();
  const statusFilter = String(status || "all");
  return (Array.isArray(sessions) ? sessions : []).filter((session) => {
    const hay = `${session.session_id || ""} ${session.summary || ""} ${session.status || ""}`.toLowerCase();
    if (q && !hay.includes(q)) return false;
    if (statusFilter !== "all" && String(session.status || "") !== statusFilter) return false;
    return true;
  });
}

/** @param {AuditEvent[]} events @param {{category?: string}} [filters] @returns {AuditEvent[]} */
export function filteredAuditEvents(events, { category = "all" } = {}) {
  let list = Array.isArray(events) ? events : [];
  if (category && category !== "all") {
    list = list.filter((event) => {
      const stage = String(event.stage || event.type || event.name || "").toLowerCase();
      return stage.includes(String(category).toLowerCase());
    });
  }
  return list;
}

/**
 * Select the next render batch without changing the complete event collection.
 * @param {AuditEvent[]} events
 * @param {number} start
 * @param {number} batchSize
 * @returns {{events: AuditEvent[], nextIndex: number, done: boolean}}
 */
export function nextAuditRenderBatch(events, start, batchSize) {
  const list = Array.isArray(events) ? events : [];
  const first = Math.max(0, Math.min(list.length, Number.isFinite(start) ? Math.floor(start) : 0));
  const size = Math.max(1, Number.isFinite(batchSize) ? Math.floor(batchSize) : 1);
  const nextIndex = Math.min(list.length, first + size);
  return {
    events: list.slice(first, nextIndex),
    nextIndex,
    done: nextIndex >= list.length,
  };
}

/** @param {AuditEvent} event @returns {string} */
export function auditSummaryText(event) {
  if (!event) return "";
  if (typeof event.summary === "string" && event.summary.trim()) return event.summary.trim();
  return String(event.stage || event.type || event.name || "event");
}

/**
 * Hash-chain verdict for one audit session read.
 *
 * "unknown" is deliberately distinct from "failed": a report that carries no
 * verdict at all must not be presented as a passed check, and must not be
 * presented as tampering either.
 * @param {Record<string, any>|null|undefined} data
 * @returns {{state: string, label: string, kind: string, breaks: Array<Record<string, any>>}}
 */
export function auditIntegrityStatus(data) {
  const integrity = data?.integrity && typeof data.integrity === "object" ? data.integrity : {};
  const known = typeof data?.integrity_ok === "boolean" || typeof integrity.ok === "boolean";
  const breaks = Array.isArray(integrity.breaks) ? integrity.breaks : [];
  if (!known) return { state: "unknown", label: "integrity: unknown", kind: "medium", breaks };
  const ok = data?.integrity_ok === true && integrity.ok !== false;
  return ok
    ? { state: "ok", label: "integrity: ok", kind: "low", breaks }
    : { state: "failed", label: "integrity: failed", kind: "high", breaks };
}

/**
 * Why the timeline is empty when the chain did not verify. Replaces a silent
 * empty state that read as "this session did nothing".
 * @param {{state: string, breaks: Array<Record<string, any>>}} status
 * @returns {string}
 */
export function auditIntegrityTimelineNotice(status) {
  if (status?.state !== "failed") return "";
  const breaks = Array.isArray(status.breaks) ? status.breaks : [];
  const detail = breaks.length
    ? `断点：${breaks.map((item) => `${item?.line || "?"}:${item?.reason || "unknown"}`).join("、")}`
    : "后端未提供断点位置。";
  return `哈希链校验未通过，已停用该 session 的时间线恢复。${detail}`;
}
