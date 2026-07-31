import assert from "node:assert/strict";

import {
  MCP_INPUT_SOURCE_NOTICE,
  MCP_INPUT_URGENT_MS,
  mcpInputExpiry,
  mcpInputExpiryHtml,
  mcpInputMetaRows,
  mcpInputRequestHtml,
  mcpInputRequestsHtml,
} from "../web/static/modules/mcp-input.js";

// --- 默认响应必须是 decline ---------------------------------------------
const formHtml = mcpInputRequestHtml("req-1", {
  params: { mode: "form", message: "请提供凭据", requestedSchema: { properties: { user: { type: "string" } } } },
});
assert.match(formHtml, /<option value="decline" selected>decline<\/option>/);
assert.ok(
  formHtml.indexOf('value="decline"') < formHtml.indexOf('value="accept"'),
  "decline must be the first option so the browser default is not accept",
);
assert.doesNotMatch(formHtml, /<option value="accept" selected>/);

const urlHtml = mcpInputRequestHtml("req-2", { params: { mode: "url", url: "https://example.test/a" } });
assert.match(urlHtml, /<option value="decline" selected>decline<\/option>/);
assert.ok(urlHtml.indexOf('value="decline"') < urlHtml.indexOf('value="accept"'));

// 非 http(s) 的 URL 不得渲染成可点击链接。
const fileUrlHtml = mcpInputRequestHtml("req-3", { params: { mode: "url", url: "file:///etc/shadow" } });
assert.doesNotMatch(fileUrlHtml, /<a /);
assert.match(fileUrlHtml, /<code class="mcp-input-url">file:\/\/\/etc\/shadow<\/code>/);

// --- 外部 server 提供的文案按不可信数据转义 -------------------------------
const xssHtml = mcpInputRequestHtml("req-4", {
  params: {
    mode: "form",
    message: '<img src=x onerror="alert(1)">',
    requestedSchema: {
      properties: { "<script>": { type: "string", title: "</label><script>alert(2)</script>", description: "<b>x</b>" } },
      required: ["<script>"],
    },
  },
});
assert.doesNotMatch(xssHtml, /<img /);
assert.doesNotMatch(xssHtml, /<script>/);
assert.match(xssHtml, /&lt;img src=x onerror=/);

// --- 倒计时边界 -----------------------------------------------------------
const now = 1_700_000_000_000;
const nowSeconds = now / 1000;

const unknown = mcpInputExpiry(null, now);
assert.deepEqual(
  { known: unknown.known, expired: unknown.expired, label: unknown.label },
  { known: false, expired: false, label: "未提供" },
);
assert.equal(mcpInputExpiry("not-a-number", now).known, false);
assert.equal(mcpInputExpiry(0, now).known, false);

const expired = mcpInputExpiry(nowSeconds - 1, now);
assert.equal(expired.expired, true);
assert.equal(expired.remainingMs, 0);
assert.equal(expired.label, "已过期");

// 正好到点也算过期：不能让用户提交一轮已经作废的 elicitation。
assert.equal(mcpInputExpiry(nowSeconds, now).expired, true);

const urgentEdge = mcpInputExpiry(nowSeconds + MCP_INPUT_URGENT_MS / 1000, now);
assert.equal(urgentEdge.expired, false);
assert.equal(urgentEdge.urgent, true, "剩余恰好 30s 属于紧急区间");

const notUrgent = mcpInputExpiry(nowSeconds + MCP_INPUT_URGENT_MS / 1000 + 1, now);
assert.equal(notUrgent.urgent, false);

assert.equal(mcpInputExpiry(nowSeconds + 45, now).label, "剩余 45 秒");
assert.equal(mcpInputExpiry(nowSeconds + 125, now).label, "剩余 2 分 05 秒");

// --- 过期状态渲染 ---------------------------------------------------------
const expiredHtml = mcpInputExpiryHtml(expired);
assert.match(expiredHtml, /class="mcp-input-expiry expired"/);
assert.match(expiredHtml, /本轮 elicitation 已过期，请重新发起。/);

const urgentHtml = mcpInputExpiryHtml(urgentEdge);
assert.match(urgentHtml, /class="mcp-input-expiry urgent"/);
assert.doesNotMatch(urgentHtml, /已过期/);

const calmHtml = mcpInputExpiryHtml(notUrgent);
assert.match(calmHtml, /class="mcp-input-expiry"/);

// --- 元信息必须带 transport 与有效期 --------------------------------------
const rows = mcpInputMetaRows(
  { server_id: "files", tool: "read", protocol_version: "2025-06-18", transport: "streamable_http", round: 2 },
  urgentEdge,
);
const rowMap = new Map(rows);
assert.equal(rowMap.get("传输"), "streamable_http");
assert.equal(rowMap.get("有效期"), urgentEdge.label);
assert.equal(rowMap.get("协议"), "2025-06-18");
assert.equal(rowMap.get("轮次"), "2");

const emptyRows = new Map(mcpInputMetaRows(null, unknown));
assert.equal(emptyRows.get("有效期"), "未提供");
assert.equal(emptyRows.get("轮次"), "1");

// --- 多请求拼装与固定说明 --------------------------------------------------
const allHtml = mcpInputRequestsHtml({
  a: { params: { mode: "form", message: "A" } },
  b: { params: { mode: "url", url: "https://example.test/b" } },
});
assert.equal((allHtml.match(/class="mcp-input-request"/g) || []).length, 2);
assert.equal(mcpInputRequestsHtml(null), "");
assert.match(MCP_INPUT_SOURCE_NOTICE, /外部 MCP server/);

console.log("web_mcp_input: ok");
