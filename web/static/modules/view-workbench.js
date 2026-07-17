import {
  configInputId,
  remoteSecretTransmissionBlocked as isRemoteSecretTransmissionBlocked,
} from "./config-utils.js";

/** @param {Record<string, any>} app @returns {Record<string, Function>} */
export function createWorkbenchView(app) {
  const state = app.state;
  const api = app.request;
  const $ = app.$;
  const on = app.on;
  const setText = app.setText;
  const setStatus = app.setStatus;
  const setSwitch = app.setSwitch;
  const showToast = app.showToast;
  const pretty = app.pretty;
  const escapeHtml = app.escapeHtml;
  const emptyItem = app.emptyItem;
  const emptyEvent = app.emptyEvent;
  const riskKind = app.riskKind;
  const pillKind = app.pillKind;
  const titles = app.titles;
  // Late-bound helpers from other modules / app shell (assigned on app before use)
  const statusKind = (...args) => app.statusKind(...args);
  const renderMarkdown = (...args) => app.renderMarkdown(...args);
  const createJob = (...args) => app.createJob(...args);
  const cancelJob = (...args) => app.cancelJob(...args);
  const pollJob = (...args) => app.pollJob(...args);
  const outputBlocksFrom = (...args) => app.outputBlocksFrom(...args);
  const outputBlocksText = (...args) => app.outputBlocksText(...args);
  const outputBlocksSummary = (...args) => app.outputBlocksSummary(...args);
  const renderOutputBlocksHtml = (...args) => app.renderOutputBlocksHtml(...args);
  const userOutputBlocks = (...args) => app.userOutputBlocks(...args);
  const findBlockJson = (...args) => app.findBlockJson(...args);
  const normalizeExecutionEntries = (...args) => app.normalizeExecutionEntries(...args);
  const completedExecutionCount = (...args) => app.completedExecutionCount(...args);
  const normalizeApprovalCard = (...args) => app.normalizeApprovalCard(...args);
  const auditProtocol = app.auditProtocol;
  const CONFIG_GROUPS = app.CONFIG_GROUPS;
  const CONFIG_READONLY_FIELDS = app.CONFIG_READONLY_FIELDS;
  const THINKING_TRACE_KEY = app.THINKING_TRACE_KEY;
  const REMOTE_API_KEY_TRANSMISSION_KEY = app.REMOTE_API_KEY_TRANSMISSION_KEY;
  const hiddenOutputKeys = app.hiddenOutputKeys;
  const outputLabelMap = app.outputLabelMap;
  // render-output helpers
  const primaryOutputObject = (...a) => app.primaryOutputObject(...a);
  const outputSummaryText = (...a) => app.outputSummaryText(...a);
  const renderOutputSection = (...a) => app.renderOutputSection(...a);
  const renderPrimaryOutputHtml = (...a) => app.renderPrimaryOutputHtml(...a);
  const terminalReturnPayload = (...a) => app.terminalReturnPayload(...a);
  const renderTerminalReturnHtml = (...a) => app.renderTerminalReturnHtml(...a);
  const renderMetaRows = (...a) => app.renderMetaRows(...a);
  const renderJsonDetails = (...a) => app.renderJsonDetails(...a);
  const isPlainObject = (...a) => app.isPlainObject(...a);
  const isEmptyOutputValue = (...a) => app.isEmptyOutputValue(...a);
  const extractRawOutput = (...a) => app.extractRawOutput(...a);
  const renderUserOutputText = (...a) => app.renderUserOutputText(...a);
  const renderArrayOutputText = (...a) => app.renderArrayOutputText(...a);
  const renderObjectOutputText = (...a) => app.renderObjectOutputText(...a);
  const renderProtocolText = (...a) => app.renderProtocolText(...a);
  const renderSharedExecutionOutput = (...a) => app.renderSharedExecutionOutput(...a);
  const executionFlowBlocks = (...a) => app.executionFlowBlocks(...a);
  const renderExecutionFlowHtml = (...a) => app.renderExecutionFlowHtml(...a);
  const entryStepKey = (...a) => app.entryStepKey(...a);
  const normalizedTurnEntries = (...a) => app.normalizedTurnEntries(...a);
  const workPlanMarkdown = (...a) => app.workPlanMarkdown(...a);
  const turnCanEnterContextPure = app.turnCanEnterContextPure;
  const createSessionTurnPure = app.createSessionTurnPure;
  const normalizeRestoredTurnPure = app.normalizeRestoredTurnPure;
  const upsertSessionTurnPure = app.upsertSessionTurnPure;
  const contextTurnCapacityPure = app.contextTurnCapacityPure;
  const contextMetaByTurnPure = app.contextMetaByTurnPure;
  let sessionTurnCounter = app.sessionTurnCounterRef;

  if (typeof app.sessionTurnCounter !== "number") app.sessionTurnCounter = 0;
  const sessionTurnCounterProxy = {
    get value() { return app.sessionTurnCounter; },
    set value(v) { app.sessionTurnCounter = v; },
  };
  function firstLine(value) {
    return String(value || "").split("\n").find((line) => line.trim()) || "--";
  }

  function compactText(value, max = 220) {
    const text = String(value ?? "").replace(/\s+/g, " ").trim();
    if (!text) return "";
    return text.length > max ? `${text.slice(0, max)}...` : text;
  }

  function updateSelectedStepStatus(entry) {
    const status = $("selectedStepStatus");
    if (!status) return;
    if (!entry) {
      status.textContent = "none";
      status.className = "pill";
      return;
    }
    status.textContent = entry.status || "selected";
    status.className = `pill risk ${app.statusKind(entry.status)}`;
  }

  function printOutput(id, value) {
    const el = $(id);
    if (!el) return;
    const blocks = outputBlocksFrom(value);
    el.textContent = blocks.length ? outputBlocksText(blocks) : app.renderUserOutputText(value);
  }

  function outputLabel(key) {
    return outputLabelMap[key] || key;
  }

  function updateWorkActionLabel() {
    const button = $("workRunBtn");
    if (!button) return;
    const running = Boolean((state.activeWorkJobId && !state.workSuspended) || state.workApprovalSubmitting);
    button.textContent = state.awaitingWorkApproval ? "等待审批选择" : (running ? "运行中" : (state.workSuspended ? "继续" : (state.workSubmitting ? "发送中" : "发送")));
    const remoteBlocked = remoteSecretTransmissionBlocked();
    button.disabled = state.awaitingWorkApproval || state.workSubmitting || running || remoteBlocked;
    button.title = remoteBlocked ? "Remote runtime 尚未允许向 AI Provider 传输 API Key" : "";
    if ($("workCancelBtn")) $("workCancelBtn").disabled = !state.activeWorkJobId;
    if ($("workSuspendBtn")) $("workSuspendBtn").disabled = !state.activeWorkJobId || state.workSuspended;
  }

  function remoteSecretTransmissionBlocked() {
    return isRemoteSecretTransmissionBlocked(state.configSnapshot);
  }

  function updateRemoteActionState() {
    const blocked = remoteSecretTransmissionBlocked();
    const blockedReason = "Remote runtime 尚未允许向 AI Provider 传输 API Key；请在配置中心明确开启后再使用。";
    updateWorkActionLabel();
    const editButton = $("editPlanBtn");
    if (editButton) {
      editButton.disabled = blocked;
      editButton.title = blocked ? "Remote runtime 尚未允许向 AI Provider 传输 API Key" : "";
    }
    const backupButton = $("runtimeBackupBtn");
    if (backupButton) backupButton.hidden = state.configSnapshot?.remote?.enabled !== true;
    for (const id of ["workRemoteTransmissionNotice", "editRemoteTransmissionNotice"]) {
      const notice = $(id);
      if (!notice) continue;
      notice.hidden = !blocked;
      notice.textContent = blocked ? blockedReason : "";
    }
  }

  function updateTerminalActionState() {
    const button = $("terminalRunBtn");
    if (button) button.disabled = Boolean(state.activeTerminalJobId || state.terminalSubmitting || state.pendingApproval?.type === "terminal");
  }

  function closeApprovalDrawer() {
    state.approvalDrawerOpen = false;
    state.pendingApproval = null;
    state.awaitingWorkApproval = false;
    document.body.classList.remove("terminal-approval");
    const drawer = $("approvalDrawer");
    if (drawer) drawer.hidden = true;
    updateWorkActionLabel();
    updateTerminalActionState();
  }

  function openApprovalDrawer(result, input) {
    const card = normalizeApprovalCard(result);
    const response = result.response || state.workPlan || {};
    const steps = response.steps || [];
    const step = card?.step || steps[completedExecutionCount(result)] || steps.find((candidate) => candidate.risk_level !== "low") || steps[0] || {};
    state.pendingApproval = {
      type: "work",
      input,
      response,
      context: result.context || state.workContext || {},
      card,
      step,
      index: Math.max(0, steps.indexOf(step)),
      review: card?.review || null,
      executionState: result.execution_state || {
        next_step_index: completedExecutionCount(result),
        approval_step_id: step.id || null,
        results: [],
      },
    };
    state.approvalDrawerOpen = true;
    state.awaitingWorkApproval = true;

    setText("approvalTitle", card?.title || step.title || step.id || "待审批步骤");
    setStatus("approvalRisk", card?.risk_level || step.risk_level || "approval_required", riskKind(card?.risk_level || step.risk_level || "medium"));
    const body = $("approvalBody");
    if (body) {
      body.innerHTML = `
        <div class="approval-meta">
          ${app.renderMetaRows([
            ["执行器", step.executor_type || "--"],
            ["Skill", step.skill_script || ""],
            ["MCP server", step.mcp_server || ""],
            ["MCP tool", step.mcp_tool || ""],
            ["命令", step.command || ""],
            ["预期效果", step.expected_effect || ""],
            ["原因", step.reason || ""],
          ])}
        </div>
        ${app.renderJsonDetails("策略审查 findings", state.pendingApproval.review?.findings || [], false)}
        ${app.renderJsonDetails("步骤 JSON", step, false)}
      `;
    }
    const revision = $("approvalRevision");
    if (revision) revision.value = "";
    const drawer = $("approvalDrawer");
    if (drawer) drawer.hidden = false;
    updateWorkActionLabel();
  }

  function openTerminalApprovalDrawer(command, review) {
    const card = review?.review ? review : { command, review };
    const policyReview = card.review || {};
    state.pendingApproval = { type: "terminal", command: card.command || command, review: policyReview, card };
    state.approvalDrawerOpen = true;
    setText("approvalTitle", card.title || "终端命令需要审批");
    setStatus("approvalRisk", card.risk_level || policyReview.risk_level || "approval_required", riskKind(card.risk_level || policyReview.risk_level || "medium"));
    const body = $("approvalBody");
    if (body) {
      body.innerHTML = `
        <div class="approval-meta">
          ${app.renderMetaRows([
            ["执行器", "terminal"],
            ["命令", card.command || command],
            ["风险", card.risk_level || policyReview.risk_level || ""],
          ])}
        </div>
        ${app.renderJsonDetails("策略审查 findings", policyReview.findings || [], true)}
      `;
    }
    const revision = $("approvalRevision");
    if (revision) revision.value = "";
    document.body.classList.add("terminal-approval");
    const drawer = $("approvalDrawer");
    if (drawer) drawer.hidden = false;
    updateTerminalActionState();
  }

  async function submitApprovalDecision(decision) {
    if (!state.pendingApproval) return showToast("No pending approval");
    if (state.pendingApproval.type === "terminal") {
      const command = state.pendingApproval.command;
      if (decision !== "y") {
        const review = state.pendingApproval.review || {};
        closeApprovalDrawer();
        setStatus("terminalJobStatus", "rejected", "medium");
        printOutput("terminalOutput", { ok: false, status: "rejected", review });
        return;
      }
      closeApprovalDrawer();
      if (state.activeTerminalJobId || state.terminalSubmitting) return showToast("Terminal job is already running.");
      state.terminalSubmitting = true;
      updateTerminalActionState();
      try {
        const job = await app.createJob("terminal", "run", { command, approve: true });
        state.activeTerminalJobId = job.job_id;
        state.terminalSubmitting = false;
        updateTerminalActionState();
        const completed = await app.pollJob(job.job_id, "terminalJobStatus", "terminalOutput");
        renderSharedProtocolExecution("终端输出", completed.result || completed, "terminalOutput");
      } finally {
        state.activeTerminalJobId = "";
        state.terminalSubmitting = false;
        updateTerminalActionState();
      }
      return;
    }

    const pendingApproval = state.pendingApproval;
    const payload = {
      input: pendingApproval.input,
      response: pendingApproval.response,
      context: pendingApproval.context,
      execution_state: pendingApproval.executionState || {},
      decisions: [decision],
    };
    if (decision === "s") payload.decisions.push($("approvalRevision")?.value || "");
    closeApprovalDrawer();
    if (state.activeWorkJobId || state.workSubmitting) return showToast("Work job is already running.");
    state.workSubmitting = true;
    state.workApprovalSubmitting = true;
    setStatus("workJobStatus", "running", "running");
    updateWorkActionLabel();
    try {
      const job = await app.createJob("work", "run", payload);
      state.activeWorkJobId = job.job_id;
      state.workSubmitting = false;
      state.workApprovalSubmitting = false;
      state.workSuspended = false;
      updateWorkActionLabel();
      const completed = await app.pollJob(job.job_id, "workJobStatus", null, { suspendFlag: "workSuspended", onProgress: renderWorkJobProgress });
      await handleCompletedWork(completed, payload.input);
    } finally {
      state.workSubmitting = false;
      state.workApprovalSubmitting = false;
      updateWorkActionLabel();
    }
  }

  function renderWorkPlan(response, input = "", context = null, awaitingApproval = false) {
    state.workPlan = response;
    state.workContext = context;
    state.workPlanInput = input;
    state.awaitingWorkApproval = awaitingApproval;
    updateWorkActionLabel();
  }

  function prepareNewWorkRun(input) {
    state.selectedTurnId = "";
    state.selectedStepKey = "";
    state.selectedStepIndex = -1;
    state.lastProtocolResult = null;
    state.awaitingWorkApproval = false;
    state.workPlanInput = input;
    printOutput("terminalOutput", { status: "running", message: "本轮执行中，等待返回新的共享执行输出。" });
    renderSessionTimeline();
    renderStepDetail(null);
  }

  function renderSharedProtocolExecution(title, result, outputId = "terminalOutput") {
    state.lastProtocolResult = result;
    const text = app.renderSharedExecutionOutput(title, result);
    if (outputId) printOutput(outputId, text);
    upsertSessionTurn(title, result, result?.input || "", {
      mode: title.includes("终端") ? "terminal" : "work",
      contextEligible: false,
    });
  }

  function renderWorkJobProgress(job) {
    const result = job?.result;
    if (!result) return;
    const text = app.renderSharedExecutionOutput(result.status || "work_running", result);
    if (!text.trim()) return;
    state.lastProtocolResult = result;
    printOutput("terminalOutput", text);
  }

  function contextTurnCapacity() {
    const raw = Number(state.sessionInfo?.context_turns ?? state.configSnapshot?.context_turns ?? 6);
    if (!Number.isFinite(raw) || raw <= 0) return 0;
    return Math.floor(raw);
  }

  function contextMetaByTurn() {
    return contextMetaByTurnPure(state.sessionTurns, contextTurnCapacity());
  }

  function createSessionTurn(title, result, input = "", options = {}) {
    const now = new Date().toISOString();
    const status = String(result?.status || options.status || (result?.ok ? "executed" : "completed"));
    const mode = options.mode || result?.mode || "work";
    const order = options.order ?? ++app.sessionTurnCounter;
    const number = options.number ?? (state.sessionTurns.length + 1);
    return {
      id: options.id || `turn-${order}-${Date.now()}`,
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
      entries: app.normalizedTurnEntries(title, result || {}),
      contextEligible: options.contextEligible ?? (mode === "work" && status !== "approval_required"),
    };
  }

  function normalizeRestoredTurn(turn, index) {
    const result = turn?.result || turn || {};
    const order = index + 1;
    app.sessionTurnCounter = Math.max(app.sessionTurnCounter, order);
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

  function upsertSessionTurn(title, result, input = "", options = {}) {
    const existingIndex = options.turnId ? state.sessionTurns.findIndex((turn) => turn.id === options.turnId) : -1;
    const existing = existingIndex >= 0 ? state.sessionTurns[existingIndex] : null;
    const keepSelection = existing?.id && state.selectedTurnId === existing.id;
    const turn = createSessionTurn(title, result, input, {
      ...options,
      id: existing?.id || options.turnId || options.id,
      number: existing?.number,
      order: existing?.order,
      created_at: existing?.created_at,
    });
    if (existingIndex >= 0) state.sessionTurns.splice(existingIndex, 1, turn);
    else state.sessionTurns.push(turn);
    state.lastProtocolResult = result;
    renderSessionTimeline();
    if (keepSelection) {
      const selectedEntry = state.selectedStepKey
        ? (turn.entries || []).find((entry) => app.entryStepKey(entry) === state.selectedStepKey)
        : null;
      if (selectedEntry) renderStepDetail(selectedEntry, turn.result, turn);
      else renderTurnDetail(turn);
    } else if (!state.selectedTurnId) {
      renderStepDetail(null);
    }
    return turn;
  }

  function replaceSessionTurns(turns) {
    app.sessionTurnCounter = 0;
    state.sessionTurns = (Array.isArray(turns) ? turns : []).map(normalizeRestoredTurn);
    state.selectedTurnId = "";
    state.selectedStepKey = "";
    renderSessionTimeline();
    renderStepDetail(null);
  }

  function restoreTimelineFromAudit({ backend, preview, sessionId }) {
    const restored = backend.web_timeline || preview;
    state.sessionInfo = backend.session || state.sessionInfo;
    state.restoredAuditSessionId = sessionId;
    state.lastProtocolResult = restored;
    state.workPlan = restored.response || null;
    state.workContext = { restored_from_audit: sessionId };
    state.workPlanInput = restored.input || "";
    state.awaitingWorkApproval = false;
    closeApprovalDrawer();
    if ($("workInput") && restored.input) $("workInput").value = restored.input;
    updateSessionLeaveState();
    if (Array.isArray(restored.turns) && restored.turns.length) {
      replaceSessionTurns(restored.turns);
    } else {
      replaceSessionTurns([
        {
          id: `restored-${sessionId || "audit"}`,
          number: 1,
          mode: "work",
          input: restored.input || `审计恢复 ${sessionId || ""}`,
          status: restored.status || "restored",
          result: restored,
        },
      ]);
    }
    setStatus(
      "workJobStatus",
      backend.status || restored.status || "restored",
      app.statusKind(backend.status || restored.status || "restored"),
    );
  }

  function selectedTurn() {
    return state.sessionTurns.find((turn) => turn.id === state.selectedTurnId) || null;
  }

  function selectSessionTurn(turnId) {
    state.selectedTurnId = turnId;
    state.selectedStepKey = "";
    renderSessionTimeline();
    renderTurnDetail(selectedTurn());
  }

  function selectTurnStep(turnId, stepKey) {
    const turn = state.sessionTurns.find((candidate) => candidate.id === turnId);
    if (!turn) return;
    const entry = (turn.entries || []).find((candidate) => app.entryStepKey(candidate) === stepKey);
    if (!entry) return;
    state.selectedTurnId = turnId;
    state.selectedStepKey = stepKey;
    state.selectedStepIndex = entry.index;
    renderSessionTimeline();
    renderStepDetail(entry, turn.result, turn);
  }

  function renderSessionTimeline() {
    const container = $("workPlan");
    if (!container) return;
    container.innerHTML = "";
    if (!state.sessionTurns.length) {
      container.appendChild(emptyItem("当前会话还没有执行轮次"));
      renderStepDetail(null);
      return;
    }
    const contextMeta = contextMetaByTurn();
    const turns = [...state.sessionTurns].sort((a, b) => (b.order || 0) - (a.order || 0));
    for (const turn of turns) appendTurnCard(container, turn, contextMeta.get(turn.id));
  }

  function modeLabel(mode) {
    if (mode === "terminal") return "terminal";
    if (mode === "script") return "script";
    if (mode === "edit") return "edit";
    return "work";
  }

  function appendTurnCard(container, turn, contextMeta = {}) {
    const displayStatus = turn.status || "selected";
    const selected = state.selectedTurnId === turn.id;
    const item = document.createElement("article");
    item.className = `timeline-card session-turn ${app.statusKind(displayStatus)}${selected ? " selected" : ""}`;
    const contextClass = contextMeta.included ? `context-active context-depth-${contextMeta.depth || 0}` : "context-muted";
    item.innerHTML = `
      <button class="timeline-step-button session-turn-button" type="button">
        <span class="step-index">${escapeHtml(turn.number || "?")}</span>
        <span class="timeline-main">
          <span class="timeline-title">${escapeHtml(`第 ${turn.number || "?"} 轮 · ${modeLabel(turn.mode)}`)}</span>
          <span class="timeline-copy">${escapeHtml(turn.input || turn.title || "无输入摘要")}</span>
        </span>
        <span class="turn-pills">
          <span class="pill context-pill ${contextClass}">${escapeHtml(contextMeta.label || "上下文")}</span>
          <span class="pill risk ${app.statusKind(displayStatus)}">${escapeHtml(displayStatus)}</span>
        </span>
      </button>
      ${selected ? renderTurnStepChips(turn) : ""}
    `;
    const turnButton = item.querySelector(".session-turn-button");
    if (turnButton) turnButton.addEventListener("click", () => selectSessionTurn(turn.id));
    item.querySelectorAll(".turn-step-chip").forEach((button) => {
      button.addEventListener("click", (event) => {
        event.stopPropagation();
        if (button instanceof HTMLElement) selectTurnStep(turn.id, button.dataset.stepKey || "");
      });
    });
    container.appendChild(item);
  }

  function renderTurnStepChips(turn) {
    const entries = turn.entries || [];
    if (!entries.length) return '<div class="turn-step-list"><span class="mini-pill">本轮没有步骤输出</span></div>';
    return `
      <div class="turn-step-list">
        ${entries.map((entry) => {
          const key = app.entryStepKey(entry);
          const selected = state.selectedTurnId === turn.id && state.selectedStepKey === key;
          return `
            <button class="turn-step-chip ${selected ? "selected" : ""}" type="button" data-step-key="${escapeHtml(key)}">
              <span class="mini-step-index">${escapeHtml(entry.number ?? entry.index + 1)}</span>
              <span>${escapeHtml(entry.title || "步骤")}</span>
              <span class="mini-pill risk ${app.statusKind(entry.status)}">${escapeHtml(entry.status || "step")}</span>
            </button>
          `;
        }).join("")}
      </div>
    `;
  }

  function renderTurnDetail(turn) {
    const container = $("workDetail");
    if (!container) return;
    if (!turn) {
      renderStepDetail(null);
      return;
    }
    updateSelectedStepStatus({ status: turn.status || "selected" });
    const entries = turn.entries || [];
    const flowHtml = app.renderExecutionFlowHtml(turn.result);
    const planMarkdown = app.workPlanMarkdown(turn.result?.response);
    container.className = "step-detail turn-detail";
    container.innerHTML = `
      <div class="detail-title-row">
        <div>
          <h4>${escapeHtml(`第 ${turn.number || "?"} 轮 · ${modeLabel(turn.mode)}`)}</h4>
          <p>${escapeHtml(turn.input || turn.title || "")}</p>
        </div>
        <span class="pill risk ${app.statusKind(turn.status)}">${escapeHtml(turn.status || "selected")}</span>
      </div>
      <section class="detail-section">
        <h5>轮次摘要</h5>
        <div class="meta-grid">
          ${app.renderMetaRows([
            ["模式", modeLabel(turn.mode)],
            ["状态", turn.status || ""],
            ["步骤数", entries.length],
            ["来源", turn.source || ""],
          ])}
        </div>
      </section>
      ${planMarkdown ? `
        <section class="detail-section">
          <h5>工作计划</h5>
          <div class="markdown-preview work-plan-preview">${renderMarkdown(planMarkdown)}</div>
        </section>
      ` : ""}
      <section class="detail-section terminal-return-section">
        <h5>本轮步骤输出</h5>
        <div class="turn-output-list">
          ${entries.length ? entries.map((entry) => renderTurnStepOutput(entry)).join("") : '<p class="muted">本轮没有可展示的步骤输出。</p>'}
        </div>
      </section>
      ${flowHtml ? `<details class="detail-block"><summary>轮次完整执行流程</summary>${flowHtml}</details>` : ""}
      ${app.renderJsonDetails("轮次原始数据", { result: turn.result }, false)}
    `;
  }

  function renderTurnStepOutput(entry) {
    const output = entry.output || {};
    return `
      <article class="turn-step-output">
        <div class="turn-step-output-head">
          <span class="step-index">${escapeHtml(entry.number ?? entry.index + 1)}</span>
          <strong>${escapeHtml(entry.title || "步骤")}</strong>
          <span class="pill risk ${app.statusKind(entry.status)}">${escapeHtml(entry.status || "step")}</span>
        </div>
        <div class="primary-output">${app.renderTerminalReturnHtml(output)}</div>
      </article>
    `;
  }

  function renderStepDetail(entry, result = state.lastProtocolResult, turn = selectedTurn()) {
    const container = $("workDetail");
    if (!container) return;
    if (!entry) {
      container.className = "detail-empty";
      container.textContent = "选择时间线中的轮次或步骤查看详情。";
      updateSelectedStepStatus(null);
      return;
    }
    updateSelectedStepStatus(entry);
    const step = entry.step || {};
    const output = entry.output || {};
    const blocks = outputBlocksFrom(output);
    const proxy = findBlockJson(blocks, "meta", "执行代理");
    const observer = findBlockJson(blocks, "observer");
    const review = findBlockJson(blocks, "review");
    const mcpLabel = step.mcp_server && step.mcp_tool ? `${step.mcp_server}/${step.mcp_tool}` : "";
    const commandLabel = step.skill_script || mcpLabel || step.command || output.command || app.primaryOutputObject(output).command || "";
    const subtitle = step.reason || step.expected_effect || turn?.input || "";
    container.className = "step-detail";
    container.innerHTML = `
      <div class="detail-title-row">
        <div>
          <h4>${escapeHtml(entry.title || step.title || "步骤详情")}</h4>
          ${subtitle ? `<p>${escapeHtml(subtitle)}</p>` : ""}
        </div>
        <span class="pill risk ${app.statusKind(entry.status)}">${escapeHtml(entry.status || "selected")}</span>
      </div>
      <section class="detail-section">
        <h5>执行摘要</h5>
        <div class="meta-grid">
          ${app.renderMetaRows([
            ["轮次", turn?.number ? `第 ${turn.number} 轮` : ""],
            ["状态", entry.status || output.status || ""],
            ["退出码", output.exit_code ?? ""],
            ["自动批准", output.auto_approved === true ? "是" : (output.auto_approved === false ? "否" : "")],
            ["执行器", step.executor_type || ""],
            ["风险", step.risk_level || ""],
            ["命令/Skill/MCP", commandLabel],
          ])}
        </div>
      </section>
      <section class="detail-section">
        <h5>步骤事宜</h5>
        <div class="meta-grid">
          ${app.renderMetaRows([
            ["步骤 ID", step.id || ""],
            ["原因", step.reason || ""],
            ["预期效果", step.expected_effect || ""],
            ["脚本", step.skill_script || ""],
            ["MCP server", step.mcp_server || ""],
            ["MCP tool", step.mcp_tool || ""],
            ["命令", step.command || ""],
            ["参数", step.arguments ? JSON.stringify(step.arguments) : ""],
          ]) || '<p class="muted">本步骤没有计划元数据。</p>'}
        </div>
      </section>
      <section class="detail-section terminal-return-section">
        <h5>终端返回</h5>
        <div class="primary-output">
          ${app.renderTerminalReturnHtml(output)}
        </div>
      </section>
      <section class="detail-section">
        <h5>执行代理</h5>
        <div class="meta-grid">
          ${app.renderMetaRows([
            ["启用状态", proxy.enabled === true ? "启用" : (proxy.enabled === false ? "未启用" : "")],
            ["请求权限", proxy.requested_privilege || ""],
            ["执行用户", proxy.execution_user || proxy.user || ""],
            ["准备目录", proxy.prepared_root || proxy.root || ""],
          ]) || '<p class="muted">本步骤没有返回执行代理信息。</p>'}
        </div>
      </section>
      <section class="detail-section">
        <h5>Observer 摘要</h5>
        <div class="meta-grid">
          ${app.renderMetaRows([
            ["状态", observer.status || ""],
            ["后端", observer.backend || ""],
            ["生命周期", observer.lifecycle || ""],
            ["范围", observer.scope || ""],
          ]) || '<p class="muted">本步骤没有返回 observer 信息。</p>'}
        </div>
      </section>
      ${app.renderJsonDetails("策略审查", review || step.review || null)}
      ${app.renderJsonDetails("原始调试数据", { step, output, result_session: result?.session_id || "" }, false)}
    `;
  }

  function renderPendingStepDetail(step, index, awaitingApproval = false) {
    renderStepDetail({
      index,
      number: index + 1,
      title: step.title,
      status: awaitingApproval ? "approval_required" : "planned",
      step,
      output: {
        status: awaitingApproval ? "approval_required" : "planned",
        summary: step.expected_effect || step.reason || "等待执行。",
      },
    });
  }

  async function loadSessionState() {
    const data = await app.api("/api/session/state");
    state.sessionInfo = data;
    state.restoredAuditSessionId = data.restored_from || "";
    const persistedTurns = data.web_timeline?.turns || data.turns || [];
    replaceSessionTurns(persistedTurns);
    updateSessionLeaveState();
    return data;
  }

  function updateSessionLeaveState() {
    const button = $("sessionLeaveBtn");
    if (!button) return;
    const restoredFrom = state.sessionInfo?.restored_from || "";
    button.textContent = restoredFrom ? "离开历史" : "离开";
    button.title = restoredFrom
      ? `离开恢复自 ${restoredFrom} 的历史会话并清空上下文`
      : "结束当前 Web 会话并开启新的 session_web_* 上下文";
  }

  async function leaveWorkbenchSession() {
    if (state.activeWorkJobId || state.workSubmitting || state.workApprovalSubmitting || state.activeTerminalJobId || state.terminalSubmitting) {
      showToast("当前仍有任务运行，结束后再离开会话");
      return;
    }
    const result = await app.api("/api/session/leave", { method: "POST", body: {} });
    if (!result.ok) {
      showToast(result.error || result.status || "离开会话失败");
      return;
    }
    state.sessionInfo = result.session || state.sessionInfo;
    state.restoredAuditSessionId = "";
    state.sessionTurns = [];
    state.selectedTurnId = "";
    state.selectedStepKey = "";
    state.workPlan = null;
    state.workContext = null;
    state.workPlanInput = "";
    state.lastProtocolResult = null;
    state.awaitingWorkApproval = false;
    closeApprovalDrawer();
    updateSessionLeaveState();
    renderSessionTimeline();
    setStatus("workJobStatus", result.status || "new_session", result.ok ? "ok" : "failed");
    showToast(result.status === "left_restored" ? "已离开历史会话，上下文已清空" : "已开启新的 Web 会话");
  }

  async function runWork() {
    if (remoteSecretTransmissionBlocked()) {
      showToast("请先在配置中心允许远程传输 API Key");
      return;
    }
    if (state.workSubmitting || (state.activeWorkJobId && !state.workSuspended)) {
      showToast("Work job is already running.");
      return;
    }
    if (state.activeWorkJobId && state.workSuspended) {
      state.workSuspended = false;
      updateWorkActionLabel();
      const completed = await app.pollJob(state.activeWorkJobId, "workJobStatus", null, { suspendFlag: "workSuspended", onProgress: renderWorkJobProgress });
      await handleCompletedWork(completed, state.workPlanInput);
      return;
    }
    const input = $("workInput").value.trim();
    if (!input) return showToast("Work input required");
    closeApprovalDrawer();
    prepareNewWorkRun(input);
    const payload = { input };
    state.workSubmitting = true;
    updateWorkActionLabel();
    try {
      const job = await app.createJob("work", "run", payload);
      state.activeWorkJobId = job.job_id;
      state.workSubmitting = false;
      state.workSuspended = false;
      updateWorkActionLabel();
      const completed = await app.pollJob(job.job_id, "workJobStatus", null, { suspendFlag: "workSuspended", onProgress: renderWorkJobProgress });
      await handleCompletedWork(completed, input);
    } finally {
      state.workSubmitting = false;
      updateWorkActionLabel();
    }
  }

  async function handleCompletedWork(completed, input) {
    if (completed.status === "suspended") return;
    state.activeWorkJobId = "";
    state.workApprovalSubmitting = false;
    const result = completed.result || {};
    state.lastProtocolResult = result;
    state.lastThinkingSummary = result.response?.thinking_summary || state.lastThinkingSummary || "";
    renderThinkingSummary();
    updateWorkActionLabel();
    if (result.response) {
      renderWorkPlan(result.response, input, result.context || null, result.status === "approval_required");
    } else if (result.status !== "approval_required") {
      state.awaitingWorkApproval = false;
      closeApprovalDrawer();
      updateWorkActionLabel();
    }
    const hasWorkbenchResult = Boolean(
      result.response ||
        Array.isArray(result.timeline) ||
        Array.isArray(result.output_blocks) ||
        ["approval_required", "executed", "answered", "failed", "cancelled"].includes(result.status)
    );
    if (hasWorkbenchResult) {
      const sharedText = app.renderSharedExecutionOutput(result.status || "work_return", result);
      if (sharedText.trim()) printOutput("terminalOutput", sharedText);
    }
    // SessionStore commits the immutable turn before publishing the terminal
    // Job record.  Reload it instead of assigning browser-local IDs/timestamps
    // or merging approval continuations differently from the backend.
    await loadSessionState();
    if (result.status === "approval_required") {
      openApprovalDrawer(result, input);
      showToast("需要审批后继续");
    } else {
      closeApprovalDrawer();
    }
  }

  async function cancelWork() {
    if (!state.activeWorkJobId) return;
    const data = await app.cancelJob(state.activeWorkJobId);
    printOutput("terminalOutput", data);
    state.activeWorkJobId = "";
    state.workSuspended = false;
    state.awaitingWorkApproval = false;
    closeApprovalDrawer();
    updateWorkActionLabel();
    setStatus("workJobStatus", data.status, data.ok ? "high" : "medium");
    const result = data.job?.result || data;
    const sharedText = app.renderSharedExecutionOutput(result.status || "cancelled", result);
    if (sharedText.trim()) printOutput("terminalOutput", sharedText);
    await loadSessionState();
  }

  function suspendWork() {
    if (!state.activeWorkJobId) return;
    state.workSuspended = true;
    updateWorkActionLabel();
    setStatus("workJobStatus", "suspended", "medium");
    showToast("Work polling suspended; job keeps running on server.");
  }

  async function runTerminal() {
    if (state.terminalSubmitting || state.activeTerminalJobId || state.pendingApproval?.type === "terminal") {
      showToast("Terminal job is already running.");
      return;
    }
    const command = $("terminalCommand").value.trim();
    if (!command) return showToast("Command required");
    state.terminalSubmitting = true;
    updateTerminalActionState();
    try {
      const review = await app.api("/api/terminal/review", { method: "POST", body: { command } });
      if (review.status === "blocked") {
        setStatus("terminalJobStatus", "blocked", "high");
        printOutput("terminalOutput", review);
        return;
      }
      if (review.status === "approval_required") {
        setStatus("terminalJobStatus", "approval_required", "medium");
        printOutput("terminalOutput", review);
        openTerminalApprovalDrawer(command, review.approval_card || review.review || review);
        return;
      }
      const job = await app.createJob("terminal", "run", { command, approve: false });
      state.activeTerminalJobId = job.job_id;
      state.terminalSubmitting = false;
      updateTerminalActionState();
      const completed = await app.pollJob(job.job_id, "terminalJobStatus", "terminalOutput");
      renderSharedProtocolExecution("终端输出", completed.result || completed, "terminalOutput");
    } finally {
      state.activeTerminalJobId = "";
      state.terminalSubmitting = false;
      updateTerminalActionState();
    }
  }

  function renderThinkingSummary(summary = state.lastThinkingSummary) {
    const el = $("workOutput");
    if (!el) return;
    if (!thinkingTraceEnabled()) {
      el.classList.add("summary-empty");
      el.textContent = "thinking_summary 未开启。开启开关后，新请求会在这里显示模型返回的简短思考摘要。";
      return;
    }
    const text = String(summary || "").trim();
    if (!text) {
      el.classList.add("summary-empty");
      el.textContent = "已开启 thinking_summary；本轮尚未返回模型思考摘要。";
      return;
    }
    el.classList.remove("summary-empty");
    el.innerHTML = `<div class="summary-markdown">${renderMarkdown(text)}</div>`;
  }

  function setThinkingSwitches(enabled) {
    setSwitch("thinkingTraceSwitch", enabled);
    setSwitch(configInputId(THINKING_TRACE_KEY), enabled);
  }

  function thinkingTraceEnabled() {
    return Boolean($("thinkingTraceSwitch")?.classList.contains("on"));
  }


  return {
    firstLine,
    compactText,
    updateSelectedStepStatus,
    printOutput,
    outputLabel,
    updateWorkActionLabel,
    remoteSecretTransmissionBlocked,
    updateRemoteActionState,
    updateTerminalActionState,
    closeApprovalDrawer,
    openApprovalDrawer,
    openTerminalApprovalDrawer,
    submitApprovalDecision,
    renderWorkPlan,
    prepareNewWorkRun,
    renderSharedProtocolExecution,
    renderWorkJobProgress,
    contextTurnCapacity,
    contextMetaByTurn,
    createSessionTurn,
    normalizeRestoredTurn,
    upsertSessionTurn,
    replaceSessionTurns,
    restoreTimelineFromAudit,
    selectedTurn,
    selectSessionTurn,
    selectTurnStep,
    renderSessionTimeline,
    modeLabel,
    appendTurnCard,
    renderTurnStepChips,
    renderTurnDetail,
    renderTurnStepOutput,
    renderStepDetail,
    renderPendingStepDetail,
    loadSessionState,
    updateSessionLeaveState,
    leaveWorkbenchSession,
    runWork,
    handleCompletedWork,
    cancelWork,
    suspendWork,
    runTerminal,
    renderThinkingSummary,
    setThinkingSwitches,
    thinkingTraceEnabled,
  };
}
