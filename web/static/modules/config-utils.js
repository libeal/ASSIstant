import { CONFIG_GROUPS } from "./policy-config.js";

/** @typedef {import("./types.js").ConfigSnapshot} ConfigSnapshot */

/** @param {Record<string, any>} source @param {string} path @returns {any} */
export function getNestedValue(source, path) {
  return String(path || "")
    .split(".")
    .reduce((cursor, key) => (cursor == null ? undefined : cursor[key]), source);
}

/** @param {unknown} value @returns {string} */
export function normalizeProviderId(value) {
  return String(value || "").trim().toLowerCase();
}

/** @param {string} key @returns {string} */
export function configInputId(key) {
  return `config-${String(key).replace(/[^A-Za-z0-9_-]/g, "-")}`;
}

/** @param {ConfigSnapshot|null|undefined} config @returns {boolean} */
export function remoteSecretTransmissionBlocked(config) {
  const remote = config?.remote || {};
  return remote.enabled === true && remote.allow_api_key_transmission !== true;
}

/** @param {{type?: string}} field @param {any} value @returns {any} */
export function normalizeConfigFieldValue(field, value) {
  if (field.type === "provider") return normalizeProviderId(value);
  if (field.type === "boolean") return Boolean(value);
  if (field.type === "number") {
    const number = Number(value);
    return Number.isFinite(number) ? number : 0;
  }
  if (field.type === "host_list") {
    if (Array.isArray(value)) return value.map((item) => String(item));
    if (typeof value === "string") {
      return value
        .split(/[\n,]/)
        .map((item) => item.trim())
        .filter(Boolean);
    }
    return [];
  }
  return value == null ? "" : String(value);
}

/** @param {Record<string, any>} config @param {Array<Record<string, any>>} [groups] @returns {Record<string, any>} */
export function collectEditableConfigValues(config, groups = CONFIG_GROUPS) {
  const values = {};
  for (const group of groups) {
    for (const field of group.fields) {
      if (field.writeOnly) {
        values[field.key] = "";
        continue;
      }
      const rawValue = field.key === "provider" ? (config.provider_id || config.provider) : getNestedValue(config, field.key);
      values[field.key] = normalizeConfigFieldValue(field, rawValue);
    }
  }
  return values;
}

/** @param {Record<string, any>} draft @param {Record<string, any>} original @param {Set<string>} [excludeKeys] @returns {Record<string, any>} */
export function pendingConfigChanges(draft, original, excludeKeys = new Set()) {
  const changes = {};
  for (const [key, value] of Object.entries(draft || {})) {
    if (excludeKeys.has(key)) continue;
    if (JSON.stringify(value) !== JSON.stringify((original || {})[key])) {
      changes[key] = value;
    }
  }
  return changes;
}
