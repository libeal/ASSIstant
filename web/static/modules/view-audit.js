/** @typedef {import("./types.js").AppContext} AppContext */
/** @typedef {import("./types.js").AuditView} AuditView */

import { nextAuditRenderBatch } from "./audit-view-utils.js";

/**
 * @param {AppContext} app
 * @param {{restoreTimelineFromAudit: Function, showScreen: Function}} hooks
 * @returns {AuditView}
 */
export function createAuditView(app, hooks) {
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
  const printOutput = (...args) => app.printOutput(...args);
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
  let auditRenderGeneration = 0;

  async function loadAuditList() {
    if (state.auditPaused) {
      showToast("Audit replay is paused");
      return;
    }
    const query = String($("auditSessionFilter")?.value || "").trim();
    const limit = Math.max(1, Math.min(200, Number($("auditLimitInput")?.value || 40)));
    const data = await app.api("/api/audit/list", { method: "POST", body: { limit, query } });
    state.auditSessions = data.sessions || [];
    state.auditEvents = [];
    state.auditWebTimeline = null;
    state.auditTimelineUnavailableReason = "";
    state.currentAuditSession = "";
    renderAuditSessionList();
    resetAuditSummary();
  }

  function scheduleAuditListReload() {
    window.clearTimeout(app.auditListReloadTimer);
    app.auditListReloadTimer = window.setTimeout(() => {
      app.safeAction(loadAuditList);
    }, 250);
  }

  function renderAuditSessionList() {
    const container = $("auditList");
    if (!container) return;
    auditRenderGeneration += 1;
    container.innerHTML = "";
    const sessions = filteredAuditSessions();
    if (!sessions.length) {
      container.appendChild(emptyEvent("暂无审计会话"));
      return;
    }
    for (const session of sessions) {
      const item = document.createElement("button");
      item.type = "button";
      item.className = "event session-event";
      const modes = Array.isArray(session.modes) ? session.modes : [];
      const highlights = Array.isArray(session.highlights) ? session.highlights : [];
      const modeDisplay = auditModeLabel(modes, session.mode_label);
      const headline = auditSessionHeadline(session, modeDisplay);
      const badges = [
        session.entrypoint_label || (session.entrypoint === "web" ? "Web" : "CLI"),
        modeDisplay,
        `${session.event_count ?? 0} 个事件`,
        session.has_multiple_modes ? "多模式" : "",
      ].filter(Boolean);
      item.innerHTML = `
        <time>${escapeHtml(auditProtocol.compactAuditTime(session.started_at || session.updated_at || ""))}</time>
        <div class="body">
          <strong>${escapeHtml(session.session_id || session.path || "session")}</strong>
          <span>${escapeHtml(headline)}</span>
          <div class="event-meta">
            ${badges.map((badge) => `<span class="mini-pill">${escapeHtml(badge)}</span>`).join("")}
            <span class="mini-pill risk ${app.statusKind(session.status)}">${escapeHtml(session.status || "unknown")}</span>
          </div>
          <p class="event-detail">${escapeHtml(session.event_summary || "没有关键事件摘要。")}</p>
          ${highlights.length ? `<div class="event-lines">${highlights.slice(0, 3).map((highlight) => `
            <div class="event-line">${escapeHtml(highlight.title || highlight.stage || "事件")}${highlight.detail ? `：${escapeHtml(highlight.detail)}` : ""}</div>
          `).join("")}</div>` : ""}
        </div>
      `;
      item.addEventListener("click", () => readAudit(session.session_id));
      container.appendChild(item);
    }
  }

  function filteredAuditSessions() {
    const text = String($("auditSessionFilter")?.value || "").trim().toLowerCase();
    const status = String($("auditStatusFilter")?.value || "");
    const limit = Math.max(1, Math.min(200, Number($("auditLimitInput")?.value || 40)));
    return (state.auditSessions || [])
      .filter((session) => {
        const haystack = [
          session.session_id,
          session.status,
          session.started_at,
          session.updated_at,
          session.path,
          session.file,
          session.entrypoint,
          session.mode_label,
          auditModeLabel(session.modes || [], session.mode_label),
          session.event_summary,
          ...(session.modes || []),
        ].join(" ").toLowerCase();
        if (text && !haystack.includes(text)) return false;
        if (status && String(session.status || "") !== status) return false;
        return true;
      })
      .slice(0, limit);
  }

  async function readAudit(sessionId) {
    const data = await app.api("/api/audit/read", { method: "POST", body: { session_id: sessionId } });
    state.currentAuditSession = sessionId;
    state.auditEvents = Array.isArray(data.events) ? data.events : [];
    state.auditWebTimeline = data.web_timeline || null;
    state.auditTimelineUnavailableReason = data.timeline_unavailable_reason || "";
    renderAuditEventTimeline();
    renderAuditObserverSummary();
    updateAuditMetrics();
    $("auditOutput").textContent = renderAuditReadableReport(data);
    if ($("auditRestoreTimelineBtn")) {
      $("auditRestoreTimelineBtn").disabled = !(
        state.auditWebTimeline?.timeline?.length ||
        state.auditWebTimeline?.turns?.length
      );
    }
  }

  function renderAuditEventTimeline() {
    const container = $("auditList");
    if (!container) return;
    const generation = ++auditRenderGeneration;
    const events = filteredAuditEvents();
    const batchSize = auditEventBatchSize();
    container.innerHTML = "";
    if (!events.length) {
      container.appendChild(emptyEvent(state.currentAuditSession ? "当前筛选下没有事件" : "尚未选择 session"));
      return;
    }

    function appendBatch(start) {
      if (generation !== auditRenderGeneration) return;
      const batch = nextAuditRenderBatch(events, start, batchSize);
      const fragment = document.createDocumentFragment();
      for (const event of batch.events) {
        const item = document.createElement("div");
        item.className = "event";
        const display = auditProtocol.auditEventDisplay(event, pretty);
        item.innerHTML = `
          <time>${escapeHtml(auditProtocol.compactAuditTime(auditProtocol.auditEventTime(event)))}</time>
          <div class="body">
            <strong>${escapeHtml(display.title)}</strong>
            <span>${escapeHtml(display.summary || "事件已记录。")}</span>
            <div class="event-meta">
              <span class="mini-pill">${escapeHtml(display.stage)}</span>
              ${display.status ? `<span class="mini-pill risk ${app.statusKind(display.status)}">${escapeHtml(display.status)}</span>` : ""}
              ${display.badges.map((badge) => `<span class="mini-pill">${escapeHtml(badge)}</span>`).join("")}
            </div>
            ${display.details.length ? `<div class="event-lines">${display.details.map((line) => `<div class="event-line">${escapeHtml(line)}</div>`).join("")}</div>` : ""}
          </div>
        `;
        fragment.appendChild(item);
      }
      container.appendChild(fragment);
      if (!batch.done) window.requestAnimationFrame(() => appendBatch(batch.nextIndex));
    }

    appendBatch(0);
  }

  function auditEventBatchSize() {
    return Math.max(1, Math.min(200, Number($("auditLimitInput")?.value || 40)));
  }

  function filteredAuditEvents() {
    const category = String($("auditEventFilter")?.value || "");
    return (state.auditEvents || [])
      .filter((event) => !category || auditProtocol.auditEventMatchesCategory(event, category, pretty));
  }

  function auditSummaryText(event) {
    return auditProtocol.auditEventSummary(event, pretty) || "无摘要字段，完整内容见右侧报告。";
  }

  function renderAuditReadableReport(data) {
    const events = Array.isArray(data.events) ? data.events : [];
    const restored = data.web_timeline || {};
    const selectedSession = (state.auditSessions || []).find((session) => session.session_id === data.session_id) || {};
    const integrity = data.integrity && typeof data.integrity === "object" ? data.integrity : {};
    const integrityKnown = typeof data.integrity_ok === "boolean" || typeof integrity.ok === "boolean";
    const integrityOk = data.integrity_ok === true && integrity.ok !== false;
    const integrityBreaks = Array.isArray(integrity.breaks) ? integrity.breaks : [];
    const lines = [
      `Session: ${data.session_id || state.currentAuditSession || "--"}`,
      `来源: ${selectedSession.entrypoint_label || (selectedSession.entrypoint === "web" ? "Web" : "CLI") || "--"}`,
      `模式: ${auditModeLabel(selectedSession.modes || [], selectedSession.mode_label) || "--"}`,
      `状态: ${selectedSession.status || restored.status || data.status || "--"}`,
      `事件数: ${events.length}`,
      `完整性: ${integrityKnown ? (integrityOk ? "通过" : "失败") : "未校验"}`,
      ...(integrityKnown && !integrityOk
        ? [`完整性断点: ${integrityBreaks.length ? integrityBreaks.map((item) => `${item.line || "?"}:${item.reason || "unknown"}`).join(", ") : "未提供"}`]
        : []),
      `可回放轮次: ${Array.isArray(restored.turns) ? restored.turns.length : 0}`,
      `可回放步骤: ${Array.isArray(restored.timeline) ? restored.timeline.length : 0}`,
      ...(data.timeline_unavailable_reason
        ? [`Timeline: 不可用（${data.timeline_unavailable_reason}）；该会话仅显示只读审计事件。`]
        : []),
      "",
      "事件时间线:",
    ];
    events.forEach((event, index) => {
      const display = auditProtocol.auditEventDisplay(event, pretty);
      lines.push(`${index + 1}. ${auditProtocol.compactAuditTime(auditProtocol.auditEventTime(event))} ${display.title} - ${display.summary || "已记录"}`);
      display.details.forEach((detail) => lines.push(`   ${detail}`));
    });
    // Keep the human timeline above, but also expose every stored event. The
    // API has already applied redaction and returned hash-chain validation; rebuilding
    // only summaries here made payloads disappear from the audit console.
    if (events.length) {
      lines.push("", "完整 JSONL 事件:");
      events.forEach((event) => lines.push(JSON.stringify(event)));
    }
    return lines.join("\n");
  }

  function auditModeLabel(modes, fallback = "") {
    const labels = {
      work: "Work 工作台",
      terminal: "Terminal 终端",
      script: "Script 脚本",
      edit: "Edit 编辑",
    };
    const source = Array.isArray(modes) && modes.length ? modes : String(fallback || "").split("+").map((item) => item.trim()).filter(Boolean);
    if (!source.length) return fallback || "";
    return source.map((mode) => labels[mode] || mode).join(" + ");
  }

  function auditSessionHeadline(session, modeDisplay) {
    if (session.headline && session.mode_label) {
      return session.headline.replace(session.mode_label, modeDisplay || session.mode_label);
    }
    if (session.headline && !modeDisplay) return session.headline;
    const entrypoint = session.entrypoint_label || (session.entrypoint === "web" ? "Web" : "CLI");
    const eventCount = session.event_count ?? 0;
    return `${eventCount} 个事件 · ${entrypoint} · ${modeDisplay || "未记录模式"}`;
  }

  function renderAuditObserverSummary() {
    const container = $("auditObserverSummary");
    if (!container) return;
    const observerEvents = (state.auditEvents || []).filter((event) => auditProtocol.auditEventMatchesCategory(event, "observer", pretty));
    container.innerHTML = "";
    if (!observerEvents.length) {
      container.innerHTML = '<tr><td colspan="3">当前 session 没有 observer 事件。</td></tr>';
      return;
    }
    for (const event of observerEvents) {
      const payload = /** @type {Record<string, any>} */ (event.payload || event.data || event);
      const display = auditProtocol.auditEventDisplay(event, pretty);
      const status = payload.status || payload.lifecycle || auditProtocol.auditEventName(event);
      const row = document.createElement("tr");
      row.innerHTML = `
        <td><span class="pill risk ${app.statusKind(status)}">${escapeHtml(status)}</span></td>
        <td class="mono">${escapeHtml(auditProtocol.auditEventName(event))}</td>
        <td>${escapeHtml([display.summary, ...display.details].filter(Boolean).join("；"))}</td>
      `;
      container.appendChild(row);
    }
  }

  function updateAuditMetrics() {
    const events = state.auditEvents || [];
    const textFor = (event) => `${auditProtocol.auditEventName(event)} ${pretty(event)}`.toLowerCase();
    const decisions = events.filter((event) => /decision|approve|reject|skip|terminate/.test(textFor(event))).length;
    const commands = events.filter((event) => /command|terminal|script|execution/.test(textFor(event))).length;
    const observer = events.filter((event) => auditProtocol.auditEventMatchesCategory(event, "observer", pretty)).length;
    setText("auditMetricEvents", String(events.length));
    setText("auditMetricDecisions", String(decisions));
    setText("auditMetricCommands", String(commands));
    setText("auditMetricObserver", String(observer));
  }

  function resetAuditSummary() {
    setText("auditMetricEvents", "--");
    setText("auditMetricDecisions", "--");
    setText("auditMetricCommands", "--");
    setText("auditMetricObserver", "--");
    const observer = $("auditObserverSummary");
    if (observer) observer.innerHTML = '<tr><td colspan="3">尚未选择 session。</td></tr>';
    setText("auditOutput", "等待选择审计 session。");
    state.auditWebTimeline = null;
    if ($("auditRestoreTimelineBtn")) $("auditRestoreTimelineBtn").disabled = true;
  }

  function exportAuditReport() {
    const text = $("auditOutput").textContent || "";
    if (!text.trim()) return showToast("No audit report to export");
    const blob = new Blob([text], { type: "text/plain;charset=utf-8" });
    const url = URL.createObjectURL(blob);
    const link = document.createElement("a");
    link.href = url;
    link.download = `audit-replay-${Date.now()}.txt`;
    document.body.appendChild(link);
    link.click();
    link.remove();
    URL.revokeObjectURL(url);
  }

  async function downloadRuntimeBackup() {
    const response = await fetch("/api/runtime/backup", {
      headers: { Authorization: `Bearer ${state.token}` },
      cache: "no-store",
    });
    if (!response.ok) {
      let message = `运行时备份失败 (${response.status})`;
      try {
        const error = await response.json();
        message = error.error || error.status || message;
      } catch (_error) {
        // Binary endpoint may fail before a JSON body is available.
      }
      showToast(message);
      return;
    }
    const blob = await response.blob();
    const disposition = response.headers.get("Content-Disposition") || "";
    const filename = disposition.match(/filename="([^"]+)"/)?.[1] || `linux-agent-runtime-backup-${Date.now()}.tar.gz`;
    const url = URL.createObjectURL(blob);
    const link = document.createElement("a");
    link.href = url;
    link.download = filename;
    document.body.appendChild(link);
    link.click();
    link.remove();
    URL.revokeObjectURL(url);
    showToast("运行时脱敏备份已下载");
  }

  function toggleAuditPause() {
    state.auditPaused = !state.auditPaused;
    setText("auditPauseBtn", state.auditPaused ? "继续" : "暂停");
  }

  function findAuditFailure() {
    const events = [...document.querySelectorAll("#auditList .event")];
    const target = events.find((item) => /fail|error|blocked|denied|失败|错误|阻断/i.test(item.textContent || ""));
    if (!target) return showToast("未找到失败事件");
    target.scrollIntoView({ behavior: "smooth", block: "center" });
    target.classList.add("focused-event");
    window.setTimeout(() => target.classList.remove("focused-event"), 1800);
  }

  async function restoreAuditTimelineToWorkbench() {
    const preview = state.auditWebTimeline;
    if (!preview?.timeline?.length && !preview?.turns?.length) {
      return showToast("当前审计 session 没有可恢复的工作时间线");
    }
    const sessionId = state.currentAuditSession || preview.session_id || "";
    const backend = await app.api("/api/session/restore", { method: "POST", body: { session_id: sessionId } });
    if (!backend.ok) {
      showToast(backend.error || backend.status || "恢复会话失败");
      return;
    }
    hooks.restoreTimelineFromAudit({ backend, preview, sessionId });
    hooks.showScreen("workbench");
    showToast("已从审计恢复工作时间线和上下文");
  }


  return {
    loadAuditList,
    scheduleAuditListReload,
    renderAuditSessionList,
    filteredAuditSessions,
    readAudit,
    renderAuditEventTimeline,
    filteredAuditEvents,
    auditSummaryText,
    renderAuditReadableReport,
    auditModeLabel,
    auditSessionHeadline,
    renderAuditObserverSummary,
    updateAuditMetrics,
    resetAuditSummary,
    exportAuditReport,
    downloadRuntimeBackup,
    toggleAuditPause,
    findAuditFailure,
    restoreAuditTimelineToWorkbench,
  };
}
