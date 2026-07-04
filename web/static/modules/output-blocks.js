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

export function outputBlocksFrom(value) {
  if (Array.isArray(value?.output_blocks)) return value.output_blocks;
  if (Array.isArray(value)) return value;
  return [];
}

export function userOutputBlocks(blocks) {
  return outputBlocksFrom(blocks).filter((block) => {
    const kind = String(block?.kind || "");
    return ["stdout", "stderr", "markdown", "json"].includes(kind);
  });
}

export function displayOutputBlocks(blocks) {
  const source = outputBlocksFrom(blocks);
  const userBlocks = userOutputBlocks(source);
  return userBlocks.length ? userBlocks : source;
}

export function findBlockJson(blocks, kind, title = "") {
  const match = outputBlocksFrom(blocks).find((block) => {
    if (kind && block.kind !== kind) return false;
    if (title && block.title !== title) return false;
    return block.json && typeof block.json === "object";
  });
  return match?.json || {};
}

export function outputBlocksText(blocks) {
  return displayOutputBlocks(blocks)
    .map((block) => {
      if (typeof block.text === "string" && block.text.trim()) return block.text;
      if (block.json !== undefined) return jsonDisplayText(block.json) || pretty(block.json);
      return "";
    })
    .filter(Boolean)
    .join("\n\n");
}

export function outputBlocksSummary(blocks) {
  for (const block of displayOutputBlocks(blocks)) {
    if (typeof block.text === "string" && block.text.trim()) return compactText(block.text);
    if (block.json?.summary) return compactText(block.json.summary);
    if (block.json?.message) return compactText(block.json.message);
    if (block.json?.action) return compactText(block.json.action);
    if (block.json?.tool) return compactText(block.json.tool);
    if (block.json !== undefined) {
      const text = jsonDisplayText(block.json);
      if (text) return compactText(text);
    }
  }
  return "";
}

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

export function renderOutputBlocksHtml(blocks) {
  const sections = displayOutputBlocks(blocks).map((block) => {
    const title = block.title || block.kind || "输出";
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
