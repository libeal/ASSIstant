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
  const hasDefault = schema ? Object.prototype.hasOwnProperty.call(schema, "default") : false;
  const presenceAttributes = ` data-schema-required="${required ? "true" : "false"}" data-schema-has-default="${hasDefault ? "true" : "false"}"`;
  let control = "";
  if (Array.isArray(schema?.enum) && schema.enum.length) {
    const unset = !required && !hasDefault ? '<option value="" selected>未设置</option>' : "";
    const options = schema.enum.map((value) => {
      const encoded = encodeURIComponent(JSON.stringify(value));
      const selected = hasDefault && JSON.stringify(value) === JSON.stringify(schema?.default) ? " selected" : "";
      return `<option value="${escapeHtml(encoded)}"${selected}>${escapeHtml(String(value))}</option>`;
    }).join("");
    control = `<select class="select" ${attributes} data-mcp-value-kind="enum"${presenceAttributes}>${unset}${options}</select>`;
  } else if (schema?.type === "boolean") {
    if (!required && !hasDefault) {
      control = `<select class="select" ${attributes} data-mcp-value-kind="optional-boolean"${presenceAttributes}><option value="" selected>未设置</option><option value="true">true</option><option value="false">false</option></select>`;
    } else {
      const checked = hasDefault && schema?.default === true ? " checked" : "";
      control = `<input type="checkbox" ${attributes} data-mcp-value-kind="boolean"${presenceAttributes}${checked}>`;
    }
  } else if (schema?.type === "integer" || schema?.type === "number") {
    const step = schema.type === "integer" ? "1" : "any";
    const min = Number.isFinite(schema.minimum) ? ` min="${escapeHtml(schema.minimum)}"` : "";
    const max = Number.isFinite(schema.maximum) ? ` max="${escapeHtml(schema.maximum)}"` : "";
    const value = hasDefault ? ` value="${escapeHtml(schema?.default)}"` : "";
    control = `<input class="field" type="number" step="${step}" ${attributes} data-mcp-value-kind="${schema.type}"${presenceAttributes}${min}${max}${value}>`;
  } else if (schema?.type === "array" && schema?.items?.type === "string") {
    const initial = hasDefault && Array.isArray(schema?.default)
      ? JSON.stringify(schema.default, null, 2)
      : required ? "[]" : "";
    control = `<textarea class="textarea mcp-array-input" ${attributes} data-mcp-value-kind="string-array"${presenceAttributes}>${escapeHtml(initial)}</textarea>`;
  } else {
    const format = schema?.format === "email" ? "email" : schema?.format === "uri" ? "url" : "text";
    const minLength = schema?.minLength;
    const min = Number.isInteger(minLength) ? ` minlength="${minLength}"` : "";
    const max = Number.isInteger(schema?.maxLength) ? ` maxlength="${schema?.maxLength}"` : "";
    const value = hasDefault ? ` value="${escapeHtml(schema?.default)}"` : "";
    const mustBeNonEmpty = (Number.isInteger(minLength) && minLength > 0)
      || format === "email"
      || format === "url";
    const nonEmptyAttribute = mustBeNonEmpty ? ' data-schema-nonempty="true"' : "";
    const requiredAttribute = required && mustBeNonEmpty ? " required" : "";
    control = `<input class="field" type="${format}" ${attributes} data-mcp-value-kind="string"${presenceAttributes}${nonEmptyAttribute}${min}${max}${value}${requiredAttribute}>`;
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
  if (schema?.additionalProperties === true) return "";
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
 * @returns {unknown|undefined}
 */
export function schemaControlValue(control) {
  const kind = control?.dataset?.mcpValueKind || "string";
  const raw = String(control?.value ?? "");
  const mayOmit = control?.dataset?.schemaRequired !== "true"
    && control?.dataset?.schemaHasDefault !== "true";
  if (kind === "boolean") return Boolean(control?.checked);
  if (kind === "optional-boolean") {
    if (!raw) return undefined;
    return raw === "true";
  }
  if ((kind === "integer") || (kind === "number")) {
    if (!raw) return undefined;
    return kind === "integer" ? Number.parseInt(raw, 10) : Number(raw);
  }
  if (kind === "string-array") {
    if (mayOmit && raw.trim() === "") return undefined;
    const values = JSON.parse(raw);
    if (!Array.isArray(values) || !values.every((item) => typeof item === "string")) {
      throw new TypeError("string-array control must contain a JSON string array");
    }
    return values;
  }
  if (kind === "enum") return raw ? JSON.parse(decodeURIComponent(raw)) : undefined;
  return mayOmit && raw === "" ? undefined : raw;
}

/**
 * Collect a rendered object-schema form without inventing values for optional
 * controls that the user left unset.
 * @param {Iterable<any>|ArrayLike<any>} controls
 * @param {string} invalidMessage
 * @returns {Record<string, unknown>}
 */
export function schemaFormValues(controls, invalidMessage) {
  const values = {};
  for (const control of Array.from(controls || [])) {
    if (typeof control?.reportValidity === "function" && !control.reportValidity()) {
      throw new Error(invalidMessage);
    }
    const property = decodeURIComponent(control?.dataset?.mcpProperty || "");
    let value;
    try {
      value = schemaControlValue(control);
    } catch {
      throw new Error(invalidMessage);
    }
    if (!property) continue;
    if (value === undefined) {
      if (control?.dataset?.schemaRequired === "true") throw new Error(invalidMessage);
      continue;
    }
    if (control?.dataset?.schemaNonempty === "true" && value === "") {
      throw new Error(invalidMessage);
    }
    values[property] = value;
  }
  return values;
}
