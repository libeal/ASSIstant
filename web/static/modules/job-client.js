/** @typedef {import("./types.js").Job} Job */

/**
 * Job create/cancel/poll client with injectable request for unit tests.
 * @param {{
 *   request: (path: string, options?: object) => Promise<any>,
 *   getState?: () => object,
 *   printOutput?: (id: string, value: any) => void,
 *   setStatus?: (id: string, value: string, kind?: string) => void,
 *   delay?: (ms: number) => Promise<void>,
 * }} deps
 * @returns {{
 *   createJob: (resource: string, action: string, payload: Record<string, unknown>) => Promise<Job>,
 *   cancelJob: (jobId: string) => Promise<Record<string, any>>,
 *   pollJob: (jobId: string, statusId: string, outputId?: string, options?: object) => Promise<Job|Record<string, any>>,
 * }}
 */
export function createJobClient(deps) {
  const request = deps.request;
  const getState = deps.getState || (() => ({}));
  const printOutput = deps.printOutput || (() => {});
  const setStatus = deps.setStatus || (() => {});
  const delay =
    deps.delay ||
    ((ms) => new Promise((resolve) => {
      const timer = globalThis.setTimeout || setTimeout;
      timer(resolve, ms);
    }));
  const cancellationRequests = new Map();

  async function createJob(resource, action, payload) {
    return request("/api/jobs", {
      method: "POST",
      body: { resource, action, payload },
    });
  }

  async function cancelJob(jobId) {
    if (!jobId) return { ok: false, status: "missing_job" };
    if (cancellationRequests.has(jobId)) return cancellationRequests.get(jobId);
    const cancellation = request(`/api/jobs/${jobId}/cancel`, { method: "POST", body: {} });
    cancellationRequests.set(jobId, cancellation);
    try {
      const result = await cancellation;
      if (!result?.ok || result?.status !== "cancelled") {
        cancellationRequests.delete(jobId);
      }
      return result;
    } catch (error) {
      cancellationRequests.delete(jobId);
      throw error;
    }
  }

  async function completedCancellation(jobId) {
    const cancellation = cancellationRequests.get(jobId);
    if (!cancellation) return null;
    const result = await cancellation;
    cancellationRequests.delete(jobId);
    if (!result?.ok || result?.status !== "cancelled") return null;
    return result.job || { ...result, job_id: result.job_id || jobId };
  }

  /**
   * Poll a job until terminal status.
   * @param {string} jobId
   * @param {string} statusId
   * @param {string} [outputId]
   * @param {{
   *   onProgress?: (job: Job) => void,
   *   onPartialOutput?: (partialOutput: import("./types.js").OutputBlock[], job: Job) => void,
   *   suspendFlag?: string,
   *   intervalMs?: number,
   *   backoffFactor?: number,
   *   maxIntervalMs?: number,
   * }} [options]
   * @returns {Promise<Job|Record<string, any>>}
   */
  async function pollJob(jobId, statusId, outputId, options = {}) {
    setStatus(statusId, "running", "running");
    if (outputId) printOutput(outputId, { status: "running" });
    const configuredInterval = Number(options.intervalMs ?? 500);
    const configuredBackoff = Number(options.backoffFactor ?? 1.5);
    const configuredMaximum = Number(options.maxIntervalMs ?? 2000);
    let intervalMs = Number.isFinite(configuredInterval) && configuredInterval >= 0
      ? configuredInterval
      : 500;
    const backoffFactor = Number.isFinite(configuredBackoff) && configuredBackoff >= 1
      ? configuredBackoff
      : 1.5;
    const maxIntervalMs = Number.isFinite(configuredMaximum) && configuredMaximum >= intervalMs
      ? configuredMaximum
      : Math.max(intervalMs, 2000);
    for (;;) {
      if (options.suspendFlag && getState()[options.suspendFlag]) {
        setStatus(statusId, "suspended", "medium");
        return { status: "suspended", job_id: jobId };
      }
      const cancellationBeforePoll = await completedCancellation(jobId);
      if (cancellationBeforePoll) {
        setStatus(statusId, "cancelled", "failed");
        return cancellationBeforePoll;
      }
      const job = await request(`/api/jobs/${jobId}`);
      const cancellationAfterPoll = await completedCancellation(jobId);
      if (cancellationAfterPoll) {
        setStatus(statusId, "cancelled", "failed");
        return cancellationAfterPoll;
      }
      if (job.status === "queued" || job.status === "running") {
        if (job.partial_output !== undefined && job.partial_output !== null) {
          if (outputId) printOutput(outputId, job.partial_output);
          if (typeof options.onPartialOutput === "function") {
            options.onPartialOutput(job.partial_output, job);
          }
        }
        if (typeof options.onProgress === "function") options.onProgress(job);
        await delay(intervalMs);
        intervalMs = Math.min(maxIntervalMs, intervalMs * backoffFactor);
        continue;
      }
      const resultStatus = job.result?.status || job.status;
      const kind =
        resultStatus === "approval_required"
          ? "approval_required"
          : job.status === "succeeded"
            ? "ok"
            : "failed";
      setStatus(statusId, resultStatus, kind);
      return job;
    }
  }

  return { createJob, cancelJob, pollJob };
}
