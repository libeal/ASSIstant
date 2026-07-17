import assert from "node:assert/strict";

import { createJobClient } from "../web/static/modules/job-client.js";

function delay(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

const calls = [];
let tick = 0;
const jobs = {
  j1: { job_id: "j1", status: "queued", result: null },
};

const client = createJobClient({
  async request(path, options = {}) {
    calls.push({ path, options });
    if (path === "/api/jobs" && options.method === "POST") {
      return { job_id: "j1", status: "queued" };
    }
    if (path === "/api/jobs/j1") {
      tick += 1;
      if (tick === 1) return { job_id: "j1", status: "running", result: null };
      if (tick === 2) {
        return {
          job_id: "j1",
          status: "succeeded",
          result: { ok: true, status: "succeeded", stdout: "done" },
        };
      }
      return jobs.j1;
    }
    if (path === "/api/jobs/j1/cancel") {
      return { ok: true, status: "cancelled" };
    }
    throw new Error(`unexpected path ${path}`);
  },
  getState: () => ({ suspended: false }),
  printOutput() {},
});

const created = await client.createJob("work", "run", { input: "hi" });
assert.equal(created.job_id, "j1");

const progress = [];
const completed = await client.pollJob("j1", "status", "out", {
  intervalMs: 1,
  onProgress: (job) => progress.push(job.status),
});
assert.equal(completed.status, "succeeded");
assert.ok(progress.includes("running"));

const cancel = await client.cancelJob("j1");
assert.equal(cancel.status, "cancelled");
assert.deepEqual(await client.cancelJob(""), { ok: false, status: "missing_job" });

// cancel-wins / suspend
tick = 0;
const suspendedClient = createJobClient({
  async request(path) {
    if (path === "/api/jobs/s1") return { job_id: "s1", status: "running" };
    throw new Error(path);
  },
  getState: () => ({ workSuspended: true }),
  printOutput() {},
});
const suspended = await suspendedClient.pollJob("s1", "status", null, {
  suspendFlag: "workSuspended",
  intervalMs: 1,
});
assert.equal(suspended.status, "suspended");

for (const terminalStatus of ["failed", "cancelled"]) {
  const terminalClient = createJobClient({
    request: async () => ({
      job_id: `terminal-${terminalStatus}`,
      status: terminalStatus,
      result: { ok: false, status: terminalStatus },
    }),
  });
  const terminal = await terminalClient.pollJob(
    `terminal-${terminalStatus}`,
    "status",
  );
  assert.equal(terminal.status, terminalStatus);
}

const backoffDelays = [];
const partialOutputs = [];
let backoffPoll = 0;
const backoffClient = createJobClient({
  async request() {
    backoffPoll += 1;
    if (backoffPoll <= 3) {
      return {
        job_id: "backoff",
        status: "running",
        partial_output: { chunk: backoffPoll },
      };
    }
    return { job_id: "backoff", status: "succeeded", result: { ok: true } };
  },
  delay: async (ms) => backoffDelays.push(ms),
});
const backedOff = await backoffClient.pollJob("backoff", "status", null, {
  intervalMs: 2,
  backoffFactor: 2,
  maxIntervalMs: 5,
  onPartialOutput: (partial) => partialOutputs.push(partial),
});
assert.equal(backedOff.status, "succeeded");
assert.deepEqual(backoffDelays, [2, 4, 5]);
assert.deepEqual(partialOutputs, [{ chunk: 1 }, { chunk: 2 }, { chunk: 3 }]);

let resolveRacePoll;
const raceClient = createJobClient({
  request(path) {
    if (path === "/api/jobs/race") {
      return new Promise((resolve) => {
        resolveRacePoll = resolve;
      });
    }
    if (path === "/api/jobs/race/cancel") {
      return Promise.resolve({
        ok: true,
        status: "cancelled",
        job: { job_id: "race", status: "cancelled" },
      });
    }
    throw new Error(path);
  },
});
const racePoll = raceClient.pollJob("race", "status");
while (!resolveRacePoll) await Promise.resolve();
const raceCancel = raceClient.cancelJob("race");
resolveRacePoll({ job_id: "race", status: "succeeded", result: { ok: true } });
const [raceResult, raceCancellation] = await Promise.all([racePoll, raceCancel]);
assert.equal(raceCancellation.status, "cancelled");
assert.equal(raceResult.status, "cancelled");

console.log("web_job_client: ok");
