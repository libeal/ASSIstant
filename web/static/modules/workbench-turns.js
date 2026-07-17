import { normalizeExecutionEntries } from "./timeline.js";

/** @typedef {import("./types.js").ConfigSnapshot} ConfigSnapshot */
/** @typedef {import("./types.js").StepEntry} StepEntry */
/** @typedef {import("./types.js").Turn} Turn */

/** @param {StepEntry} entry @returns {string} */
export function entryStepKey(entry) {
  return String(
    entry?.output?.id
      || entry?.step?.id
      || entry?.output?.step_id
      || entry?.output?.output?.id
      || entry?.step_id
      || (entry?.index ?? "0"),
  );
}

/** @param {string} title @param {Record<string, any>} result @returns {StepEntry[]} */
export function normalizedTurnEntries(title, result) {
  return normalizeExecutionEntries(title, result);
}

/** @param {{context_turns?: number}|null} sessionInfo @param {ConfigSnapshot|null} configSnapshot @returns {number} */
export function contextTurnCapacity(sessionInfo, configSnapshot) {
  const raw = Number(sessionInfo?.context_turns ?? configSnapshot?.context_turns ?? 6);
  if (!Number.isFinite(raw) || raw <= 0) return 0;
  return Math.floor(raw);
}

/** @param {Turn} turn @returns {boolean} */
export function turnCanEnterContext(turn) {
  return String(turn?.mode || "work") === "work" && turn?.contextEligible === true;
}

/** @param {Turn[]} turns @param {number} capacity @returns {Map<string, {included: boolean, depth: number, label: string}>} */
export function contextMetaByTurn(turns, capacity) {
  const sessionTurns = Array.isArray(turns) ? turns : [];
  const eligible = [...sessionTurns]
    .sort((a, b) => (a.order || 0) - (b.order || 0))
    .filter(turnCanEnterContext);
  const active = capacity > 0 ? eligible.slice(-capacity) : [];
  const meta = new Map();
  [...active].reverse().forEach((turn, depth) => {
    meta.set(turn.id, {
      included: true,
      depth: Math.min(depth, 5),
      label: depth === 0 ? "上下文 最新" : `上下文 -${depth}`,
    });
  });
  for (const turn of sessionTurns) {
    if (!meta.has(turn.id)) {
      meta.set(turn.id, {
        included: false,
        depth: 6,
        label: turnCanEnterContext(turn) ? "不在上下文" : "不加入上下文",
      });
    }
  }
  return meta;
}

/** @param {string} title @param {Record<string, any>} result @param {string} [input] @param {Record<string, any>} [options] @returns {Turn} */
export function createSessionTurn(title, result, input = "", options = {}) {
  const now = options.now || new Date().toISOString();
  const status = String(result?.status || options.status || (result?.ok ? "executed" : "completed"));
  const mode = options.mode || result?.mode || "work";
  const order = options.order ?? 1;
  const number = options.number ?? order;
  const timestamp = options.timestamp ?? Date.now();
  return {
    id: options.id || `turn-${order}-${timestamp}`,
    number,
    order,
    title: title || (mode === "terminal" ? "终端执行" : "work 请求"),
    mode,
    input: input || result?.input || "",
    status,
    created_at: options.created_at || now,
    updated_at: options.updated_at || now,
    source: options.source || result?.source || "live",
    jobId: options.jobId || result?.job_id || "",
    result: result || {},
    entries: normalizedTurnEntries(title, result || {}),
    contextEligible: options.contextEligible ?? (mode === "work" && status !== "approval_required"),
  };
}

/** @param {Record<string, any>} turn @param {number} index @returns {Turn} */
export function normalizeRestoredTurn(turn, index) {
  const result = turn?.result || turn || {};
  const order = index + 1;
  return createSessionTurn(`持久化轮次 ${turn?.number || order}`, result, turn?.input || result.input || "", {
    id: turn?.id || `restored-${order}`,
    number: turn?.number || order,
    order,
    mode: turn?.mode || "work",
    status: turn?.status || result.status || "restored",
    source: turn?.source || "persisted",
    created_at: turn?.created_at || "",
    updated_at: turn?.updated_at || "",
    jobId: turn?.job_id || "",
    contextEligible: typeof turn?.context_eligible === "boolean" ? turn.context_eligible : false,
  });
}

/** @param {Turn[]} turns @param {Turn} turn @param {string} [turnId] @returns {Turn[]} */
export function upsertSessionTurn(turns, turn, turnId = turn?.id) {
  const next = Array.isArray(turns) ? [...turns] : [];
  const existingIndex = turnId ? next.findIndex((candidate) => candidate.id === turnId) : -1;
  if (existingIndex >= 0) next.splice(existingIndex, 1, turn);
  else next.push(turn);
  return next;
}

/** @param {Record<string, any>|null} response @returns {string} */
export function workPlanMarkdown(response) {
  if (!response) return "";
  if (response.response_type === "answer") {
    return ["# 回答", "", response.answer || response.summary || ""].join("\n").trim();
  }
  const steps = Array.isArray(response.steps) ? response.steps : [];
  const lines = ["# 工作计划", ""];
  if (response.summary) lines.push(response.summary, "");
  for (const step of steps) {
    const id = step.id || "step";
    const title = step.title || id;
    const executor = step.executor_type || "executor";
    const risk = step.risk_level || "unknown";
    lines.push(`- ${id}: ${title} [${executor}, risk=${risk}]`);
    if (step.expected_effect) lines.push(`  预测: ${step.expected_effect}`);
  }
  return lines.join("\n").trim();
}
