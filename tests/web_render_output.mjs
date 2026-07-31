import assert from "node:assert/strict";

import {
  outputSummaryText,
  renderObjectOutputText,
  renderPrimaryOutputHtml,
  terminalReturnPayload,
} from "../web/static/modules/render-output.js";

const malicious = '<script>alert("xss")</script><img src=x onerror=alert(1)>';
const html = renderPrimaryOutputHtml({ summary: 'unsafe " title', stdout: malicious });
assert.doesNotMatch(html, /<script>/i);
assert.doesNotMatch(html, /<img/i);
assert.match(html, /&lt;script&gt;/);
assert.match(html, /&quot;/);

const blockHtml = renderPrimaryOutputHtml({
  output_blocks: [{ kind: "text", title: "输出", text: malicious }],
});
assert.doesNotMatch(blockHtml, /<script>/i);
assert.match(blockHtml, /&lt;script&gt;/);

assert.equal(renderObjectOutputText({ ok: true, stdout: "hello", stderr: "" }), "标准输出: hello");
assert.equal(outputSummaryText({ message: "done" }), "done");
assert.deepEqual(terminalReturnPayload({ command: "printf ok", stdout: "ok", exit_code: 0 }), {
  command: "printf ok",
  stdout: "ok",
});

// --- MCP 结果块 -----------------------------------------------------------
const mcpBlock = {
  kind: "mcp_result",
  title: "MCP 调用结果",
  mcp: {
    server_id: "files",
    tool: "read",
    transport: "stdio",
    protocol_version: "2025-06-18",
    fallback_used: false,
    fallback_reason: "",
    is_error: false,
    content: [
      { type: "text", text: malicious, size_bytes: 64 },
      { type: "image", mime_type: "image/png", size_bytes: 2048 },
      { type: "audio", mime_type: "audio/wav", size_bytes: 4096 },
      { type: "resource_link", uri: "https://evil.test/track.png", name: "l", mime_type: "image/png" },
      { type: "resource", uri: "file:///tmp/a.txt", mime_type: "text/plain", text: malicious, size_bytes: 64 },
      { type: "resource", uri: "file:///tmp/b.bin", mime_type: "application/octet-stream", text: null, size_bytes: 1536 },
      { type: "weird" },
    ],
    structured_content: { rows: 2 },
  },
};
const mcpHtml = renderPrimaryOutputHtml({ output_blocks: [mcpBlock] });

// 转义：外部 server 返回的文本不得变成活动内容。
assert.doesNotMatch(mcpHtml, /<script>/i);
assert.doesNotMatch(mcpHtml, /<img/i);
assert.match(mcpHtml, /&lt;script&gt;/);

// 不生成任何外部资源请求：没有真实的 src/href 属性，URI 只作为文本出现。
// 用「标签内的属性」而不是裸字符串匹配——转义后的文本里本来就含 src=x。
assert.doesNotMatch(mcpHtml, /<[a-z]+[^>]*\ssrc=/i);
assert.doesNotMatch(mcpHtml, /<[a-z]+[^>]*\shref=/i);
assert.doesNotMatch(mcpHtml, /<a\s/i);
assert.match(mcpHtml, /https:\/\/evil\.test\/track\.png/, "resource_link 仍以纯文本展示 URI");

// 媒体只报 MIME 与大小。
assert.match(mcpHtml, /image · image\/png · 2\.0 KB/);
assert.match(mcpHtml, /audio · audio\/wav · 4\.0 KB/);
assert.match(mcpHtml, /resource · application\/octet-stream · 1\.5 KB/);
assert.match(mcpHtml, /structuredContent/);
assert.match(mcpHtml, /不会被自动获取/);
assert.match(mcpHtml, /未知内容类型/);
assert.doesNotMatch(mcpHtml, /isError/);

// isError 与协议回退都要显性呈现。
const erroredHtml = renderPrimaryOutputHtml({
  output_blocks: [{
    ...mcpBlock,
    mcp: { ...mcpBlock.mcp, is_error: true, fallback_used: true, fallback_reason: "streamable_http 不可用" },
  }],
});
assert.match(erroredHtml, /标记为 isError/);
assert.match(erroredHtml, /已回退到 legacy 协议：streamable_http 不可用/);

// 空 content 不应渲染成空白。
const emptyMcpHtml = renderPrimaryOutputHtml({
  output_blocks: [{ kind: "mcp_result", title: "MCP 调用结果", mcp: { server_id: "s", tool: "t", content: [] } }],
});
assert.match(emptyMcpHtml, /server 未返回 content/);

// 摘要与纯文本链路也要认识这种块。
assert.match(outputSummaryText({ output_blocks: [mcpBlock] }), /alert/);

console.log("web_render_output: ok");
