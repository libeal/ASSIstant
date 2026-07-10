import assert from "node:assert/strict";

import { renderMarkdown } from "../web/static/modules/markdown.js";
import { renderOutputBlocksHtml } from "../web/static/modules/output-blocks.js";

const markdown = [
  "# 检查结果",
  "",
  "- 磁盘正常",
  "- **服务**需要关注",
  "",
  "1. 读取日志",
  "2. 执行 `systemctl status`",
  "",
  "```sh",
  "echo '<unsafe>'",
  "```",
  "",
  "<script>alert('xss')</script>",
].join("\n");

const html = renderMarkdown(markdown);
assert.match(html, /<h1>检查结果<\/h1>/);
assert.match(html, /<ul><li>磁盘正常<\/li><li><strong>服务<\/strong>需要关注<\/li><\/ul>/);
assert.match(html, /<ol><li>读取日志<\/li><li>执行 <code>systemctl status<\/code><\/li><\/ol>/);
assert.match(html, /<pre><code>echo '&lt;unsafe&gt;'<\/code><\/pre>/);
assert.match(html, /&lt;script&gt;alert\('xss'\)&lt;\/script&gt;/);
assert.doesNotMatch(html, /<script>/);

const hostileHtml = renderMarkdown("**<img src=x onerror=alert(1)>**\n\n`</code><script>alert(1)</script>`");
assert.match(hostileHtml, /&lt;img src=x onerror=alert\(1\)&gt;/);
assert.doesNotMatch(hostileHtml, /<(?:img|script)\b/i);

const outputHtml = renderOutputBlocksHtml([
  { kind: "markdown", title: "最终回答", text: "## 摘要\n\n- 完成" },
]);
assert.match(outputHtml, /class="output-markdown"/);
assert.match(outputHtml, /<h2>摘要<\/h2>/);
assert.match(outputHtml, /<ul><li>完成<\/li><\/ul>/);

console.log("web_markdown: ok");
