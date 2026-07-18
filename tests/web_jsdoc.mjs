import assert from "node:assert/strict";
import { readdir, readFile } from "node:fs/promises";

const modulesDirectory = new URL("../web/static/modules/", import.meta.url);
const modules = (await readdir(modulesDirectory))
  .filter((name) => name.endsWith(".js"))
  .sort();

let documentedExportCount = 0;

for (const moduleName of modules) {
  const url = new URL(`../web/static/modules/${moduleName}`, import.meta.url);
  const source = await readFile(url, "utf8");
  const exports = [...source.matchAll(/^export (?:async )?function\s+(\w+)\s*\(([^)]*)\)|^export const (\$)\s*=/gm)];
  for (const match of exports) {
    documentedExportCount += 1;
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
assert.ok(documentedExportCount >= 70, `expected broad public JSDoc coverage, got ${documentedExportCount}`);

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
assert.match(typesSource, /@typedef \{object\} AppContext/);
assert.match(typesSource, /@typedef \{AppContext & AuditViewContract/);

const appSource = await readFile(new URL("../web/static/app.js", import.meta.url), "utf8");
assert.match(appSource, /import\("\.\/modules\/types\.js"\)\.ApplicationController/);
assert.doesNotMatch(appSource, /@type \{Record<string, any>\} Shared runtime bag/);

const jsconfigSource = await readFile(new URL("../jsconfig.json", import.meta.url), "utf8");
const jsconfig = JSON.parse(jsconfigSource);
assert.equal(jsconfig.compilerOptions.allowJs, true);
assert.equal(jsconfig.compilerOptions.checkJs, true);
assert.equal(jsconfig.compilerOptions.noEmit, true);
assert.deepEqual(jsconfig.include, ["web/static/**/*.js"]);

const lintSource = await readFile(new URL("../scripts/lint.sh", import.meta.url), "utf8");
assert.match(lintSource, /tsc --project jsconfig\.json/);
assert.match(lintSource, /CI:-.*LINUX_AGENT_REQUIRE_TSC/);
assert.match(lintSource, /fail "tsc 未安装/);

for (const workflow of ["ci.yml", "remote-release.yml"]) {
  const source = await readFile(new URL(`../.github/workflows/${workflow}`, import.meta.url), "utf8");
  assert.match(source, /npm install --global 'typescript@5\.7\.3'/, `${workflow} does not pin TypeScript`);
  assert.match(source, /command -v tsc/, `${workflow} does not verify tsc installation`);
}

const viewTypeExpectations = {
  "view-audit.js": ["AppContext", "AuditView"],
  "view-config.js": ["AppContext", "ConfigView"],
  "view-policy.js": ["AppContext", "PolicyView"],
  "view-skills.js": ["AppContext", "SkillsView"],
  "view-workbench.js": ["AppContext", "WorkbenchView"],
  "observer-bootstrap.js": ["AppContext", "ObserverBootstrapView"],
};
for (const [moduleName, [contextType, returnType]] of Object.entries(viewTypeExpectations)) {
  const source = await readFile(new URL(`../web/static/modules/${moduleName}`, import.meta.url), "utf8");
  assert.match(source, new RegExp(`import\\(\"\\./types\\.js\"\\)\\.${contextType}`));
  assert.match(source, new RegExp(`@param \\{${contextType}\\} app`));
  assert.match(source, new RegExp(`@returns \\{${returnType}\\}`));
  assert.doesNotMatch(source, /@param \{(?:any|Record<string, any>)\} app/);
}

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
