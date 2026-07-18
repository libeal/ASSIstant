/** @typedef {import("./types.js").AuditEvent} AuditEvent */

/** @param {AuditEvent & Record<string, any>} event @returns {string} */
export function auditEventName(event) {
  return event?.stage || event?.event || event?.type || event?.name || event?.status || event?.kind || event?.payload?.event || "event";
}

/** @param {AuditEvent & Record<string, any>} event @returns {string} */
export function auditEventTime(event) {
  return event?.timestamp || event?.time || event?.started_at || event?.created_at || "";
}

/** @param {unknown} value @returns {string} */
export function compactAuditTime(value) {
  if (!value) return "--";
  return String(value).replace("T", " ").replace("Z", "");
}

function compactText(value, max = 520) {
  const text = String(value ?? "").replace(/\s+/g, " ").trim();
  if (!text) return "";
  return text.length > max ? `${text.slice(0, max)}...` : text;
}

function payloadOf(event) {
  return event?.payload && typeof event.payload === "object" ? event.payload : (event || {});
}

function stepName(payload) {
  const mcpRef = payload?.step?.mcp_server && payload?.step?.mcp_tool ? `${payload.step.mcp_server}/${payload.step.mcp_tool}` : "";
  return payload?.step?.title || payload?.step?.id || payload?.step?.skill_script || mcpRef || payload?.step?.command_preview || "步骤";
}

function resultSummary(detail = {}) {
  const parts = [];
  if (detail.status) parts.push(`状态 ${detail.status}`);
  if (detail.exit_code !== undefined && detail.exit_code !== null) parts.push(`退出码 ${detail.exit_code}`);
  if (detail.tool) parts.push(`工具 ${detail.tool}`);
  if (detail.action) parts.push(`动作 ${detail.action}`);
  return parts.join("，");
}

/** @param {string} stage @returns {string} */
export function auditStageLabel(stage) {
  if (stage === "session_started") return "会话开始";
  if (stage === "session_finished") return "会话结束";
  if (stage === "command_started") return "入口调用开始";
  if (stage === "command_finished") return "入口调用结束";
  if (stage === "received") return "收到请求";
  if (stage === "sensed") return "采集环境";
  if (stage === "request_context_built") return "构建模型上下文";
  if (stage === "planned") return "生成执行计划";
  if (stage === "step_policy_checked") return "策略审查";
  if (stage === "step_auto_approved") return "自动批准";
  if (stage === "step_approval_required") return "等待审批";
  if (stage === "step_approved") return "批准执行";
  if (stage === "step_running") return "开始执行";
  if (stage === "step_succeeded") return "执行成功";
  if (stage === "step_failed") return "执行失败";
  if (stage === "step_blocked") return "策略阻断";
  if (stage === "step_rejected") return "用户拒绝";
  if (stage === "step_skipped_user") return "用户跳过";
  if (stage === "step_skipped_unexecuted") return "后续未执行";
  if (stage === "terminal_executed") return "终端执行";
  if (stage === "script_executed") return "Skill 执行";
  if (stage === "file_vault_detected") return "文件保险箱检测";
  if (stage === "file_vault_observed") return "文件保险箱实际事件";
  if (stage === "executed") return "工作流结果";
  if (stage === "finished") return "业务完成";
  if (stage === "agent_loop_started") return "Agent 循环开始";
  if (stage === "agent_loop_iteration_started") return "Agent 循环迭代开始";
  if (stage === "agent_reflection_requested") return "Agent 反思请求";
  if (stage === "agent_reflection_planned") return "Agent 反思计划";
  if (stage === "agent_checkpoint_requested") return "Agent checkpoint 请求";
  if (stage === "agent_checkpoint_decision") return "Agent checkpoint 决策";
  if (stage === "agent_loop_finished") return "Agent 循环结束";
  if (String(stage).startsWith("observer_")) return "Observer";
  if (String(stage).startsWith("agent_")) return "Agent 循环";
  return stage || "事件";
}

/**
 * Build the presentation model for one audit event.
 * @param {AuditEvent & Record<string, any>} event
 * @param {(value: unknown) => string} [pretty]
 * @returns {{stage: string, title: string, status: string, summary: string, details: string[], badges: string[]}}
 */
export function auditEventDisplay(event, pretty = (value) => JSON.stringify(value)) {
  const stage = auditEventName(event);
  const payload = payloadOf(event);
  const title = auditStageLabel(stage);
  const badges = [];
  const details = [];
  let summary = "";
  let status = payload.status || event?.status || "";

  if (payload.mode) badges.push(payload.mode);
  if (payload.risk_level) badges.push(payload.risk_level);

  if (stage === "session_started") {
    badges.push(payload.entrypoint === "web" ? "Web" : "CLI");
    summary = `请求：${payload.request || "未记录"}`;
  } else if (stage === "command_started") {
    summary = `调用：${payload.command || "agent"}`;
    if (payload.args_preview || payload.args) details.push(`参数：${payload.args_preview || payload.args}`);
  } else if (stage === "command_finished" || stage === "session_finished" || stage === "finished") {
    summary = `状态：${payload.status || "unknown"}`;
  } else if (stage === "received") {
    summary = payload.input_preview || payload.command || payload.ref || "请求内容已记录";
    if (payload.command) details.push(`命令：${payload.command}`);
    if (payload.ref) details.push(`Skill：${payload.ref}`);
  } else if (stage === "sensed") {
    summary = `主题：${payload.topic || "unknown"}`;
    if (Array.isArray(payload.context_keys) && payload.context_keys.length) details.push(`上下文字段：${payload.context_keys.join("、")}`);
  } else if (stage === "request_context_built") {
    summary = payload.current_request_preview || "模型上下文已构建";
    details.push(`会话轮数：${payload.conversation_turns ?? 0}`);
    if (Array.isArray(payload.environment_keys) && payload.environment_keys.length) details.push(`环境字段：${payload.environment_keys.join("、")}`);
  } else if (stage === "planned") {
    summary = payload.summary_preview || `生成 ${payload.step_count ?? 0} 个步骤`;
    details.push(`步骤数：${payload.step_count ?? 0}`);
  } else if (stage === "step_policy_checked") {
    const review = payload.review || {};
    summary = stepName(payload);
    badges.push(review.risk_level || "risk");
    details.push(`审查结果：${review.approved === false ? "阻断" : review.approval_required ? "需要审批" : "通过"}`);
    details.push(`发现项：${review.finding_count ?? 0}`);
  } else if (String(stage).startsWith("step_")) {
    const detail = payload.detail || {};
    summary = stepName(payload);
    if (payload.step?.executor_type) badges.push(payload.step.executor_type);
    if (payload.step?.skill_script) details.push(`调用 Skill：${payload.step.skill_script}`);
    if (payload.step?.mcp_server && payload.step?.mcp_tool) details.push(`调用 MCP：${payload.step.mcp_server}/${payload.step.mcp_tool}`);
    if (payload.step?.command_preview) details.push(`调用命令：${payload.step.command_preview}`);
    const result = resultSummary(detail);
    if (result) details.push(result);
    if (detail.output_preview) details.push(`输出：${detail.output_preview}`);
    if (detail.stderr_preview) details.push(`错误：${detail.stderr_preview}`);
    if (Array.isArray(payload.findings) && payload.findings.length) details.push(`策略发现：${payload.findings.length} 项`);
  } else if (stage === "terminal_executed" || stage === "script_executed" || stage === "executed") {
    summary = resultSummary(payload) || payload.action || payload.status || title;
    if (payload.output_preview) details.push(`输出：${payload.output_preview}`);
    if (payload.stderr_preview) details.push(`错误：${payload.stderr_preview}`);
    if (Array.isArray(payload.results)) details.push(`步骤结果：${payload.results.length} 个`);
  } else if (String(stage).startsWith("file_vault_")) {
    summary = `动作：${payload.action || "unknown"}`;
    if (payload.mode) badges.push(payload.mode);
    if (payload.matched_path_count != null) details.push(`匹配文件：${payload.matched_path_count}`);
    if (payload.observed_path_count != null) details.push(`实际事件文件：${payload.observed_path_count}`);
    if (payload.warning) details.push(payload.warning);
  } else if (String(stage).startsWith("observer_")) {
    status = payload.status || payload.lifecycle || status;
    summary = `状态：${payload.status || "unknown"}，后端：${payload.backend || "auditd"}`;
    details.push(`exec=${payload.exec_count ?? 0}，file=${payload.file_event_count ?? 0}`);
    if (payload.reason_code || payload.diagnostic) details.push(payload.reason_code || payload.diagnostic);
  } else if (String(stage).startsWith("agent_")) {
    status = payload.status || status;
    summary = payload.stopped_reason || payload.status || title;
    if (payload.iteration != null) details.push(`迭代：${payload.iteration}`);
    if (payload.iterations != null) details.push(`总轮数：${payload.iterations}`);
    if (payload.plan_step_count != null) details.push(`计划步骤：${payload.plan_step_count}`);
    if (payload.auto_executed_count != null) details.push(`自动执行：${payload.auto_executed_count}`);
    if (payload.checkpoint_turns != null) details.push(`checkpoint 间隔：${payload.checkpoint_turns}`);
  } else {
    summary = payload.message || payload.status || payload.event || compactText(pretty(payload));
  }

  return {
    stage,
    title,
    status,
    summary: compactText(summary),
    details: details.map((line) => compactText(line)).filter(Boolean),
    badges: [...new Set(badges.filter(Boolean).map(String))],
  };
}

/**
 * Produce a compact human-readable event summary.
 * @param {AuditEvent & Record<string, any>} event
 * @param {(value: unknown) => string} [pretty]
 * @returns {string}
 */
export function auditEventSummary(event, pretty = (value) => JSON.stringify(value)) {
  const display = auditEventDisplay(event, pretty);
  if (display.summary) return display.summary;
  const payload = event?.payload || event || {};
  if (payload.message) return payload.message;
  if (payload.status) return String(payload.status);
  if (payload.mode && payload.input) return `${payload.mode}: ${payload.input}`;
  if (payload.command) return String(payload.command);
  if (payload.ref) return String(payload.ref);
  return compactText(pretty(payload));
}

/**
 * Test whether an event belongs to a UI filter category.
 * @param {AuditEvent & Record<string, any>} event
 * @param {string} category
 * @param {(value: unknown) => string} [pretty]
 * @returns {boolean}
 */
export function auditEventMatchesCategory(event, category, pretty = (value) => JSON.stringify(value)) {
  const text = `${auditEventName(event)} ${pretty(event)}`.toLowerCase();
  if (category === "observer") return text.includes("observer") || text.includes("auditd");
  if (category === "policy") return text.includes("policy") || text.includes("approval") || text.includes("review");
  if (category === "execution") return text.includes("execut") || text.includes("terminal") || text.includes("script");
  if (category === "decision") return text.includes("decision") || text.includes("approve") || text.includes("reject") || text.includes("skip") || text.includes("terminate");
  if (category === "error") return text.includes("failed") || text.includes("error") || text.includes("blocked");
  return true;
}
