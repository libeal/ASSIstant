/** @typedef {import("./types.js").AppContext} AppContext */
/** @typedef {import("./types.js").ObserverBootstrapView} ObserverBootstrapView */

/** @param {AppContext} app @returns {ObserverBootstrapView} */
export function createObserverBootstrap(app) {
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

  function observerStatusKind(status) {
    const text = String(status || "").toLowerCase();
    if (["enabled", "disabled"].includes(text)) return "low";
    if (["pending", "skipped", "sudo_required"].includes(text)) return "medium";
    return "high";
  }

  function setObserverBootstrapState(data) {
    state.observerBootstrap = data || null;
    const status = data?.status || "pending";
    const button = $("observerAuditBtn");
    if (button) {
      const kind = observerStatusKind(status);
      button.className = `pill status-action risk ${kind}`;
      button.title = data?.error || data?.diagnostic || "observer bootstrap status";
    }
    setText("observerState", status);
    setStatus("observerAuditStatus", status, observerStatusKind(status));
    const output = $("observerAuditOutput");
    if (output && data) output.textContent = pretty(data);
  }

  function shouldPromptObserverBootstrap(data) {
    return Boolean(data?.requires_permission && data.status === "pending" && !state.observerBootstrapPrompted);
  }

  function observerHelperNeedsRepair(data) {
    return data?.status === "observer_helper_failed" ||
      (data?.method === "helper" && data?.ok === false);
  }

  async function loadObserverBootstrapStatus({ prompt = false } = {}) {
    const data = await app.api("/api/observer/bootstrap");
    setObserverBootstrapState(data);
    if (prompt && shouldPromptObserverBootstrap(data)) {
      state.observerBootstrapPrompted = true;
      openObserverAuditDialog(data);
    }
    return data;
  }

  function openObserverAuditDialog(data = state.observerBootstrap) {
    if (observerHelperNeedsRepair(data)) {
      showToast(data?.error || data?.diagnostic || "请先修复 observer helper socket 权限");
      return;
    }
    if (!state.token) {
      showToast("Token required");
      return;
    }
    setObserverBootstrapState(data || state.observerBootstrap || { status: "pending", ok: true });
    const password = $("observerAuditPassword");
    if (password) password.value = "";
    const dialog = $("observerAuditDialog");
    if (!dialog) return;
    if (typeof dialog.showModal === "function") {
      if (!dialog.open) dialog.showModal();
    } else {
      dialog.setAttribute("open", "");
    }
    password?.focus();
  }

  function closeObserverAuditDialog() {
    const dialog = $("observerAuditDialog");
    if (!dialog) return;
    if (typeof dialog.close === "function" && dialog.open) dialog.close();
    else dialog.removeAttribute("open");
  }

  async function enableObserverAudit() {
    if (observerHelperNeedsRepair(state.observerBootstrap)) {
      showToast(
        state.observerBootstrap?.error ||
          state.observerBootstrap?.diagnostic ||
          "请先修复 observer helper socket 权限",
      );
      closeObserverAuditDialog();
      return;
    }
    const password = $("observerAuditPassword")?.value || "";
    const data = await app.api("/api/observer/bootstrap", {
      method: "POST",
      body: { action: "enable", password },
    });
    if ($("observerAuditPassword")) $("observerAuditPassword").value = "";
    setObserverBootstrapState(data);
    if (data.ok && data.status === "enabled") {
      closeObserverAuditDialog();
      showToast("内核审计已启用");
      return;
    }
    showToast(data.error || data.status || "observer bootstrap failed");
  }

  async function skipObserverAudit() {
    const data = await app.api("/api/observer/bootstrap", {
      method: "POST",
      body: { action: "skip" },
    });
    if ($("observerAuditPassword")) $("observerAuditPassword").value = "";
    setObserverBootstrapState(data);
    closeObserverAuditDialog();
    showToast(data.logged ? "已记录未启用审计" : "已跳过审计授权");
  }


  return {
    observerStatusKind,
    observerHelperNeedsRepair,
    setObserverBootstrapState,
    shouldPromptObserverBootstrap,
    loadObserverBootstrapStatus,
    openObserverAuditDialog,
    closeObserverAuditDialog,
    enableObserverAudit,
    skipObserverAudit,
  };
}
