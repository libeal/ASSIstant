import { outputBlocksFrom, outputBlocksSummary } from "./output-blocks.js";

export function normalizeProtocolExecutionEntries(title, result) {
  const timeline = Array.isArray(result?.timeline) ? result.timeline : [];
  if (!timeline.length) return [];
  return timeline.filter((item) => item && typeof item === "object").map((item, index) => ({
    index,
    number: index + 1,
    title: item.title || item.step_id || title || "执行结果",
    status: item.status || "pending",
    step: item.step || {},
    output: {
      ...item,
      output_blocks: outputBlocksFrom(item),
      summary: item.summary || outputBlocksSummary(item),
    },
  }));
}

export function normalizeExecutionEntries(title, result) {
  // An empty authoritative timeline means there are no protocol steps to
  // render.  Root-level ok/status values describe the request envelope and
  // must not be promoted into invented business-state steps in the browser.
  return normalizeProtocolExecutionEntries(title, result);
}

export function completedExecutionCount(result) {
  return (Array.isArray(result?.timeline) ? result.timeline : []).filter((item) => item.kind === "execution").length;
}
