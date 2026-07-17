import { hiddenOutputKeys, outputLabelMap } from "./constants.js";
import { escapeHtml, pretty } from "./dom.js";
import { normalizeExecutionEntries } from "./timeline.js";
import {
  findBlockJson,
  outputBlocksFrom,
  outputBlocksSummary,
  outputBlocksText,
  renderOutputBlocksHtml,
  userOutputBlocks,
} from "./output-blocks.js";

/** @typedef {import("./types.js").OutputBlock} OutputBlock */

/** @param {unknown} value @returns {value is Record<string, any>} */
export function isPlainObject(value) {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value);
}

/** @param {unknown} value @returns {boolean} */
export function isEmptyOutputValue(value) {
  if (value === undefined || value === null || value === "") return true;
  if (Array.isArray(value)) return value.length === 0;
  if (isPlainObject(value)) return Object.keys(value).length === 0;
  return false;
}

function compactText(value, max = 220) {
  const text = String(value ?? "").replace(/\s+/g, " ").trim();
  if (!text) return "";
  return text.length > max ? `${text.slice(0, max)}...` : text;
}

function outputLabel(key) {
  return outputLabelMap[key] || key;
}

/** @param {unknown} value @returns {string} */
export function extractRawOutput(value) {
  if (!isPlainObject(value)) return "";
  if (outputBlocksFrom(value).length) return outputBlocksText(value);
  if (isPlainObject(value.output)) return extractRawOutput(value.output);
  return "";
}

/** @param {unknown} value @returns {string} */
export function renderUserOutputText(value) {
  if (value === undefined) return "";
  if (typeof value === "string") return value;
  const raw = extractRawOutput(value);
  if (raw) return raw;
  if (Array.isArray(value)) return renderArrayOutputText(value);
  if (isPlainObject(value)) return renderObjectOutputText(value);
  return String(value);
}

/** @param {Array<unknown>} values @returns {string} */
export function renderArrayOutputText(values) {
  return values
    .map((entry, index) => {
      const text = renderUserOutputText(entry);
      if (!text.trim()) return "";
      return isPlainObject(entry) ? `${index + 1}. ${text}` : text;
    })
    .filter(Boolean)
    .join("\n\n");
}

/** @param {Record<string, any>} value @returns {string} */
export function renderObjectOutputText(value) {
  const rows = [];
  for (const [key, entry] of Object.entries(value)) {
    if (hiddenOutputKeys.has(key) || isEmptyOutputValue(entry)) continue;
    const text = renderUserOutputText(entry);
    if (!text.trim()) continue;
    const label = outputLabel(key);
    if (text.includes("\n")) rows.push(`${label}\n${text}`);
    else rows.push(`${label}: ${text}`);
  }
  return rows.join("\n\n");
}

/** @param {any} output @returns {Record<string, any>} */
export function primaryOutputObject(output) {
  const blocks = outputBlocksFrom(output);
  const blockJson = findBlockJson(blocks, "json");
  if (Object.keys(blockJson).length) return blockJson;
  if (isPlainObject(output?.output)) return output.output;
  return isPlainObject(output) ? output : {};
}

/** @param {any} output @returns {string} */
export function outputSummaryText(output) {
  const blockSummary = outputBlocksSummary(output);
  if (blockSummary) return blockSummary;
  const payload = primaryOutputObject(output);
  for (const key of ["summary", "message", "action", "error"]) {
    if (typeof payload[key] === "string" && payload[key].trim()) return compactText(payload[key], 260);
    if (typeof output?.[key] === "string" && output[key].trim()) return compactText(output[key], 260);
  }
  const raw = extractRawOutput(output);
  if (raw) return compactText(raw, 260);
  const text = renderUserOutputText(payload);
  return compactText(text, 260) || "无摘要输出";
}

/** @param {string} key @param {unknown} value @returns {string} */
export function renderOutputSection(key, value) {
  const label = outputLabel(key);
  const text = renderUserOutputText(value);
  return `
    <section class="output-section">
      <h5>${escapeHtml(label)}</h5>
      <pre class="inline-code">${escapeHtml(text)}</pre>
    </section>
  `;
}

/** @param {any} output @returns {string} */
export function renderPrimaryOutputHtml(output) {
  const blocks = outputBlocksFrom(output);
  if (blocks.length) return renderOutputBlocksHtml(blocks);
  const payload = primaryOutputObject(output);
  const chunks = [];
  const renderedKeys = new Set();
  const preferred = [
    "summary", "message", "error", "command", "stdout", "stderr", "load", "memory", "disk_usage", "df_summary",
    "top_dirs", "top_files", "top_processes", "processes", "journal", "journal_sample", "matches",
  ];
  for (const key of preferred) {
    const value = payload[key] ?? output?.[key];
    if (isEmptyOutputValue(value)) continue;
    chunks.push(renderOutputSection(key, value));
    renderedKeys.add(key);
  }
  if (isPlainObject(payload)) {
    for (const [key, value] of Object.entries(payload)) {
      if (renderedKeys.has(key) || hiddenOutputKeys.has(key) || isEmptyOutputValue(value)) continue;
      chunks.push(renderOutputSection(key, value));
    }
  }
  if (chunks.length) return chunks.join("");
  return `<p class="muted">${escapeHtml(outputSummaryText(output))}</p>`;
}

/** @param {any} output @returns {Record<string, any>} */
export function terminalReturnPayload(output) {
  const blocks = outputBlocksFrom(output);
  if (blocks.length) {
    const visibleBlocks = userOutputBlocks(blocks);
    return visibleBlocks.length ? { output_blocks: visibleBlocks } : {};
  }
  const payload = primaryOutputObject(output);
  const merged = {};
  for (const key of ["command", "stdout", "stderr", "summary", "message", "error"]) {
    const value = payload[key] ?? output?.[key];
    if (!isEmptyOutputValue(value)) merged[key] = value;
  }
  if (!Object.keys(merged).length && isPlainObject(payload)) return payload;
  return merged;
}

/** @param {any} output @returns {string} */
export function renderTerminalReturnHtml(output) {
  const payload = terminalReturnPayload(output);
  if (isEmptyOutputValue(payload)) {
    return '<p class="muted">本步骤没有返回 stdout/stderr；可展开原始调试数据确认执行元信息。</p>';
  }
  return renderPrimaryOutputHtml(payload);
}

/** @param {Array<[string, unknown]>} rows @returns {string} */
export function renderMetaRows(rows) {
  return rows
    .filter(([, value]) => !isEmptyOutputValue(value))
    .map(([label, value]) => `<div class="meta-row"><span>${escapeHtml(label)}</span><strong>${escapeHtml(value)}</strong></div>`)
    .join("");
}

/** @param {string} title @param {unknown} value @param {boolean} [open] @returns {string} */
export function renderJsonDetails(title, value, open = false) {
  if (isEmptyOutputValue(value)) return "";
  return `
    <details class="detail-block"${open ? " open" : ""}>
      <summary>${escapeHtml(title)}</summary>
      <pre class="code">${escapeHtml(pretty(value))}</pre>
    </details>
  `;
}

/** @param {Record<string, any>} result @returns {OutputBlock[]} */
export function executionFlowBlocks(result) {
  return outputBlocksFrom(result).filter((block) => {
    if (block?.title === "执行流程" && typeof block.text === "string" && block.text.trim()) return true;
    if (block?.title === "最终回答" && typeof block.text === "string" && block.text.trim()) return true;
    return false;
  });
}

/** @param {any} result @returns {string} */
export function renderExecutionFlowHtml(result) {
  const blocks = executionFlowBlocks(result);
  return blocks.length ? renderOutputBlocksHtml(blocks) : "";
}

/** @param {string} title @param {any} result @returns {string} */
export function renderProtocolText(title, result) {
  const flowText = outputBlocksText(executionFlowBlocks(result));
  const entriesText = normalizeExecutionEntries(title, result)
    .map((entry) => {
      const body = outputBlocksFrom(entry.output).length ? outputBlocksText(entry.output) : renderUserOutputText(entry.output);
      const number = entry.number ?? entry.index;
      const header = `${number}. ${entry.title}${entry.status ? ` (${entry.status})` : ""}`;
      return body.trim() ? `${header}\n${body}` : header;
    })
    .join("\n\n");
  return [flowText, entriesText].filter((text) => text.trim()).join("\n\n");
}

/** @param {string} title @param {any} result @returns {string} */
export function renderSharedExecutionOutput(title, result) {
  const flowText = outputBlocksText(executionFlowBlocks(result));
  if (flowText.trim()) return flowText;
  const blocks = outputBlocksFrom(result);
  if (blocks.length) return outputBlocksText(blocks);
  const entries = normalizeExecutionEntries(title, result);
  if (entries.length === 1) {
    const output = entries[0].output || result;
    const outputText = outputBlocksFrom(output).length ? outputBlocksText(output) : renderUserOutputText(output);
    if (outputText.trim()) return outputText;
  }
  return renderUserOutputText(result);
}
