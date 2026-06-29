import { outputBlocksFrom, outputBlocksSummary } from "./output-blocks.js";

export function normalizeProtocolExecutionEntries(title, result) {
  const timeline = Array.isArray(result?.timeline) ? result.timeline : [];
  const executionItems = timeline.filter((item) => ["execution", "failure", "observer", "audit"].includes(item.kind));
  if (!executionItems.length) return [];
  return executionItems.map((item, index) => ({
    index,
    number: index + 1,
    title: item.title || item.step_id || title || "执行结果",
    status: item.status || "completed",
    step: item.step || {},
    output: {
      ...item,
      output_blocks: outputBlocksFrom(item),
      summary: item.summary || outputBlocksSummary(item),
    },
  }));
}

export function normalizeExecutionEntries(title, result) {
  const protocolEntries = normalizeProtocolExecutionEntries(title, result);
  if (protocolEntries.length) return protocolEntries;

  const root = result || {};
  return [{
    index: 0,
    number: 1,
    title,
    status: root.status || (root.ok ? "executed" : "完成"),
    step: {},
    output: root,
  }];
}

export function completedExecutionCount(result) {
  return (Array.isArray(result?.timeline) ? result.timeline : []).filter((item) => item.kind === "execution").length;
}
