/**
 * Pure helpers for the MCP portion of the approval card.
 *
 * The snapshot rendered here is captured by the execution layer at policy
 * review time (`approval_card.mcp_metadata`). The console must not go re-query
 * `/api/mcp/tools` for it: that catalog only exists after the user manually
 * clicked "加载工具" and may have drifted since the plan was reviewed.
 *
 * `description` / `inputSchema` / `annotations` are the server's own words.
 * They are displayed as untrusted data and never change the `risk_level` the
 * backend already decided.
 */

/** Fixed caveat shown above every server-authored annotation group. */
export const MCP_ANNOTATION_CAVEAT = "以下为外部 server 的自述，不构成安全保证。";

/** @param {unknown} value @returns {string} */
function displayValue(value) {
  if (value === null || value === undefined) return "";
  if (typeof value === "string") return value;
  return JSON.stringify(value, null, 2);
}

/**
 * Step arguments as key/value rows, so the reviewer does not have to unfold
 * "步骤 JSON" to see what is about to be sent.
 * @param {unknown} args
 * @returns {Array<{key: string, value: string, long: boolean}>}
 */
export function mcpArgumentRows(args) {
  if (!args || typeof args !== "object" || Array.isArray(args)) return [];
  return Object.entries(args).map(([key, value]) => {
    const text = displayValue(value);
    return { key, value: text, long: text.length > 200 || text.includes("\n") };
  });
}

/**
 * Tool annotations as rows. Kept as its own group rather than merged into the
 * step meta, because these are claims by the server, not facts about the step.
 * @param {unknown} annotations
 * @returns {Array<{key: string, value: string}>}
 */
export function mcpAnnotationRows(annotations) {
  if (!annotations || typeof annotations !== "object" || Array.isArray(annotations)) return [];
  return Object.entries(annotations).map(([key, value]) => ({ key, value: displayValue(value) }));
}

/**
 * `destructiveHint` earns its own explicit warning and nothing more: it does
 * not upgrade the card's risk styling, which stays whatever the backend's
 * policy review returned.
 * @param {unknown} annotations
 * @returns {string}
 */
export function mcpDestructiveWarning(annotations) {
  const destructive = annotations && typeof annotations === "object"
    ? /** @type {Record<string, any>} */ (annotations).destructiveHint
    : undefined;
  return destructive === true ? "Server 声明该 tool 可能具有破坏性（destructiveHint）。" : "";
}

/**
 * Client-side pre-validation against the snapshot's `inputSchema`.
 *
 * Advisory only — it surfaces obvious mistakes before a round trip. The
 * authoritative decision stays in the execution layer, so an empty or
 * unparseable schema simply yields no issues rather than blocking.
 * @param {unknown} schema
 * @param {unknown} args
 * @returns {{ok: boolean, issues: string[]}}
 */
export function mcpSchemaPrecheck(schema, args) {
  const issues = [];
  const source = schema && typeof schema === "object" && !Array.isArray(schema)
    ? /** @type {Record<string, any>} */ (schema)
    : null;
  if (!source) return { ok: true, issues };
  const value = args && typeof args === "object" && !Array.isArray(args)
    ? /** @type {Record<string, any>} */ (args)
    : null;
  if (!value) {
    return { ok: false, issues: ["arguments 必须是 JSON object。"] };
  }
  const properties = source.properties && typeof source.properties === "object" ? source.properties : {};
  for (const name of Array.isArray(source.required) ? source.required : []) {
    if (!Object.prototype.hasOwnProperty.call(value, String(name))) {
      issues.push(`缺少必填参数 ${String(name)}。`);
    }
  }
  for (const [name, entry] of Object.entries(value)) {
    const propertySchema = properties[name];
    if (!propertySchema || typeof propertySchema !== "object") {
      if (source.additionalProperties === false) issues.push(`schema 未声明参数 ${name}。`);
      continue;
    }
    const expected = String(propertySchema.type || "");
    if (expected && !matchesJsonType(entry, expected)) {
      issues.push(`参数 ${name} 期望 ${expected}，实际是 ${describeJsonType(entry)}。`);
    }
    if (Array.isArray(propertySchema.enum) && propertySchema.enum.length) {
      const allowed = propertySchema.enum.map((item) => JSON.stringify(item));
      if (!allowed.includes(JSON.stringify(entry))) {
        issues.push(`参数 ${name} 不在枚举范围内。`);
      }
    }
  }
  return { ok: issues.length === 0, issues };
}

/** @param {unknown} value @returns {string} */
function describeJsonType(value) {
  if (value === null) return "null";
  if (Array.isArray(value)) return "array";
  return typeof value;
}

/** @param {unknown} value @param {string} expected @returns {boolean} */
function matchesJsonType(value, expected) {
  switch (expected) {
    case "string": return typeof value === "string";
    case "number": return typeof value === "number" && Number.isFinite(value);
    case "integer": return typeof value === "number" && Number.isInteger(value);
    case "boolean": return typeof value === "boolean";
    case "array": return Array.isArray(value);
    case "object": return Boolean(value) && typeof value === "object" && !Array.isArray(value);
    case "null": return value === null;
    default: return true;
  }
}
