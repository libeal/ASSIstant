import { createInitialState } from "./modules/store.js";
import { requestJson } from "./modules/api.js";
import { normalizeExecutionEntries, completedExecutionCount } from "./modules/timeline.js";
import {
  findBlockJson,
  outputBlocksFrom,
  outputBlocksSummary,
  outputBlocksText,
  renderOutputBlocksHtml,
  userOutputBlocks,
} from "./modules/output-blocks.js";
import { normalizeApprovalCard } from "./modules/approval.js";
import * as auditProtocol from "./modules/audit.js";
import { CONFIG_GROUPS, CONFIG_READONLY_FIELDS } from "./modules/policy-config.js";
import { renderMarkdown } from "./modules/markdown.js";
import {
  REMOTE_API_KEY_TRANSMISSION_KEY,
  THINKING_TRACE_KEY,
  hiddenOutputKeys,
  outputLabelMap,
  titles,
} from "./modules/constants.js";
import {
  $,
  emptyEvent,
  emptyItem,
  escapeHtml,
  on,
  pillKind,
  pretty,
  riskKind,
  setStatus,
  setSwitch,
  setText,
  showToast,
} from "./modules/dom.js";
import { createLayoutController, initSidebarToggle } from "./modules/layout.js";
import * as renderOutput from "./modules/render-output.js";
import * as workbenchTurns from "./modules/workbench-turns.js";
import { createJobClient } from "./modules/job-client.js";
import { createObserverBootstrap } from "./modules/observer-bootstrap.js";
import { createWorkbenchView } from "./modules/view-workbench.js";
import { createConfigView } from "./modules/view-config.js";
import { createSkillsView } from "./modules/view-skills.js";
import { createAuditView } from "./modules/view-audit.js";
import { createPolicyView } from "./modules/view-policy.js";
import { bindApplicationEvents } from "./modules/app-bindings.js";
import { consumeBootstrapFromLocation } from "./modules/auth.js";

/** @typedef {import("./modules/types.js").ApplicationController} ApplicationController */

const state = createInitialState();
const { initPanelLayout, setLayoutRunId, bindPanelDrag } = createLayoutController(state);
let auditListReloadTimer = 0;

/** Shared runtime controller assembled from typed view modules. */
const app = /** @type {ApplicationController} */ (/** @type {unknown} */ ({
  state,
  get auditListReloadTimer() { return auditListReloadTimer; },
  set auditListReloadTimer(v) { auditListReloadTimer = v; },
  sessionTurnCounter: 0,
  $,
  on,
  setText,
  setStatus,
  setSwitch,
  showToast,
  pretty,
  escapeHtml,
  emptyItem,
  emptyEvent,
  riskKind,
  pillKind,
  titles,
  renderMarkdown,
  auditProtocol,
  CONFIG_GROUPS,
  CONFIG_READONLY_FIELDS,
  THINKING_TRACE_KEY,
  REMOTE_API_KEY_TRANSMISSION_KEY,
  hiddenOutputKeys,
  outputLabelMap,
  outputBlocksFrom,
  outputBlocksText,
  outputBlocksSummary,
  renderOutputBlocksHtml,
  userOutputBlocks,
  findBlockJson,
  normalizeExecutionEntries,
  completedExecutionCount,
  normalizeApprovalCard,
  ...renderOutput,
  entryStepKey: workbenchTurns.entryStepKey,
  normalizedTurnEntries: workbenchTurns.normalizedTurnEntries,
  workPlanMarkdown: workbenchTurns.workPlanMarkdown,
  turnCanEnterContextPure: workbenchTurns.turnCanEnterContext,
  createSessionTurnPure: workbenchTurns.createSessionTurn,
  normalizeRestoredTurnPure: workbenchTurns.normalizeRestoredTurn,
  upsertSessionTurnPure: workbenchTurns.upsertSessionTurn,
  contextTurnCapacityPure: workbenchTurns.contextTurnCapacity,
  contextMetaByTurnPure: workbenchTurns.contextMetaByTurn,
}));

async function request(path, options = {}) {
  return requestJson(path, options, () => state.token);
}
app.request = request;
Object.assign(app, createJobClient({
  request,
  getState: () => state,
  printOutput: (...args) => app.printOutput(...args),
  setStatus,
}));

function statusKind(value) {
  const text = String(value || "").toLowerCase();
  const presentation = state.domainSchema?.status_presentation || {};
  for (const kind of ["low", "medium", "high"]) {
    if (Array.isArray(presentation[kind]) && presentation[kind].includes(text)) return kind;
  }
  return pillKind(text);
}

async function api(path, options = {}) {
  return request(path, options);
}

async function shutdownServer() {
  if (!state.token) {
    showToast("Token required");
    return;
  }
  if (!window.confirm("结束 agent-web 进程并关闭当前界面？")) return;
  const result = await api("/api/server/shutdown", { method: "POST", body: {} });
  showShutdownScreen(result);
}

function showShutdownScreen(result) {
  const overlay = $("shutdownOverlay");
  if (!overlay) {
    showToast(result?.message || "Server shutting down");
    return;
  }
  overlay.hidden = false;
  setText("shutdownMessage", result?.message || "Web 控制台已请求关闭。");
  setStatus("connectionState", "offline", "high");
}

function parseJsonText(id) {
  const control = $(id);
  const raw = control instanceof HTMLInputElement || control instanceof HTMLTextAreaElement
    ? control.value.trim()
    : "";
  if (!raw) return {};
  return JSON.parse(raw);
}

async function connect() {
  const tokenInput = $("tokenInput");
  state.token = tokenInput instanceof HTMLInputElement ? tokenInput.value.trim() : "";
  if (!state.token) {
    showToast("Token required");
    return;
  }
  localStorage.setItem("linuxAgentToken", state.token);
  const health = await api("/api/health");
  if (!health?.ok) {
    setStatus("connectionState", "offline", "high");
    setText("rootPath", "未连接");
    if (health?.status === "unauthorized") localStorage.removeItem("linuxAgentToken");
    throw new Error(health?.error || health?.status || "连接失败");
  }
  setLayoutRunId(health.web_server?.run_id || "");
  setStatus("connectionState", "online", "ok");
  setText("rootPath", health.root || "connected");
  await loadDomainSchema();
  await app.loadConfig();
  await app.loadSessionState();
  await app.loadObserverBootstrapStatus({ prompt: true });
  await app.loadSense();
  await app.loadTools();
  await app.loadSkillTree();
  await app.loadMcpRegistry();
  await app.loadAuditList();
  await app.loadPolicies();
  showToast("Connected");
}

async function exchangeBootstrap(bootstrap) {
  const result = await requestJson(
    "/api/auth/bootstrap",
    { method: "POST", body: { bootstrap } },
    () => "",
  );
  if (!result?.ok || !result.token) {
    throw new Error(result?.error || "自动认证失败，请手动输入 token");
  }
  return String(result.token);
}

async function loadDomainSchema() {
  try {
    const data = await api("/api/schema");
    if (data?.ok && data.schema) state.domainSchema = data.schema;
  } catch (_err) {
    // Non-fatal for basic rendering; protocol validation remains unavailable.
  }
}

function showScreen(name) {
  document.querySelectorAll(".screen").forEach((el) => el.classList.toggle("active", el.id === `screen-${name}`));
  /** @type {HTMLElement|null} */
  let activeButton = null;
  document.querySelectorAll(".nav button").forEach((el) => {
    if (!(el instanceof HTMLElement)) return;
    const active = el.dataset.screen === name;
    el.classList.toggle("active", active);
    if (active) {
      el.setAttribute("aria-current", "page");
      activeButton = el;
    } else {
      el.removeAttribute("aria-current");
    }
  });
  setText("screenTitle", titles[name] || name);
  scrollActiveNavigationIntoView(activeButton);
}

function scrollActiveNavigationIntoView(button) {
  if (!button || !window.matchMedia("(max-width: 760px)").matches) return;
  const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  window.requestAnimationFrame(() => {
    button.scrollIntoView({ block: "nearest", inline: "nearest", behavior: reducedMotion ? "auto" : "smooth" });
  });
}

async function safeAction(fn) {
  try {
    await fn();
  } catch (error) {
    showToast(error instanceof Error ? error.message : String(error));
    console.error(error);
  }
}

function init() {
  const bootstrap = consumeBootstrapFromLocation();
  const tokenInput = $("tokenInput");
  if (tokenInput instanceof HTMLInputElement) tokenInput.value = state.token;
  app.updateWorkActionLabel();
  app.updateTerminalActionState();
  app.updatePolicyEditState();
  initPanelLayout();
  initSidebarToggle();
  bindApplicationEvents(app, { safeAction, showScreen, connect, shutdownServer, state });
  bindPanelDrag();
  if (bootstrap) {
    safeAction(async () => {
      state.token = await exchangeBootstrap(bootstrap);
      if (tokenInput instanceof HTMLInputElement) tokenInput.value = state.token;
      await connect();
    });
  } else if (state.token) {
    safeAction(connect);
  }
}

Object.assign(app, {
  statusKind,
  api,
  request,
  shutdownServer,
  showShutdownScreen,
  parseJsonText,
  connect,
  loadDomainSchema,
  showScreen,
  scrollActiveNavigationIntoView,
  safeAction,
  init,
  setLayoutRunId,
  initPanelLayout,
  bindPanelDrag,
  initSidebarToggle,
});

Object.assign(app, createObserverBootstrap(app));
const workbenchView = createWorkbenchView(app);
Object.assign(app, workbenchView);
Object.assign(app, createConfigView(app, {
  renderWorkbench: () => {
    workbenchView.renderThinkingSummary();
    workbenchView.renderSessionTimeline();
  },
  renderThinkingSummary: workbenchView.renderThinkingSummary,
  setThinkingSwitches: workbenchView.setThinkingSwitches,
  thinkingTraceEnabled: workbenchView.thinkingTraceEnabled,
  updateRemoteActionState: workbenchView.updateRemoteActionState,
}));
Object.assign(app, createSkillsView(app));
Object.assign(app, createAuditView(app, {
  restoreTimelineFromAudit: workbenchView.restoreTimelineFromAudit,
  showScreen,
}));
Object.assign(app, createPolicyView(app));

init();
