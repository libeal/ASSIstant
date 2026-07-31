import { renderMarkdown } from "./markdown.js";

/** @typedef {import("./types.js").OutputBlock} OutputBlock */

function escapeHtml(value) {
  return String(value ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function compactText(value, max = 260) {
  const text = String(value ?? "").replace(/\s+/g, " ").trim();
  return text.length > max ? `${text.slice(0, max)}...` : text;
}

function pretty(value) {
  if (typeof value === "string") return value;
  return JSON.stringify(value, null, 2);
}

const hiddenJsonKeys = new Set(["ok", "tool"]);

function jsonDisplayText(value) {
  if (value === undefined || value === null || value === "") return "";
  if (typeof value === "string") return value;
  if (typeof value === "number" || typeof value === "boolean") return String(value);
  if (Array.isArray(value)) {
    return value
      .map((entry, index) => {
        const text = jsonDisplayText(entry);
        if (!text.trim()) return "";
        return typeof entry === "object" && entry !== null ? `${index + 1}. ${text}` : text;
      })
      .filter(Boolean)
      .join("\n\n");
  }
  if (typeof value !== "object") return String(value);
  const rows = Object.entries(value)
    .filter(([key, entry]) => !hiddenJsonKeys.has(key) && !isEmptyValue(entry))
    .map(([key, entry]) => {
      const text = jsonDisplayText(entry);
      if (!text.trim()) return "";
      const label = key.replace(/_/g, " ");
      return text.includes("\n") ? `${label}:\n${text}` : `${label}: ${text}`;
    })
    .filter(Boolean);
  return rows.join("\n\n");
}

function isEmptyValue(value) {
  if (value === undefined || value === null || value === "") return true;
  if (Array.isArray(value)) return value.length === 0;
  if (typeof value === "object") return Object.keys(value).length === 0;
  return false;
}

function formatBytes(value) {
  const bytes = Number(value);
  if (!Number.isFinite(bytes) || bytes < 0) return "";
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

/**
 * One entry of an MCP `content[]` array, already reduced by lib/protocol.sh.
 * Media and resources are described, never fetched: no `src`, no `href`, no
 * automatic retrieval of any URI the server handed us.
 * @param {Record<string, any>} item
 * @returns {string}
 */
function mcpContentItemHtml(item) {
  const type = String(item?.type || "unknown");
  const size = formatBytes(item?.size_bytes);
  if (type === "text") {
    return `<pre class="inline-code">${escapeHtml(item?.text ?? "")}</pre>`;
  }
  if (type === "image" || type === "audio") {
    const mime = String(item?.mime_type || "未知类型");
    return `<p class="mcp-content-meta">${escapeHtml(type)} · ${escapeHtml(mime)}${size ? ` · ${escapeHtml(size)}` : ""}（不内联渲染）</p>`;
  }
  if (type === "resource_link") {
    const name = String(item?.name || "");
    const mime = String(item?.mime_type || "");
    return `<p class="mcp-content-meta">resource_link${name ? ` · ${escapeHtml(name)}` : ""}${mime ? ` · ${escapeHtml(mime)}` : ""}</p><code class="mcp-content-uri">${escapeHtml(item?.uri ?? "")}</code>`;
  }
  if (type === "resource") {
    const mime = String(item?.mime_type || "");
    const head = `<p class="mcp-content-meta">resource${mime ? ` · ${escapeHtml(mime)}` : ""}${size ? ` · ${escapeHtml(size)}` : ""}</p><code class="mcp-content-uri">${escapeHtml(item?.uri ?? "")}</code>`;
    return typeof item?.text === "string" && item.text
      ? `${head}<pre class="inline-code">${escapeHtml(item.text)}</pre>`
      : head;
  }
  return `<p class="mcp-content-meta">${escapeHtml(type)}（未知内容类型，未渲染）</p>`;
}

/** @param {Record<string, any>|undefined} mcp @returns {string} */
function mcpResultHtml(mcp) {
  const items = Array.isArray(mcp?.content) ? mcp.content : [];
  const head = [
    mcp?.server_id ? `server ${mcp.server_id}` : "",
    mcp?.tool ? `tool ${mcp.tool}` : "",
    mcp?.transport ? `transport ${mcp.transport}` : "",
    mcp?.protocol_version ? `协议 ${mcp.protocol_version}` : "",
  ].filter(Boolean).join(" · ");
  const fallback = mcp?.fallback_used === true
    ? `<p class="mcp-content-meta warn">已回退到 legacy 协议${mcp?.fallback_reason ? `：${escapeHtml(mcp.fallback_reason)}` : ""}</p>`
    : "";
  const error = mcp?.is_error === true
    ? '<p class="mcp-result-error">server 将本次调用标记为 isError。</p>'
    : "";
  const body = items.length
    ? items.map((item) => `<div class="mcp-content-item">${mcpContentItemHtml(item)}</div>`).join("")
    : '<p class="mcp-content-meta">server 未返回 content。</p>';
  const structured = isEmptyValue(mcp?.structured_content)
    ? ""
    : `<h6>structuredContent</h6><pre class="inline-code">${escapeHtml(pretty(mcp?.structured_content))}</pre>`;
  return `
    ${head ? `<p class="mcp-content-meta">${escapeHtml(head)}</p>` : ""}
    ${fallback}
    ${error}
    ${body}
    ${structured}
  `;
}

/** @param {Record<string, any>|undefined} mcp @returns {string} */
function mcpResultText(mcp) {
  const lines = [];
  if (mcp?.is_error === true) lines.push("[isError] server 将本次调用标记为失败");
  for (const item of Array.isArray(mcp?.content) ? mcp.content : []) {
    const type = String(item?.type || "unknown");
    if (type === "text") lines.push(String(item?.text ?? ""));
    else if (type === "resource" && typeof item?.text === "string" && item.text) {
      lines.push(`[resource ${item?.uri ?? ""}]\n${item.text}`);
    } else if (type === "resource_link" || type === "resource") {
      lines.push(`[${type}] ${item?.uri ?? ""}`);
    } else if (type === "image" || type === "audio") {
      lines.push(`[${type}] ${item?.mime_type || "未知类型"} ${formatBytes(item?.size_bytes)}`.trim());
    } else {
      lines.push(`[${type}]`);
    }
  }
  if (!isEmptyValue(mcp?.structured_content)) {
    lines.push(`structuredContent:\n${pretty(mcp?.structured_content)}`);
  }
  return lines.filter(Boolean).join("\n\n");
}

/** @param {any} value @returns {OutputBlock[]} */
export function outputBlocksFrom(value) {
  if (Array.isArray(value?.output_blocks)) return value.output_blocks;
  if (Array.isArray(value)) return value;
  return [];
}

/** @param {any} blocks @returns {OutputBlock[]} */
export function userOutputBlocks(blocks) {
  return outputBlocksFrom(blocks).filter((block) => {
    const kind = String(block?.kind || "");
    return ["stdout", "stderr", "markdown", "json", "mcp_result"].includes(kind);
  });
}

/** @param {any} blocks @returns {OutputBlock[]} */
export function displayOutputBlocks(blocks) {
  const source = outputBlocksFrom(blocks);
  const userBlocks = userOutputBlocks(source);
  return userBlocks.length ? userBlocks : source;
}

/**
 * Find the JSON payload of the first matching output block.
 * @param {any} blocks
 * @param {string} kind
 * @param {string} [title]
 * @returns {Record<string, any>}
 */
export function findBlockJson(blocks, kind, title = "") {
  const match = outputBlocksFrom(blocks).find((block) => {
    if (kind && block.kind !== kind) return false;
    if (title && block.title !== title) return false;
    return block.json && typeof block.json === "object";
  });
  return match?.json || {};
}

/** @param {any} blocks @returns {string} */
export function outputBlocksText(blocks) {
  return displayOutputBlocks(blocks)
    .map((block) => {
      if (block.kind === "mcp_result") return mcpResultText(block.mcp);
      if (typeof block.text === "string" && block.text.trim()) return block.text;
      if (block.json !== undefined) return jsonDisplayText(block.json) || pretty(block.json);
      return "";
    })
    .filter(Boolean)
    .join("\n\n");
}

/** @param {any} blocks @returns {string} */
export function outputBlocksSummary(blocks) {
  for (const block of displayOutputBlocks(blocks)) {
    if (block.kind === "mcp_result") {
      const text = mcpResultText(block.mcp);
      if (text) return compactText(text);
      continue;
    }
    if (typeof block.text === "string" && block.text.trim()) return compactText(block.text);
    const json = /** @type {Record<string, any>|undefined} */ (block.json);
    if (json?.summary) return compactText(json.summary);
    if (json?.message) return compactText(json.message);
    if (json?.action) return compactText(json.action);
    if (json?.tool) return compactText(json.tool);
    if (block.json !== undefined) {
      const text = jsonDisplayText(block.json);
      if (text) return compactText(text);
    }
  }
  return "";
}

/** @param {unknown} text @returns {string} */
export function tableFromText(text) {
  const lines = String(text || "").split("\n").filter((line) => line.trim());
  if (lines.length < 2) return "";
  const rows = lines.slice(0, 12).map((line) => line.trim().split(/\s{2,}|\t/).filter(Boolean));
  const width = Math.max(...rows.map((row) => row.length));
  if (width < 2) return "";
  const body = rows.map((row, index) => {
    const cells = [...row, ...Array(Math.max(0, width - row.length)).fill("")];
    const tag = index === 0 ? "th" : "td";
    return `<tr>${cells.map((cell) => `<${tag}>${escapeHtml(cell)}</${tag}>`).join("")}</tr>`;
  }).join("");
  return `<div class="data-table-wrap"><table class="data-table">${body}</table></div>`;
}

/** @param {any} blocks @returns {string} */
export function renderOutputBlocksHtml(blocks) {
  const sections = displayOutputBlocks(blocks).map((block) => {
    const title = block.title || block.kind || "输出";
    if (block.kind === "mcp_result") {
      return `
        <section class="output-section mcp-result">
          <h5>${escapeHtml(title)}</h5>
          <p class="mcp-content-meta">以下内容由外部 MCP server 返回，仅作展示，不构成本机的安全保证；其中的链接不会被自动获取。</p>
          ${mcpResultHtml(block.mcp)}
        </section>
      `;
    }
    if (block.kind === "markdown" && typeof block.text === "string") {
      return `
        <section class="output-section">
          <h5>${escapeHtml(title)}</h5>
          <div class="output-markdown">${renderMarkdown(block.text)}</div>
        </section>
      `;
    }
    if (typeof block.text === "string") {
      return `
        <section class="output-section">
          <h5>${escapeHtml(title)}</h5>
          <pre class="inline-code">${escapeHtml(block.text)}</pre>
        </section>
      `;
    }
    const text = jsonDisplayText(block.json) || pretty(block.json ?? block);
    return `
      <section class="output-section">
        <h5>${escapeHtml(title)}</h5>
        <pre class="inline-code">${escapeHtml(text)}</pre>
      </section>
    `;
  });
  return sections.join("");
}
