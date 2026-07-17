/** @param {string} id @returns {HTMLElement|null} */
export const $ = (id) => document.getElementById(id);

/** @param {unknown} value @returns {string} */
export function escapeHtml(value) {
  return String(value ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

/** @param {string} message @returns {void} */
export function showToast(message) {
  const toast = $("toast");
  if (!toast) return;
  toast.textContent = message;
  toast.classList.add("show");
  window.setTimeout(() => toast.classList.remove("show"), 2600);
}

/** @param {string} id @param {unknown} value @returns {void} */
export function setText(id, value) {
  const element = $(id);
  if (element) element.textContent = String(value ?? "");
}

/** @param {string} kind @returns {string} */
export function pillKind(kind) {
  if (["ok", "low", "succeeded", "completed", "read", "saved"].includes(kind)) return "low";
  if (["warn", "medium", "running", "queued", "approval_required", "planning", "review"].includes(kind)) return "medium";
  if (["err", "error", "failed", "high", "critical"].includes(kind)) return "high";
  return "";
}

/** @param {string} id @param {string} value @param {string} [kind] @returns {void} */
export function setStatus(id, value, kind = "") {
  const element = $(id);
  if (!element) return;
  const mapped = pillKind(kind);
  element.textContent = value;
  element.className = mapped ? `pill risk ${mapped}` : "pill";
}

/** @param {string} id @param {boolean} enabled @returns {void} */
export function setSwitch(id, enabled) {
  const element = $(id);
  if (!element) return;
  element.classList.toggle("on", Boolean(enabled));
  element.setAttribute("aria-pressed", enabled ? "true" : "false");
}

/** @param {string} risk @returns {"low"|"medium"|"high"} */
export function riskKind(risk) {
  if (risk === "low" || risk === "clean" || risk === "ok") return "low";
  if (risk === "medium" || risk === "warn" || risk === "warning") return "medium";
  return "high";
}

/** @param {string} text @returns {HTMLElement} */
export function emptyItem(text) {
  const item = document.createElement("article");
  item.className = "item";
  item.innerHTML = `<p>${escapeHtml(text)}</p>`;
  return item;
}

/** @param {string} text @returns {HTMLElement} */
export function emptyEvent(text) {
  const event = document.createElement("div");
  event.className = "event";
  event.innerHTML = `<time>--</time><div class="body"><strong>${escapeHtml(text)}</strong><span>等待数据。</span></div>`;
  return event;
}

/** @param {unknown} value @returns {string} */
export function pretty(value) {
  if (value === undefined) return "";
  if (typeof value === "string") return value;
  return JSON.stringify(value, null, 2);
}

/** @param {string} id @param {string} eventName @param {(event: any) => void} handler @returns {void} */
export function on(id, eventName, handler) {
  const element = $(id);
  if (!element) return;
  element.addEventListener(eventName, handler);
}
