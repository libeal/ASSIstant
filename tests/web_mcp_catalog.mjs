import assert from "node:assert/strict";

import {
  mcpCredentialPresentation,
  mcpDeclaredProtocolLabel,
  mcpManifestVersionLabel,
  mcpProtocolPresentation,
} from "../web/static/modules/mcp-catalog.js";
import {
  MCP_ANNOTATION_CAVEAT,
  mcpAnnotationRows,
  mcpArgumentRows,
  mcpDestructiveWarning,
  mcpSchemaPrecheck,
} from "../web/static/modules/mcp-approval.js";

// --- 协议真相：modern / legacy / 未协商 / 未探测 必须可区分 -----------------
const unprobed = mcpProtocolPresentation({ valid: true });
assert.equal(unprobed.state, "unprobed");
assert.match(unprobed.detail, /加载工具/);

const modern = mcpProtocolPresentation({ contacted: true, protocol_version: "2025-06-18" });
assert.deepEqual(
  { state: modern.state, label: modern.label, kind: modern.kind },
  { state: "modern", label: "2025-06-18", kind: "low" },
);

const legacy = mcpProtocolPresentation({
  contacted: true,
  protocol_version: "2024-11-05",
  fallback_used: true,
  fallback_reason: "streamable_http 返回 405",
});
assert.equal(legacy.state, "legacy", "回退过的会话不能显示成 modern");
assert.equal(legacy.label, "legacy");
assert.equal(legacy.detail, "streamable_http 返回 405", "回退原因必须有可见详情");
assert.equal(legacy.kind, "medium");

// 回退但 server 没给原因时也要有兜底文案，不能留空。
assert.match(mcpProtocolPresentation({ contacted: true, fallback_used: true }).detail, /未提供回退原因/);

const unreachable = mcpProtocolPresentation({ contacted: true });
assert.equal(unreachable.state, "unreachable");
assert.equal(unreachable.kind, "medium");

// --- manifest 声明与实际协商是两回事 ---------------------------------------
assert.equal(
  mcpDeclaredProtocolLabel({ protocol: { mode: "modern_only", require_modern: true } }),
  "声明 modern_only · require_modern",
);
assert.equal(mcpDeclaredProtocolLabel({ protocol: { mode: "modern_then_legacy" } }), "声明 modern_then_legacy");
assert.equal(mcpDeclaredProtocolLabel({}), "");
assert.equal(mcpDeclaredProtocolLabel({ protocol: null }), "");

assert.equal(mcpManifestVersionLabel({ manifest_version: 2 }), "v2");
assert.equal(mcpManifestVersionLabel({}), "");

// --- 凭据绑定只读摘要：只有 id 与是否绑定，绝不含 profile 内容 --------------
const bound = mcpCredentialPresentation({ credential_bound: true, credential_profile_id: "demo-oauth" });
assert.deepEqual(bound, { bound: true, label: "credential: demo-oauth", profileId: "demo-oauth" });

const unbound = mcpCredentialPresentation({ credential_bound: false, credential_profile_id: "" });
assert.equal(unbound.bound, false);
assert.equal(unbound.label, "credential: 未绑定");
assert.equal(unbound.profileId, "");

// credential_bound 为 true 但 id 缺失时按未绑定处理，不编造 id。
assert.equal(mcpCredentialPresentation({ credential_bound: true }).bound, false);
assert.equal(mcpCredentialPresentation(null).label, "credential: 未绑定");

// --- 审批卡：参数表格 ------------------------------------------------------
const rows = mcpArgumentRows({ path: "/var/log", limit: 5, deep: { a: 1 } });
assert.equal(rows.length, 3);
assert.deepEqual(rows[0], { key: "path", value: "/var/log", long: false });
assert.equal(rows[1].value, "5");
assert.equal(rows[2].long, true, "多行 JSON 值应折叠");
assert.deepEqual(mcpArgumentRows(null), []);
assert.deepEqual(mcpArgumentRows([1, 2]), []);
assert.equal(mcpArgumentRows({ big: "x".repeat(201) })[0].long, true);

// --- 审批卡：annotations 单独一组，并且只是 server 的自述 ------------------
assert.deepEqual(
  mcpAnnotationRows({ title: "Read file", readOnlyHint: true }),
  [{ key: "title", value: "Read file" }, { key: "readOnlyHint", value: "true" }],
);
assert.deepEqual(mcpAnnotationRows(null), []);
assert.match(MCP_ANNOTATION_CAVEAT, /不构成安全保证/);

assert.match(mcpDestructiveWarning({ destructiveHint: true }), /destructiveHint/);
assert.equal(mcpDestructiveWarning({ destructiveHint: false }), "");
assert.equal(mcpDestructiveWarning({}), "");
assert.equal(mcpDestructiveWarning(null), "");

// --- 审批卡：客户端预校验只提示，不下结论 ---------------------------------
const schema = {
  type: "object",
  properties: {
    path: { type: "string" },
    limit: { type: "integer" },
    mode: { type: "string", enum: ["fast", "full"] },
  },
  required: ["path"],
  additionalProperties: false,
};

assert.deepEqual(mcpSchemaPrecheck(schema, { path: "/var/log", limit: 5, mode: "fast" }), { ok: true, issues: [] });

const missing = mcpSchemaPrecheck(schema, { limit: 5 });
assert.equal(missing.ok, false);
assert.ok(missing.issues.some((issue) => issue.includes("缺少必填参数 path")));

const wrongType = mcpSchemaPrecheck(schema, { path: "/x", limit: "5" });
assert.ok(wrongType.issues.some((issue) => issue.includes("期望 integer")));

const badEnum = mcpSchemaPrecheck(schema, { path: "/x", mode: "turbo" });
assert.ok(badEnum.issues.some((issue) => issue.includes("枚举")));

const extra = mcpSchemaPrecheck(schema, { path: "/x", nope: 1 });
assert.ok(extra.issues.some((issue) => issue.includes("未声明参数 nope")));

// 没有 schema 或 schema 不可用时不得阻断——最终判定在执行层。
assert.deepEqual(mcpSchemaPrecheck(null, { anything: 1 }), { ok: true, issues: [] });
assert.deepEqual(mcpSchemaPrecheck(undefined, null), { ok: true, issues: [] });
assert.equal(mcpSchemaPrecheck(schema, "not-an-object").ok, false);
// 未声明 additionalProperties:false 时，多余参数不算问题。
assert.deepEqual(
  mcpSchemaPrecheck({ type: "object", properties: { a: { type: "string" } } }, { a: "x", b: 1 }),
  { ok: true, issues: [] },
);

console.log("web_mcp_catalog: ok");
