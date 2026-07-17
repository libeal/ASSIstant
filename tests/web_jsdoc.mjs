import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const modules = [
  "audit-view-utils.js",
  "app-bindings.js",
  "config-utils.js",
  "dom.js",
  "job-client.js",
  "layout.js",
  "observer-bootstrap.js",
  "render-output.js",
  "store.js",
  "view-audit.js",
  "view-config.js",
  "view-policy.js",
  "view-skills.js",
  "view-workbench.js",
  "workbench-turns.js",
];

for (const moduleName of modules) {
  const url = new URL(`../web/static/modules/${moduleName}`, import.meta.url);
  const source = await readFile(url, "utf8");
  const exports = [...source.matchAll(/^export (?:async )?function\s+(\w+)\s*\(([^)]*)\)|^export const (\$)\s*=/gm)];
  assert.ok(exports.length > 0, `${moduleName} has no documented exports`);
  for (const match of exports) {
    const name = match[1] || match[3];
    const before = source.slice(0, match.index);
    const commentStart = before.lastIndexOf("/**");
    const commentEnd = before.lastIndexOf("*/");
    assert.ok(commentStart >= 0 && commentEnd > commentStart, `${moduleName}:${name} lacks JSDoc`);
    assert.equal(before.slice(commentEnd + 2).trim(), "", `${moduleName}:${name} JSDoc is not adjacent`);
    const comment = before.slice(commentStart, commentEnd + 2);
    assert.match(comment, /@returns?\b/, `${moduleName}:${name} lacks @returns`);
    if ((match[2] || match[3])?.trim()) {
      assert.match(comment, /@param\b/, `${moduleName}:${name} lacks @param`);
    }
  }
}

const typeUsages = {
  "audit-view-utils.js": "AuditEvent",
  "config-utils.js": "ConfigSnapshot",
  "job-client.js": "Job",
  "render-output.js": "OutputBlock",
  "workbench-turns.js": "Turn",
};
for (const [moduleName, typeName] of Object.entries(typeUsages)) {
  const url = new URL(`../web/static/modules/${moduleName}`, import.meta.url);
  const source = await readFile(url, "utf8");
  assert.match(
    source,
    new RegExp(`import\\(\\"\\./types\\.js\\"\\)\\.${typeName}`),
    `${moduleName} does not consume shared type ${typeName}`,
  );
}

const typesSource = await readFile(new URL("../web/static/modules/types.js", import.meta.url), "utf8");
assert.match(typesSource, /@property \{OutputBlock\[\]\|null\} \[partial_output\]/);

const forbiddenCrossViewCalls = [
  "configInputId",
  "renderSessionTimeline",
  "renderThinkingSummary",
  "remoteSecretTransmissionBlocked",
  "closeApprovalDrawer",
  "replaceSessionTurns",
  "updateSessionLeaveState",
];
for (const moduleName of ["view-audit.js", "view-config.js", "view-skills.js", "view-workbench.js"]) {
  const source = await readFile(new URL(`../web/static/modules/${moduleName}`, import.meta.url), "utf8");
  for (const method of forbiddenCrossViewCalls) {
    assert.doesNotMatch(source, new RegExp(`app\\.${method}\\b`), `${moduleName} calls cross-view app.${method}`);
  }
}

console.log("web_jsdoc: ok");
