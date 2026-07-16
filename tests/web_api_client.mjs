import assert from "node:assert/strict";

import { requestJson } from "../web/static/modules/api.js";

const originalFetch = globalThis.fetch;

try {
  globalThis.fetch = async () => ({
    ok: false,
    status: 409,
    json: async () => ({ ok: false, status: "sudo_required", error: "sudo required" }),
  });
  const domainFailure = await requestJson("/api/policies/write");
  assert.equal(domainFailure.ok, false);
  assert.equal(domainFailure.status, "sudo_required");

  globalThis.fetch = async () => ({
    ok: false,
    status: 502,
    json: async () => ({ status: "bad_gateway" }),
  });
  await assert.rejects(
    requestJson("/api/health"),
    /bad_gateway/,
    "non-domain HTTP failures must still reject",
  );
} finally {
  globalThis.fetch = originalFetch;
}

console.log("web_api_client: ok");
