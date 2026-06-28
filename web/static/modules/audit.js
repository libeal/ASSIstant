export function auditEventName(event) {
  return event?.stage || event?.event || event?.type || event?.name || event?.status || event?.kind || event?.payload?.event || "event";
}

export function auditEventTime(event) {
  return event?.timestamp || event?.time || event?.started_at || event?.created_at || "";
}

export function compactAuditTime(value) {
  if (!value) return "--";
  return String(value).replace("T", " ").replace("Z", "");
}

export function auditEventSummary(event, pretty = (value) => JSON.stringify(value)) {
  const payload = event?.payload || event || {};
  if (payload.message) return payload.message;
  if (payload.status) return payload.status;
  if (payload.mode && payload.input) return `${payload.mode}: ${payload.input}`;
  if (payload.command) return payload.command;
  if (payload.ref) return payload.ref;
  return pretty(payload).replace(/\s+/g, " ").slice(0, 160);
}

export function auditEventMatchesCategory(event, category, pretty = (value) => JSON.stringify(value)) {
  const text = `${auditEventName(event)} ${pretty(event)}`.toLowerCase();
  if (category === "observer") return text.includes("observer") || text.includes("auditd");
  if (category === "policy") return text.includes("policy") || text.includes("approval") || text.includes("review");
  if (category === "execution") return text.includes("execut") || text.includes("terminal") || text.includes("script");
  if (category === "decision") return text.includes("decision") || text.includes("approve") || text.includes("reject") || text.includes("skip") || text.includes("terminate");
  if (category === "error") return text.includes("failed") || text.includes("error") || text.includes("blocked");
  return true;
}
