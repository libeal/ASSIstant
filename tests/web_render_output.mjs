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

console.log("web_render_output: ok");
