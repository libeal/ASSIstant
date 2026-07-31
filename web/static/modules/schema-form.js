/**
 * Shared JSON-Schema form controls.
 *
 * Extracted from the MCP elicitation drawer so Skill parameter forms can reuse
 * exactly the same rendering and value collection. This module carries no MCP
 * protocol semantics: it renders a small, closed subset of JSON Schema
 * (`string` / `number` / `integer` / `boolean`, `array` of `string`, and
 * `enum` as a constraint) and nothing else.
 *
 * Field labels and descriptions may come from an external MCP server, so every
 * value is escaped and never interpreted.
 */

import { escapeHtml } from "./dom.js";

/**
 * @param {string} scope grouping key, e.g. an elicitation request id
 * @param {string} propertyName
 * @param {Record<string, any>|null} schema
 * @param {boolean} required
 * @returns {string}
 */
export function schemaFieldHtml(scope, propertyName, schema, required) {
  const encodedScope = encodeURIComponent(scope);
  const encodedProperty = encodeURIComponent(propertyName);
  const label = schema?.title || propertyName;
  const description = schema?.description || "";
  const attributes = `data-mcp-request-key="${escapeHtml(encodedScope)}" data-mcp-property="${escapeHtml(encodedProperty)}"`;
  const requiredAttribute = required ? " required" : "";
  const hasDefault = schema ? Object.prototype.hasOwnProperty.call(schema, "default") : false;
  let control = "";
  if (Array.isArray(schema?.enum) && schema.enum.length) {
    const options = schema.enum.map((value) => {
      const encoded = encodeURIComponent(JSON.stringify(value));
      const selected = hasDefault && JSON.stringify(value) === JSON.stringify(schema?.default) ? " selected" : "";
      return `<option value="${escapeHtml(encoded)}"${selected}>${escapeHtml(String(value))}</option>`;
    }).join("");
    control = `<select class="select" ${attributes} data-mcp-value-kind="enum"${requiredAttribute}>${options}</select>`;
  } else if (schema?.type === "boolean") {
    const checked = hasDefault && schema?.default === true ? " checked" : "";
    control = `<input type="checkbox" ${attributes} data-mcp-value-kind="boolean"${checked}>`;
  } else if (schema?.type === "integer" || schema?.type === "number") {
    const step = schema.type === "integer" ? "1" : "any";
    const min = Number.isFinite(schema.minimum) ? ` min="${escapeHtml(schema.minimum)}"` : "";
    const max = Number.isFinite(schema.maximum) ? ` max="${escapeHtml(schema.maximum)}"` : "";
    const value = hasDefault ? ` value="${escapeHtml(schema?.default)}"` : "";
    control = `<input class="field" type="number" step="${step}" ${attributes} data-mcp-value-kind="${schema.type}"${min}${max}${value}${requiredAttribute}>`;
  } else if (schema?.type === "array" && schema?.items?.type === "string") {
    const value = hasDefault && Array.isArray(schema?.default) ? escapeHtml(schema.default.join("\n")) : "";
    control = `<textarea class="textarea mcp-array-input" ${attributes} data-mcp-value-kind="string-array"${requiredAttribute}>${value}</textarea>`;
  } else {
    const format = schema?.format === "email" ? "email" : schema?.format === "uri" ? "url" : "text";
    const min = Number.isInteger(schema?.minLength) ? ` minlength="${schema?.minLength}"` : "";
    const max = Number.isInteger(schema?.maxLength) ? ` maxlength="${schema?.maxLength}"` : "";
    const value = hasDefault ? ` value="${escapeHtml(schema?.default)}"` : "";
    control = `<input class="field" type="${format}" ${attributes} data-mcp-value-kind="string"${min}${max}${value}${requiredAttribute}>`;
  }
  return `<label class="small mcp-input-field"><span>${escapeHtml(label)}${required ? " *" : ""}</span>${control}${description ? `<small>${escapeHtml(description)}</small>` : ""}</label>`;
}

/**
 * Render every declared property of an object schema, or return "" when the
 * schema is not the supported flat-object shape — callers fall back to a raw
 * JSON textbox in that case rather than rendering a half-form.
 * @param {string} scope
 * @param {Record<string, any>|null|undefined} schema
 * @returns {string}
 */
export function schemaFormHtml(scope, schema) {
  const properties = schema?.properties && typeof schema.properties === "object" && !Array.isArray(schema.properties)
    ? schema.properties
    : null;
  if (!properties || !Object.keys(properties).length) return "";
  const required = new Set(Array.isArray(schema?.required) ? schema.required : []);
  return Object.entries(properties)
    .map(([name, propertySchema]) => schemaFieldHtml(scope, name, propertySchema, required.has(name)))
    .join("");
}

/** @param {unknown} schema @returns {boolean} */
export function schemaIsRenderable(schema) {
  return schemaFormHtml("probe", /** @type {any} */ (schema)) !== "";
}

/**
 * Read one rendered control back into a JSON value.
 * @param {{dataset: Record<string, string>, value?: string, checked?: boolean}} control
 * @returns {unknown}
 */
export function schemaControlValue(control) {
  const kind = control?.dataset?.mcpValueKind || "string";
  if (kind === "boolean") return Boolean(control?.checked);
  if (kind === "integer") return Number.parseInt(String(control?.value ?? ""), 10);
  if (kind === "number") return Number(control?.value);
  if (kind === "string-array") {
    return String(control?.value ?? "").split(/[\n,]/).map((item) => item.trim()).filter(Boolean);
  }
  if (kind === "enum") return JSON.parse(decodeURIComponent(String(control?.value ?? "")));
  return String(control?.value ?? "");
}
