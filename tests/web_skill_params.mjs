import assert from "node:assert/strict";

import {
  schemaControlValue,
  schemaFieldHtml,
  schemaFormHtml,
  schemaIsRenderable,
} from "../web/static/modules/schema-form.js";
import {
  groupToolsForSelect,
  guardSummary,
  skillGuardSummaries,
  skillPackageRows,
} from "../web/static/modules/skill-catalog.js";

// --- 共享 schema control：支持的子集 ---------------------------------------
const stringField = schemaFieldHtml("s", "path", { type: "string", title: "路径", default: "/var" }, true);
assert.match(stringField, /type="text"/);
assert.match(stringField, /value="\/var"/);
assert.match(stringField, /路径 \*/, "必填项要有可见标记");
assert.match(stringField, /data-mcp-value-kind="string"/);
assert.match(stringField, / required/);

const intField = schemaFieldHtml("s", "top_n", { type: "integer", default: 10 }, false);
assert.match(intField, /type="number"/);
assert.match(intField, /step="1"/);
assert.match(intField, /value="10"/);
assert.doesNotMatch(intField, / required/);

const boolField = schemaFieldHtml("s", "include_journal", { type: "boolean", default: false }, false);
assert.match(boolField, /type="checkbox"/);
assert.doesNotMatch(boolField, /checked/, "default false 不得预勾选");
assert.match(schemaFieldHtml("s", "x", { type: "boolean", default: true }, false), /checked/);

const arrayField = schemaFieldHtml("s", "tags", { type: "array", items: { type: "string" }, default: ["a", "b"] }, false);
assert.match(arrayField, /data-mcp-value-kind="string-array"/);
assert.match(arrayField, />a\nb</);

const enumField = schemaFieldHtml("s", "mode", { type: "string", enum: ["fast", "full"], default: "full" }, false);
assert.match(enumField, /data-mcp-value-kind="enum"/);
assert.match(enumField, /<option value="%22full%22" selected>full<\/option>/);

// 外部提供的 title / description 一律转义。
const hostile = schemaFieldHtml("s", "x", {
  type: "string",
  title: '</label><script>alert(1)</script>',
  description: '<img src=x onerror=alert(2)>',
}, false);
assert.doesNotMatch(hostile, /<script>/);
assert.doesNotMatch(hostile, /<img/);

// --- 表单装配与回落 -------------------------------------------------------
const form = schemaFormHtml("scope", {
  type: "object",
  properties: { a: { type: "string" }, b: { type: "integer" } },
  required: ["a"],
});
assert.equal((form.match(/mcp-input-field/g) || []).length, 2);
assert.ok(schemaIsRenderable({ type: "object", properties: { a: { type: "string" } } }));

// 没有可渲染属性时返回空串，调用方据此回落到 JSON 文本框。
assert.equal(schemaFormHtml("scope", null), "");
assert.equal(schemaFormHtml("scope", {}), "");
assert.equal(schemaFormHtml("scope", { type: "object", properties: {} }), "");
assert.equal(schemaFormHtml("scope", { type: "object", properties: [] }), "");
assert.equal(schemaIsRenderable(undefined), false);

// --- 控件回读 -------------------------------------------------------------
assert.equal(schemaControlValue({ dataset: { mcpValueKind: "boolean" }, checked: true }), true);
assert.equal(schemaControlValue({ dataset: { mcpValueKind: "integer" }, value: "7" }), 7);
assert.equal(schemaControlValue({ dataset: { mcpValueKind: "number" }, value: "1.5" }), 1.5);
assert.deepEqual(
  schemaControlValue({ dataset: { mcpValueKind: "string-array" }, value: "a\n b ,c\n\n" }),
  ["a", "b", "c"],
);
assert.equal(
  schemaControlValue({ dataset: { mcpValueKind: "enum" }, value: encodeURIComponent(JSON.stringify("full")) }),
  "full",
);
assert.equal(schemaControlValue({ dataset: {}, value: "plain" }), "plain");

// --- Skill 选择器分组与过滤 ------------------------------------------------
const tools = [
  { ref: "ops-basic/disk-hotspots", skill: "ops-basic", category: "system", description: "磁盘热点" },
  { ref: "ops-basic/log-search", skill: "ops-basic", category: "system", description: "日志检索" },
  { ref: "container-inspect/container-inspect", skill: "container-inspect", category: "container", description: "容器" },
];
const groups = groupToolsForSelect(tools);
assert.deepEqual(groups.map((group) => group.label), ["container / container-inspect", "system / ops-basic"]);
assert.equal(groups[1].tools.length, 2);

assert.deepEqual(groupToolsForSelect(tools, "日志").map((group) => group.label), ["system / ops-basic"]);
assert.equal(groupToolsForSelect(tools, "日志")[0].tools.length, 1);
assert.deepEqual(groupToolsForSelect(tools, "container").map((group) => group.label), ["container / container-inspect"]);
// 过滤同时命中 ref、分类和描述；无匹配时返回空分组而不是全量。
assert.deepEqual(groupToolsForSelect(tools, "nothing-matches"), []);
assert.deepEqual(groupToolsForSelect(null), []);

// --- 包信息面板 -----------------------------------------------------------
const rows = new Map(skillPackageRows({
  ref: "ops-basic/safe-log-cleanup",
  skill: "ops-basic",
  package_version: "1.0.0",
  core_api: 1,
  origin: "builtin",
  category: "system",
  risk: "high",
  approval_scope: "skill_mutating",
  execution_class: "host_helper",
  capability: "firewall.apply",
}));
assert.equal(rows.get("package_version"), "1.0.0");
assert.equal(rows.get("core_api"), "1");
assert.equal(rows.get("来源"), "builtin");
assert.equal(rows.get("审批范围"), "skill_mutating");
assert.equal(rows.get("执行类"), "host_helper · firewall.apply");
assert.deepEqual(skillPackageRows(null), []);

// 后端没给包字段时如实显示「未提供」，不编造。
const sparse = new Map(skillPackageRows({ ref: "x/y", skill: "x" }));
assert.equal(sparse.get("package_version"), "未提供");
assert.equal(sparse.get("审批范围"), "未声明");

// --- guards 摘要 ----------------------------------------------------------
assert.equal(
  guardSummary({ type: "backup_proof", message: "真实变更必须先完成目标备份。" }),
  "backup_proof：真实变更必须先完成目标备份。",
);
assert.match(guardSummary({ type: "backup_proof", source: { tool: "system.config.backup" } }), /system\.config\.backup/);
assert.match(guardSummary({ type: "risk_by_value", field: "dry_run" }), /dry_run/);
assert.match(guardSummary({ type: "runner_fallthrough", field: "mode" }), /mode/);
assert.match(guardSummary({}), /unknown/);

assert.deepEqual(skillGuardSummaries({ guards: [] }), []);
assert.deepEqual(skillGuardSummaries(null), []);
assert.equal(skillGuardSummaries({ guards: [{ type: "backup_proof", message: "m" }] }).length, 1);

console.log("web_skill_params: ok");
