/**
 * Pure rendering helpers for the MCP elicitation ("MCP input") drawer.
 *
 * Everything in here renders data supplied by an external MCP server. Field
 * names, titles, descriptions, enum values and prompt text are untrusted input
 * and are only ever escaped, never interpreted. No URI is fetched, inlined or
 * turned into a media source.
 */

import { escapeHtml } from "./dom.js";
import { schemaFieldHtml, schemaFormHtml } from "./schema-form.js";

/** Remaining time below which the countdown turns urgent. */
export const MCP_INPUT_URGENT_MS = 30_000;

/** Fixed provenance notice shown once per drawer. */
export const MCP_INPUT_SOURCE_NOTICE =
  "以下字段与文案由外部 MCP server 提供，不构成本机的安全保证；确认后所填内容会发送给该 server。";

/**
 * Interpret `approval_card.expires_at`, which lib/mcp_client.py emits as Unix
 * epoch seconds.
 * @param {unknown} expiresAt
 * @param {number} nowMs current time in milliseconds
 * @returns {{known: boolean, expired: boolean, remainingMs: number, urgent: boolean, label: string}}
 */
export function mcpInputExpiry(expiresAt, nowMs) {
  const seconds = Number(expiresAt);
  if (!Number.isFinite(seconds) || seconds <= 0) {
    return { known: false, expired: false, remainingMs: 0, urgent: false, label: "未提供" };
  }
  const remainingMs = seconds * 1000 - Number(nowMs || 0);
  if (remainingMs <= 0) {
    return { known: true, expired: true, remainingMs: 0, urgent: true, label: "已过期" };
  }
  const totalSeconds = Math.ceil(remainingMs / 1000);
  const minutes = Math.floor(totalSeconds / 60);
  const seconds_ = totalSeconds % 60;
  return {
    known: true,
    expired: false,
    remainingMs,
    urgent: remainingMs <= MCP_INPUT_URGENT_MS,
    label: minutes > 0 ? `剩余 ${minutes} 分 ${String(seconds_).padStart(2, "0")} 秒` : `剩余 ${seconds_} 秒`,
  };
}

/**
 * Meta rows for the drawer header. `transport` and `expires_at` come straight
 * from the approval card built in lib/protocol.sh.
 * @param {Record<string, any>|null} card
 * @param {{label: string}} expiry
 * @returns {Array<[string, string]>}
 */
export function mcpInputMetaRows(card, expiry) {
  return [
    ["MCP server", String(card?.server_id || "")],
    ["MCP tool", String(card?.tool || "")],
    ["协议", String(card?.protocol_version || "")],
    ["传输", String(card?.transport || "")],
    ["轮次", String(card?.round || 1)],
    ["有效期", String(expiry?.label || "未提供")],
  ];
}

/**
 * Thin alias over the shared schema control, kept so the elicitation drawer
 * and Skill parameter forms can never drift apart.
 * @param {string} requestKey
 * @param {string} propertyName
 * @param {Record<string, any>|null} schema
 * @param {boolean} required
 * @returns {string}
 */
export function mcpInputControl(requestKey, propertyName, schema, required) {
  return schemaFieldHtml(requestKey, propertyName, schema, required);
}

/**
 * The response selector defaults to `decline`: a conservative agent must not
 * ship a pre-armed "accept" for a request it renders on behalf of a third
 * party. `decline` is both first (browser default) and explicitly selected.
 * @param {string} requestKey
 * @returns {string}
 */
function mcpInputActionHtml(requestKey) {
  const encodedRequest = encodeURIComponent(requestKey);
  return `
      <label class="small mcp-input-action"><span>响应</span>
        <select class="select" data-mcp-action="${escapeHtml(encodedRequest)}">
          <option value="decline" selected>decline</option>
          <option value="accept">accept</option>
          <option value="cancel">cancel</option>
        </select>
      </label>`;
}

/**
 * @param {string} requestKey
 * @param {Record<string, any>|null} request
 * @returns {string}
 */
export function mcpInputRequestHtml(requestKey, request) {
  const params = request?.params && typeof request.params === "object" ? request.params : {};
  const mode = params.mode || "form";
  const message = params.message || requestKey;
  const encodedRequest = encodeURIComponent(requestKey);
  const action = mcpInputActionHtml(requestKey);
  if (mode === "url") {
    const url = String(params.url || "");
    const safeUrl = /^https?:\/\//i.test(url);
    return `<section class="mcp-input-request" data-mcp-request="${escapeHtml(encodedRequest)}" data-mcp-mode="url">
        <strong>${escapeHtml(message)}</strong>
        ${safeUrl ? `<a class="mcp-input-url" href="${escapeHtml(url)}" target="_blank" rel="noopener noreferrer">${escapeHtml(url)}</a>` : `<code class="mcp-input-url">${escapeHtml(url)}</code>`}
        ${action}
      </section>`;
  }
  const schema = params.requestedSchema || params.requested_schema || {};
  const controls = schemaFormHtml(requestKey, schema)
    || `<label class="small mcp-input-field"><span>JSON content</span><textarea class="textarea" data-mcp-content-json="${escapeHtml(encodedRequest)}" required>{}</textarea></label>`;
  return `<section class="mcp-input-request" data-mcp-request="${escapeHtml(encodedRequest)}" data-mcp-mode="form">
      <strong>${escapeHtml(message)}</strong>
      ${action}
      <div class="mcp-input-fields">${controls}</div>
    </section>`;
}

/**
 * @param {Record<string, any>} requests
 * @returns {string}
 */
export function mcpInputRequestsHtml(requests) {
  const entries = requests && typeof requests === "object" ? Object.entries(requests) : [];
  return entries.map(([key, request]) => mcpInputRequestHtml(key, request)).join("");
}

/**
 * @param {{known: boolean, expired: boolean, urgent: boolean, label: string}} expiry
 * @returns {string}
 */
export function mcpInputExpiryHtml(expiry) {
  const classes = ["mcp-input-expiry"];
  if (expiry?.expired) classes.push("expired");
  else if (expiry?.urgent) classes.push("urgent");
  const suffix = expiry?.expired ? "：本轮 elicitation 已过期，请重新发起。" : "";
  return `<p class="${classes.join(" ")}" id="mcpInputExpiry" role="status">有效期 ${escapeHtml(expiry?.label || "未提供")}${escapeHtml(suffix)}</p>`;
}
