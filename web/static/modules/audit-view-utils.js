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

/** @param {AuditEvent[]} events @param {{category?: string, limit?: number}} [filters] @returns {AuditEvent[]} */
export function filteredAuditEvents(events, { category = "all", limit = 200 } = {}) {
  const max = Math.max(0, Number(limit) || 0);
  let list = Array.isArray(events) ? events : [];
  if (category && category !== "all") {
    list = list.filter((event) => {
      const stage = String(event.stage || event.type || event.name || "").toLowerCase();
      return stage.includes(String(category).toLowerCase());
    });
  }
  return max > 0 ? list.slice(0, max) : list;
}

/** @param {AuditEvent} event @returns {string} */
export function auditSummaryText(event) {
  if (!event) return "";
  if (typeof event.summary === "string" && event.summary.trim()) return event.summary.trim();
  return String(event.stage || event.type || event.name || "event");
}
