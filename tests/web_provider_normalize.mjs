import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { normalizeProviderId } from "../web/static/modules/config-utils.js";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const schema = JSON.parse(readFileSync(join(root, "schema/domain.json"), "utf8"));
const rules = schema.provider_normalization || {};

const cases = [
  ["", "openai_compatible"],
  ["openai", "openai"],
  ["OpenAI-Compatible", "openai_compatible"],
  ["openai_compatible / custom", "openai_compatible"],
  ["zhipu", "zhipu_ai"],
  ["ZhipuAI", "zhipu_ai"],
  ["moonshot", "moonshot_ai"],
  ["xAI", "x_ai"],
  ["sarvam", "sarvam_ai"],
  ["nvidia", "nvidia"],
  ["some-new/provider name", "some_new_provider_name"],
];

for (const [input, expected] of cases) {
  const got = normalizeProviderId(input, rules);
  assert.equal(got, expected, `normalizeProviderId(${JSON.stringify(input)}) got ${got}`);
}

console.log("web_provider_normalize: ok");
