import { createInitialState } from "./modules/state.js";
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

const state = createInitialState();

const $ = (id) => document.getElementById(id);
const LAYOUT_STORAGE_PREFIX = "assistant.panelLayout.v1";
const THINKING_TRACE_KEY = "agent_loop.thinking_trace_enabled";
let sessionTurnCounter = 0;

const titles = {
  workbench: "工作台",
  skills: "Skill 库",
  policy: "策略",
  audit: "审计与回放",
  config: "配置中心",
};

const outputLabelMap = {
  status: "状态",
  failed: "失败服务",
  load: "系统负载",
  load_summary: "系统负载",
  memory: "内存",
  memory_summary: "内存",
  top_processes: "高占用进程",
  disk_usage: "磁盘使用",
  df_summary: "磁盘使用",
  top_dirs: "目录占用",
  top_files: "大文件",
  processes: "进程列表",
  zombies: "僵尸进程",
  error: "错误",
  stdout: "标准输出",
  stderr: "错误输出",
  exit_code: "退出码",
  command: "命令",
  result: "结果",
  results: "步骤结果",
  output: "输出",
  review: "审查结果",
  edit: "编辑包",
  scripts: "脚本",
  path: "路径",
  content: "内容",
  summary: "摘要",
  thinking_summary: "thinking_summary",
  config_updated: "配置已更新",
  value: "值",
  execution_proxy: "执行代理",
  auto_approved: "自动批准",
  risk_level: "风险",
  executor_type: "执行器",
  skill_script: "Skill",
};

const hiddenOutputKeys = new Set([
  "ok",
  "tool",
  "job_id",
  "response_type",
  "execution_proxy",
  "observer",
  "auto_approved",
  "root_pid",
  "session_status",
  "backend",
  "lifecycle",
  "scope",
  "subject",
  "step",
]);

function escapeHtml(value) {
  return String(value ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function showToast(message) {
  const toast = $("toast");
  toast.textContent = message;
  toast.classList.add("show");
  window.setTimeout(() => toast.classList.remove("show"), 2600);
}

function setText(id, value) {
  const el = $(id);
  if (el) el.textContent = value;
}

function pillKind(kind) {
  if (["ok", "low", "succeeded", "completed", "read", "saved"].includes(kind)) return "low";
  if (["warn", "medium", "running", "queued", "approval_required", "planning", "review"].includes(kind)) return "medium";
  if (["err", "error", "failed", "high", "critical"].includes(kind)) return "high";
  return "";
}

function setStatus(id, value, kind = "") {
  const el = $(id);
  if (!el) return;
  const mapped = pillKind(kind);
  el.textContent = value;
  el.className = mapped ? `pill risk ${mapped}` : "pill";
}

function setSwitch(id, enabled) {
  const el = $(id);
  if (!el) return;
  el.classList.toggle("on", Boolean(enabled));
  el.setAttribute("aria-pressed", enabled ? "true" : "false");
}

function setThinkingSwitches(enabled) {
  setSwitch("thinkingTraceSwitch", enabled);
  setSwitch(configInputId(THINKING_TRACE_KEY), enabled);
}

function thinkingTraceEnabled() {
  return Boolean($("thinkingTraceSwitch")?.classList.contains("on"));
}

function renderThinkingSummary(summary = state.lastThinkingSummary) {
  const el = $("workOutput");
  if (!el) return;
  if (!thinkingTraceEnabled()) {
    el.textContent = "thinking_summary 未开启。开启开关后，新请求会在这里显示模型返回的简短思考摘要。";
    return;
  }
  const text = String(summary || "").trim();
  el.textContent = text || "已开启 thinking_summary；本轮尚未返回模型思考摘要。";
}

function firstLine(value) {
  return String(value || "").split("\n").find((line) => line.trim()) || "--";
}

function compactText(value, max = 220) {
  const text = String(value ?? "").replace(/\s+/g, " ").trim();
  if (!text) return "";
  return text.length > max ? `${text.slice(0, max)}...` : text;
}

function getNestedValue(source, path) {
  return String(path || "").split(".").reduce((current, key) => {
    if (!current || typeof current !== "object") return undefined;
    return current[key];
  }, source);
}

function configInputId(key) {
  return `config-${String(key).replace(/[^A-Za-z0-9_-]/g, "-")}`;
}

function statusKind(value) {
  const text = String(value || "").toLowerCase();
  if (["ok", "executed", "succeeded", "success", "approved", "auto_approved"].includes(text)) return "low";
  if (["running", "queued", "approval_required", "pending", "skipped", "review"].includes(text)) return "medium";
  if (["failed", "blocked", "rejected", "terminated", "critical", "high"].includes(text)) return "high";
  return pillKind(text);
}

function primaryOutputObject(output) {
  const blocks = outputBlocksFrom(output);
  const blockJson = findBlockJson(blocks, "json");
  if (Object.keys(blockJson).length) return blockJson;
  if (isPlainObject(output?.output)) return output.output;
  return isPlainObject(output) ? output : {};
}

function outputSummaryText(output) {
  const blockSummary = outputBlocksSummary(output);
  if (blockSummary) return blockSummary;
  const payload = primaryOutputObject(output);
  for (const key of ["summary", "message", "action", "error"]) {
    if (typeof payload[key] === "string" && payload[key].trim()) return compactText(payload[key], 260);
    if (typeof output?.[key] === "string" && output[key].trim()) return compactText(output[key], 260);
  }
  const raw = extractRawOutput(output);
  if (raw) return compactText(raw, 260);
  const text = renderUserOutputText(payload);
  return compactText(text, 260) || "无摘要输出";
}

function renderOutputSection(key, value) {
  const label = outputLabel(key);
  const text = renderUserOutputText(value);
  return `
    <section class="output-section">
      <h5>${escapeHtml(label)}</h5>
      <pre class="inline-code">${escapeHtml(text)}</pre>
    </section>
  `;
}

function renderPrimaryOutputHtml(output) {
  const blocks = outputBlocksFrom(output);
  if (blocks.length) return renderOutputBlocksHtml(blocks);
  const payload = primaryOutputObject(output);
  const chunks = [];
  const renderedKeys = new Set();
  const preferred = [
    "summary", "message", "error", "command", "stdout", "stderr", "load", "memory", "disk_usage", "df_summary",
    "top_dirs", "top_files", "top_processes", "processes", "journal", "journal_sample", "matches",
  ];
  for (const key of preferred) {
    const value = payload[key] ?? output?.[key];
    if (isEmptyOutputValue(value)) continue;
    chunks.push(renderOutputSection(key, value));
    renderedKeys.add(key);
  }
  if (isPlainObject(payload)) {
    for (const [key, value] of Object.entries(payload)) {
      if (renderedKeys.has(key) || hiddenOutputKeys.has(key) || isEmptyOutputValue(value)) continue;
      chunks.push(renderOutputSection(key, value));
    }
  }
  if (chunks.length) return chunks.join("");
  return `<p class="muted">${escapeHtml(outputSummaryText(output))}</p>`;
}

function terminalReturnPayload(output) {
  const blocks = outputBlocksFrom(output);
  if (blocks.length) {
    const visibleBlocks = userOutputBlocks(blocks);
    return visibleBlocks.length ? { output_blocks: visibleBlocks } : {};
  }
  const payload = primaryOutputObject(output);
  const merged = {};
  for (const key of ["command", "stdout", "stderr", "summary", "message", "error"]) {
    const value = payload[key] ?? output?.[key];
    if (!isEmptyOutputValue(value)) merged[key] = value;
  }
  if (!Object.keys(merged).length && isPlainObject(payload)) return payload;
  return merged;
}

function renderTerminalReturnHtml(output) {
  const payload = terminalReturnPayload(output);
  if (isEmptyOutputValue(payload)) {
    return `<p class="muted">本步骤没有返回 stdout/stderr；可展开原始调试数据确认执行元信息。</p>`;
  }
  return renderPrimaryOutputHtml(payload);
}

function renderMetaRows(rows) {
  return rows
    .filter(([, value]) => !isEmptyOutputValue(value))
    .map(([label, value]) => `<div class="meta-row"><span>${escapeHtml(label)}</span><strong>${escapeHtml(value)}</strong></div>`)
    .join("");
}

function renderJsonDetails(title, value, open = false) {
  if (isEmptyOutputValue(value)) return "";
  return `
    <details class="detail-block"${open ? " open" : ""}>
      <summary>${escapeHtml(title)}</summary>
      <pre class="code">${escapeHtml(pretty(value))}</pre>
    </details>
  `;
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
  status.className = `pill risk ${statusKind(entry.status)}`;
}

function currentLayoutStorageKey() {
  return state.layoutStorageKey || "";
}

function readCurrentLayout() {
  const containers = {};
  const children = {};
  document.querySelectorAll("[data-layout-container]").forEach((container) => {
    const containerId = container.dataset.layoutContainer;
    containers[containerId] = [...container.children]
      .filter((child) => child.dataset?.layoutPanel)
      .map((child) => child.dataset.layoutPanel);
    children[containerId] = [...container.children]
      .map(layoutChildToken)
      .filter(Boolean);
  });
  return { containers, children };
}

function loadSavedLayout() {
  const key = currentLayoutStorageKey();
  if (!key) return {};
  try {
    return JSON.parse(localStorage.getItem(key) || "{}");
  } catch {
    return {};
  }
}

function saveLayout() {
  const key = currentLayoutStorageKey();
  if (!key) return false;
  localStorage.setItem(key, JSON.stringify(readCurrentLayout()));
  return true;
}

function initPanelLayout() {
  let panelIndex = 0;
  document.querySelectorAll(".screen").forEach((screen) => {
    const containers = [screen, ...screen.querySelectorAll(".stack, .split, .split-wide")]
      .filter((container) => hasDirectLayoutPanel(container));
    containers.forEach((container, index) => {
      container.dataset.layoutContainer = `${screen.id}:container-${index}`;
      container.classList.add("layout-container");
      let staticIndex = 0;
      getDirectLayoutPanels(container).forEach((panel) => {
        if (!panel.dataset.layoutPanel) {
          panel.dataset.layoutPanel = `${screen.id}:panel-${panelIndex}`;
          panelIndex += 1;
        }
        panel.classList.add("layout-panel");
        addDragHandle(panel);
      });
      [...container.children].forEach((child) => {
        if (child.dataset.layoutPanel || child.dataset.layoutStatic) return;
        child.dataset.layoutStatic = `${container.dataset.layoutContainer}:static-${staticIndex}`;
        staticIndex += 1;
      });
    });
  });
  state.defaultLayout = readCurrentLayout();
}

function hasDirectLayoutPanel(container) {
  return getDirectLayoutPanels(container).length > 0;
}

function getDirectLayoutPanels(container) {
  return [...container.children].filter((child) => child.classList?.contains("panel") || child.classList?.contains("terminal"));
}

function addDragHandle(panel) {
  const header = panel.querySelector(":scope > .panel-header, :scope > .terminal-head");
  if (!header || header.querySelector(":scope > .drag-handle")) return;
  const handle = document.createElement("span");
  handle.className = "drag-handle";
  handle.draggable = true;
  handle.setAttribute("role", "button");
  handle.setAttribute("tabindex", "0");
  handle.setAttribute("aria-label", "拖动调整窗口位置");
  handle.setAttribute("title", "拖动调整窗口位置");
  handle.textContent = "⠿";
  header.appendChild(handle);
}

function layoutChildToken(child) {
  if (child.dataset?.layoutPanel) return `panel:${child.dataset.layoutPanel}`;
  if (child.dataset?.layoutStatic) return `static:${child.dataset.layoutStatic}`;
  return "";
}

function applyPanelLayout(layout) {
  const containers = layout.containers || layout;
  const children = layout.children || {};
  for (const [containerId, childTokens] of Object.entries(children)) {
    const container = findLayoutContainer(containerId);
    if (!container || !Array.isArray(childTokens)) continue;
    applyContainerChildLayout(container, childTokens);
  }
  for (const [containerId, panelIds] of Object.entries(containers)) {
    if (children[containerId]) continue;
    const container = findLayoutContainer(containerId);
    if (!container || !Array.isArray(panelIds)) continue;
    applyContainerPanelLayout(container, panelIds);
  }
}

function applyContainerChildLayout(container, childTokens) {
  for (const token of childTokens) {
    const child = findLayoutChild(token);
    if (child && child.closest(".screen") === container.closest(".screen")) {
      container.appendChild(child);
    }
  }
}

function applyContainerPanelLayout(container, panelIds) {
  const anchor = findPanelBlockAnchor(container);
  for (const panelId of panelIds) {
    const panel = findLayoutPanel(panelId);
    if (panel && panel.closest(".screen") === container.closest(".screen")) {
      if (anchor && anchor.parentElement === container) container.insertBefore(panel, anchor);
      else container.appendChild(panel);
    }
  }
}

function findPanelBlockAnchor(container) {
  const children = [...container.children];
  const firstPanelIndex = children.findIndex((child) => child.dataset?.layoutPanel);
  if (firstPanelIndex < 0) return null;
  return children.slice(firstPanelIndex).find((child) => !child.dataset?.layoutPanel) || null;
}

function applySavedLayout() {
  const saved = loadSavedLayout();
  applyPanelLayout(state.defaultLayout);
  if (saved.containers) applyPanelLayout(saved);
}

function setLayoutRunId(runId) {
  if (!runId) {
    state.webRunId = "";
    state.layoutStorageKey = "";
    applyPanelLayout(state.defaultLayout);
    return;
  }
  const nextRunId = String(runId);
  const nextKey = `${LAYOUT_STORAGE_PREFIX}:${nextRunId}`;
  if (state.layoutStorageKey === nextKey) return;
  state.webRunId = nextRunId;
  state.layoutStorageKey = nextKey;
  applySavedLayout();
}

function bindPanelDrag() {
  document.addEventListener("dragstart", (event) => {
    const handle = event.target.closest(".drag-handle");
    if (!handle) return;
    const panel = handle.closest("[data-layout-panel]");
    if (!panel) return;
    state.draggedPanelId = panel.dataset.layoutPanel;
    panel.classList.add("layout-dragging");
    event.dataTransfer.effectAllowed = "move";
    event.dataTransfer.setData("text/plain", state.draggedPanelId);
  });

  document.addEventListener("dragover", (event) => {
    const container = event.target.closest("[data-layout-container]");
    const panel = getDraggedPanel();
    if (!container || !panel || container.closest(".screen") !== panel.closest(".screen")) return;
    event.preventDefault();
    container.classList.add("layout-drop-active");
    const after = getDragAfterElement(container, event.clientY);
    if (after) container.insertBefore(panel, after);
    else container.appendChild(panel);
  });

  document.addEventListener("dragleave", (event) => {
    const container = event.target.closest("[data-layout-container]");
    if (container && !container.contains(event.relatedTarget)) {
      container.classList.remove("layout-drop-active");
    }
  });

  document.addEventListener("drop", (event) => {
    const container = event.target.closest("[data-layout-container]");
    const panel = getDraggedPanel();
    if (!container || !panel || container.closest(".screen") !== panel.closest(".screen")) return;
    event.preventDefault();
    container.classList.remove("layout-drop-active");
    panel.classList.remove("layout-dragging");
    state.draggedPanelId = "";
    showToast(saveLayout() ? "布局已保存于本次进程" : "连接后可保存布局");
  });

  document.addEventListener("dragend", () => {
    document.querySelectorAll(".layout-dragging").forEach((panel) => panel.classList.remove("layout-dragging"));
    document.querySelectorAll(".layout-drop-active").forEach((container) => container.classList.remove("layout-drop-active"));
    if (state.draggedPanelId) saveLayout();
    state.draggedPanelId = "";
  });
}

function getDraggedPanel() {
  if (!state.draggedPanelId) return null;
  return findLayoutPanel(state.draggedPanelId);
}

function findLayoutContainer(id) {
  return [...document.querySelectorAll("[data-layout-container]")].find((container) => container.dataset.layoutContainer === id) || null;
}

function findLayoutPanel(id) {
  return [...document.querySelectorAll("[data-layout-panel]")].find((panel) => panel.dataset.layoutPanel === id) || null;
}

function findLayoutStatic(id) {
  return [...document.querySelectorAll("[data-layout-static]")].find((child) => child.dataset.layoutStatic === id) || null;
}

function findLayoutChild(token) {
  if (!token.includes(":")) return null;
  const separator = token.indexOf(":");
  const type = token.slice(0, separator);
  const id = token.slice(separator + 1);
  if (type === "panel") return findLayoutPanel(id);
  if (type === "static") return findLayoutStatic(id);
  return null;
}

function getDragAfterElement(container, y) {
  const elements = [...container.children].filter((child) => child.dataset?.layoutPanel && !child.classList.contains("layout-dragging"));
  return elements.reduce((closest, child) => {
    const box = child.getBoundingClientRect();
    const offset = y - box.top - box.height / 2;
    if (offset < 0 && offset > closest.offset) {
      return { offset, element: child };
    }
    return closest;
  }, { offset: Number.NEGATIVE_INFINITY, element: null }).element;
}

function pretty(value) {
  if (value === undefined) return "";
  if (typeof value === "string") return value;
  return JSON.stringify(value, null, 2);
}

function printOutput(id, value) {
  const el = $(id);
  if (!el) return;
  const blocks = outputBlocksFrom(value);
  el.textContent = blocks.length ? outputBlocksText(blocks) : renderUserOutputText(value);
}

function outputLabel(key) {
  return outputLabelMap[key] || key;
}

function isPlainObject(value) {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value);
}

function isEmptyOutputValue(value) {
  if (value === undefined || value === null || value === "") return true;
  if (Array.isArray(value)) return value.length === 0;
  if (isPlainObject(value)) return Object.keys(value).length === 0;
  return false;
}

function extractRawOutput(value) {
  if (!isPlainObject(value)) return "";
  if (outputBlocksFrom(value).length) return outputBlocksText(value);
  for (const key of ["output"]) {
    if (isPlainObject(value[key])) {
      const raw = extractRawOutput(value[key]);
      if (raw) return raw;
    }
  }
  return "";
}

function renderUserOutputText(value) {
  if (value === undefined) return "";
  if (typeof value === "string") return value;
  const raw = extractRawOutput(value);
  if (raw) return raw;
  if (Array.isArray(value)) return renderArrayOutputText(value);
  if (isPlainObject(value)) return renderObjectOutputText(value);
  return String(value);
}

function renderArrayOutputText(values) {
  return values
    .map((entry, index) => {
      const text = renderUserOutputText(entry);
      if (!text.trim()) return "";
      return isPlainObject(entry) ? `${index + 1}. ${text}` : text;
    })
    .filter(Boolean)
    .join("\n\n");
}

function renderObjectOutputText(value) {
  const rows = [];
  for (const [key, entry] of Object.entries(value)) {
    if (hiddenOutputKeys.has(key) || isEmptyOutputValue(entry)) continue;
    const text = renderUserOutputText(entry);
    if (!text.trim()) continue;
    const label = outputLabel(key);
    if (text.includes("\n")) rows.push(`${label}\n${text}`);
    else rows.push(`${label}: ${text}`);
  }
  return rows.join("\n\n");
}

function renderProtocolText(title, result) {
  const flowText = outputBlocksText(executionFlowBlocks(result));
  const entriesText = normalizeExecutionEntries(title, result)
    .map((entry) => {
      const body = outputBlocksFrom(entry.output).length ? outputBlocksText(entry.output) : renderUserOutputText(entry.output);
      const number = entry.number ?? entry.index;
      const header = `${number}. ${entry.title}${entry.status ? ` (${entry.status})` : ""}`;
      return body.trim() ? `${header}\n${body}` : header;
    })
    .join("\n\n");
  return [flowText, entriesText].filter((text) => text.trim()).join("\n\n");
}

function renderSharedExecutionOutput(title, result) {
  const flowText = outputBlocksText(executionFlowBlocks(result));
  if (flowText.trim()) return flowText;
  const blocks = outputBlocksFrom(result);
  if (blocks.length) return outputBlocksText(blocks);
  const entries = normalizeExecutionEntries(title, result);
  if (entries.length === 1) {
    const output = entries[0].output || result;
    const outputText = outputBlocksFrom(output).length ? outputBlocksText(output) : renderUserOutputText(output);
    if (outputText.trim()) return outputText;
  }
  return renderUserOutputText(result);
}

function executionFlowBlocks(result = state.lastProtocolResult) {
  return outputBlocksFrom(result).filter((block) => block?.title === "执行流程" && typeof block.text === "string" && block.text.trim());
}

function renderExecutionFlowHtml(result = state.lastProtocolResult) {
  const blocks = executionFlowBlocks(result);
  return blocks.length ? renderOutputBlocksHtml(blocks) : "";
}

async function api(path, options = {}) {
  return requestJson(path, options, () => state.token);
}

async function shutdownServer() {
  if (!state.token) {
    showToast("Token required");
    return;
  }
  if (!window.confirm("结束 agent-web 进程并关闭当前界面？")) return;
  const button = $("shutdownServerBtn");
  if (button) button.disabled = true;
  const result = await api("/api/server/shutdown", { method: "POST", body: {} });
  showShutdownScreen(result);
  window.setTimeout(() => {
    window.close();
  }, 500);
}

function showShutdownScreen(result) {
  document.body.innerHTML = `
    <main class="closed-screen">
      <section class="closed-card">
        <h1>Web 进程已结束</h1>
        <p>agent-web 正在停止。本次进程内的页面布局已结束，重新启动项目后会恢复初始界面。</p>
        <pre>${escapeHtml(pretty(result))}</pre>
      </section>
    </main>
  `;
}

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
    button.title = data?.diagnostic || "observer bootstrap status";
  }
  setText("observerState", status);
  setStatus("observerAuditStatus", status, observerStatusKind(status));
  const output = $("observerAuditOutput");
  if (output && data) output.textContent = pretty(data);
}

function shouldPromptObserverBootstrap(data) {
  return Boolean(data?.requires_permission && data.status === "pending" && !state.observerBootstrapPrompted);
}

async function loadObserverBootstrapStatus({ prompt = false } = {}) {
  const data = await api("/api/observer/bootstrap");
  setObserverBootstrapState(data);
  if (prompt && shouldPromptObserverBootstrap(data)) {
    state.observerBootstrapPrompted = true;
    openObserverAuditDialog(data);
  }
  return data;
}

function openObserverAuditDialog(data = state.observerBootstrap) {
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
  const password = $("observerAuditPassword")?.value || "";
  const data = await api("/api/observer/bootstrap", {
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
  const data = await api("/api/observer/bootstrap", {
    method: "POST",
    body: { action: "skip" },
  });
  if ($("observerAuditPassword")) $("observerAuditPassword").value = "";
  setObserverBootstrapState(data);
  closeObserverAuditDialog();
  showToast(data.logged ? "已记录未启用审计" : "已跳过审计授权");
}

function parseJsonText(id) {
  const raw = $(id).value.trim();
  if (!raw) return {};
  return JSON.parse(raw);
}

function riskKind(risk) {
  if (risk === "low" || risk === "clean" || risk === "ok") return "low";
  if (risk === "medium" || risk === "warn" || risk === "warning") return "medium";
  return "high";
}

function emptyItem(text) {
  const item = document.createElement("article");
  item.className = "item";
  item.innerHTML = `<p>${escapeHtml(text)}</p>`;
  return item;
}

function emptyEvent(text) {
  const event = document.createElement("div");
  event.className = "event";
  event.innerHTML = `<time>--</time><div class="body"><strong>${escapeHtml(text)}</strong><span>等待数据。</span></div>`;
  return event;
}

function updateWorkActionLabel() {
  const button = $("workRunBtn");
  if (!button) return;
  const running = Boolean((state.activeWorkJobId && !state.workSuspended) || state.workApprovalSubmitting);
  button.textContent = state.awaitingWorkApproval ? "等待审批选择" : (running ? "运行中" : (state.workSuspended ? "继续" : (state.workSubmitting ? "发送中" : "发送")));
  button.disabled = state.awaitingWorkApproval || state.workSubmitting || running;
  if ($("workCancelBtn")) $("workCancelBtn").disabled = !state.activeWorkJobId;
  if ($("workSuspendBtn")) $("workSuspendBtn").disabled = !state.activeWorkJobId || state.workSuspended;
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
    turnId: state.activeWorkTurnId || "",
    card,
    step,
    index: Math.max(0, steps.indexOf(step)),
    review: card?.review || null,
  };
  state.approvalDrawerOpen = true;
  state.awaitingWorkApproval = true;

  setText("approvalTitle", card?.title || step.title || step.id || "待审批步骤");
  setStatus("approvalRisk", card?.risk_level || step.risk_level || "approval_required", riskKind(card?.risk_level || step.risk_level || "medium"));
  const body = $("approvalBody");
  if (body) {
    body.innerHTML = `
      <div class="approval-meta">
        ${renderMetaRows([
          ["执行器", step.executor_type || "--"],
          ["Skill", step.skill_script || ""],
          ["命令", step.command || ""],
          ["预期效果", step.expected_effect || ""],
          ["原因", step.reason || ""],
        ])}
      </div>
      ${renderJsonDetails("策略审查 findings", state.pendingApproval.review?.findings || [], false)}
      ${renderJsonDetails("步骤 JSON", step, false)}
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
        ${renderMetaRows([
          ["执行器", "terminal"],
          ["命令", card.command || command],
          ["风险", card.risk_level || policyReview.risk_level || ""],
        ])}
      </div>
      ${renderJsonDetails("策略审查 findings", policyReview.findings || [], true)}
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
      const job = await createJob("terminal", "run", { command, approve: true });
      state.activeTerminalJobId = job.job_id;
      state.terminalSubmitting = false;
      updateTerminalActionState();
      const completed = await pollJob(job.job_id, "terminalJobStatus", "terminalOutput");
      renderSharedProtocolExecution("终端输出", completed.result || completed, "terminalOutput");
    } finally {
      state.activeTerminalJobId = "";
      state.terminalSubmitting = false;
      updateTerminalActionState();
    }
    return;
  }

  const pendingApproval = state.pendingApproval;
  const turnId = pendingApproval.turnId || state.activeWorkTurnId || "";
  const payload = {
    input: pendingApproval.input,
    response: pendingApproval.response,
    context: pendingApproval.context,
    decisions: [decision],
  };
  if (decision === "s") payload.decisions.push($("approvalRevision")?.value || "");
  closeApprovalDrawer();
  state.activeWorkTurnId = turnId;
  if (state.activeWorkJobId || state.workSubmitting) return showToast("Work job is already running.");
  state.workSubmitting = true;
  state.workApprovalSubmitting = true;
  setStatus("workJobStatus", "running", "running");
  updateWorkActionLabel();
  try {
    const job = await createJob("work", "run", payload);
    state.activeWorkJobId = job.job_id;
    state.workSubmitting = false;
    state.workApprovalSubmitting = false;
    state.workSuspended = false;
    updateWorkActionLabel();
    const completed = await pollJob(job.job_id, "workJobStatus", null, { suspendFlag: "workSuspended" });
    handleCompletedWork(completed, payload.input);
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

function renderTimelineReturns(title, result) {
  return upsertSessionTurn(title, result, result?.input || state.workPlanInput || "", {
    turnId: state.activeWorkTurnId || "",
    mode: "work",
  });
}

function renderSharedProtocolExecution(title, result, outputId = "terminalOutput") {
  state.lastProtocolResult = result;
  const text = renderSharedExecutionOutput(title, result);
  if (outputId) printOutput(outputId, text);
  upsertSessionTurn(title, result, result?.input || "", {
    mode: title.includes("终端") ? "terminal" : "work",
    contextEligible: false,
  });
}

function executionItems(result) {
  return (Array.isArray(result?.timeline) ? result.timeline : []).filter((item) => ["execution", "failure", "observer", "audit"].includes(item.kind));
}

function entryStepKey(entry) {
  return String(entry?.step?.id || entry?.output?.step_id || entry?.index || "0");
}

function normalizedTurnEntries(title, result) {
  const response = result?.response || {};
  const steps = Array.isArray(response.steps) ? response.steps : [];
  const protocolEntries = executionItems(result).length ? normalizeExecutionEntries(title, result) : [];
  if (steps.length) {
    const byStepId = new Map(protocolEntries.map((entry) => [entryStepKey(entry), entry]));
    const pendingIndex = result?.status === "approval_required" ? completedExecutionCount(result) : -1;
    return steps.map((step, index) => {
      const key = String(step.id || index);
      const matched = byStepId.get(key) || protocolEntries.find((entry) => entry.index === index);
      if (matched) {
        return {
          ...matched,
          index,
          number: index + 1,
          title: matched.title || step.title || step.id || `step-${index + 1}`,
          step: { ...step, ...(matched.step || {}) },
        };
      }
      const status = index === pendingIndex ? "approval_required" : "planned";
      return {
        index,
        number: index + 1,
        title: step.title || step.id || `step-${index + 1}`,
        status,
        step,
        output: {
          status,
          summary: step.expected_effect || step.reason || (status === "approval_required" ? "等待审批后执行。" : "尚未执行。"),
        },
      };
    });
  }
  if (response.response_type === "answer") {
    return [{
      index: 0,
      number: "A",
      title: "answer_received",
      status: result?.status || "answered",
      step: {},
      output: { status: result?.status || "answered", summary: response.answer || "" },
    }];
  }
  return normalizeExecutionEntries(title, result);
}

function contextTurnCapacity() {
  const raw = Number(state.sessionInfo?.context_turns ?? state.configSnapshot?.context_turns ?? 6);
  if (!Number.isFinite(raw) || raw <= 0) return 0;
  return Math.floor(raw);
}

function turnCanEnterContext(turn) {
  const mode = String(turn?.mode || "work");
  const status = String(turn?.status || "");
  return turn?.contextEligible !== false && mode === "work" && status !== "approval_required";
}

function contextMetaByTurn() {
  const capacity = contextTurnCapacity();
  const eligible = [...state.sessionTurns]
    .sort((a, b) => (a.order || 0) - (b.order || 0))
    .filter(turnCanEnterContext);
  const active = capacity > 0 ? eligible.slice(-capacity) : [];
  const meta = new Map();
  [...active].reverse().forEach((turn, depth) => {
    meta.set(turn.id, { included: true, depth: Math.min(depth, 5), label: depth === 0 ? "上下文 最新" : `上下文 -${depth}` });
  });
  for (const turn of state.sessionTurns) {
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

function createSessionTurn(title, result, input = "", options = {}) {
  const now = new Date().toISOString();
  const status = String(result?.status || options.status || (result?.ok ? "executed" : "completed"));
  const mode = options.mode || result?.mode || "work";
  const order = options.order ?? ++sessionTurnCounter;
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
    result: result || {},
    entries: normalizedTurnEntries(title, result || {}),
    contextEligible: options.contextEligible ?? (mode === "work" && status !== "approval_required"),
  };
}

function normalizeRestoredTurn(turn, index) {
  const result = turn?.result || turn || {};
  const order = index + 1;
  sessionTurnCounter = Math.max(sessionTurnCounter, order);
  return createSessionTurn(`审计恢复 ${turn?.number || order}`, result, turn?.input || result.input || "", {
    id: turn?.id || `restored-${order}`,
    number: turn?.number || order,
    order,
    mode: turn?.mode || "work",
    status: turn?.status || result.status || "restored",
    source: "audit",
    created_at: turn?.created_at || "",
    updated_at: turn?.updated_at || "",
    contextEligible: (turn?.mode || "work") === "work" && (turn?.status || result.status) !== "approval_required",
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
      ? (turn.entries || []).find((entry) => entryStepKey(entry) === state.selectedStepKey)
      : null;
    if (selectedEntry) renderStepDetail(selectedEntry, turn.result, turn);
    else renderTurnDetail(turn);
  } else if (!state.selectedTurnId) {
    renderStepDetail(null);
  }
  return turn;
}

function replaceSessionTurns(turns) {
  sessionTurnCounter = 0;
  state.sessionTurns = (Array.isArray(turns) ? turns : []).map(normalizeRestoredTurn);
  state.selectedTurnId = "";
  state.selectedStepKey = "";
  renderSessionTimeline();
  renderStepDetail(null);
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
  const entry = (turn.entries || []).find((candidate) => entryStepKey(candidate) === stepKey);
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
  item.className = `timeline-card session-turn ${statusKind(displayStatus)}${selected ? " selected" : ""}`;
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
        <span class="pill risk ${statusKind(displayStatus)}">${escapeHtml(displayStatus)}</span>
      </span>
    </button>
    ${selected ? renderTurnStepChips(turn) : ""}
  `;
  item.querySelector(".session-turn-button").addEventListener("click", () => selectSessionTurn(turn.id));
  item.querySelectorAll(".turn-step-chip").forEach((button) => {
    button.addEventListener("click", (event) => {
      event.stopPropagation();
      selectTurnStep(turn.id, button.dataset.stepKey || "");
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
        const key = entryStepKey(entry);
        const selected = state.selectedTurnId === turn.id && state.selectedStepKey === key;
        return `
          <button class="turn-step-chip ${selected ? "selected" : ""}" type="button" data-step-key="${escapeHtml(key)}">
            <span class="mini-step-index">${escapeHtml(entry.number ?? entry.index + 1)}</span>
            <span>${escapeHtml(entry.title || "步骤")}</span>
            <span class="mini-pill risk ${statusKind(entry.status)}">${escapeHtml(entry.status || "step")}</span>
          </button>
        `;
      }).join("")}
    </div>
  `;
}

function workPlanMarkdown(response) {
  if (!response) return "";
  if (response.response_type === "answer") {
    return ["# 回答", "", response.answer || response.summary || ""].join("\n").trim();
  }
  const steps = Array.isArray(response.steps) ? response.steps : [];
  const lines = ["# 工作计划", ""];
  if (response.summary) {
    lines.push(response.summary, "");
  }
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

function renderTurnDetail(turn) {
  const container = $("workDetail");
  if (!container) return;
  if (!turn) {
    renderStepDetail(null);
    return;
  }
  updateSelectedStepStatus({ status: turn.status || "selected" });
  const entries = turn.entries || [];
  const flowHtml = renderExecutionFlowHtml(turn.result);
  const planMarkdown = workPlanMarkdown(turn.result?.response);
  container.className = "step-detail turn-detail";
  container.innerHTML = `
    <div class="detail-title-row">
      <div>
        <h4>${escapeHtml(`第 ${turn.number || "?"} 轮 · ${modeLabel(turn.mode)}`)}</h4>
        <p>${escapeHtml(turn.input || turn.title || "")}</p>
      </div>
      <span class="pill risk ${statusKind(turn.status)}">${escapeHtml(turn.status || "selected")}</span>
    </div>
    <section class="detail-section">
      <h5>轮次摘要</h5>
      <div class="meta-grid">
        ${renderMetaRows([
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
    ${renderJsonDetails("轮次原始数据", { result: turn.result }, false)}
  `;
}

function renderTurnStepOutput(entry) {
  const output = entry.output || {};
  return `
    <article class="turn-step-output">
      <div class="turn-step-output-head">
        <span class="step-index">${escapeHtml(entry.number ?? entry.index + 1)}</span>
        <strong>${escapeHtml(entry.title || "步骤")}</strong>
        <span class="pill risk ${statusKind(entry.status)}">${escapeHtml(entry.status || "step")}</span>
      </div>
      <div class="primary-output">${renderTerminalReturnHtml(output)}</div>
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
  const commandLabel = step.skill_script || step.command || output.command || primaryOutputObject(output).command || "";
  const subtitle = step.reason || step.expected_effect || turn?.input || "";
  container.className = "step-detail";
  container.innerHTML = `
    <div class="detail-title-row">
      <div>
        <h4>${escapeHtml(entry.title || step.title || "步骤详情")}</h4>
        ${subtitle ? `<p>${escapeHtml(subtitle)}</p>` : ""}
      </div>
      <span class="pill risk ${statusKind(entry.status)}">${escapeHtml(entry.status || "selected")}</span>
    </div>
    <section class="detail-section">
      <h5>执行摘要</h5>
      <div class="meta-grid">
        ${renderMetaRows([
          ["轮次", turn?.number ? `第 ${turn.number} 轮` : ""],
          ["状态", entry.status || output.status || ""],
          ["退出码", output.exit_code ?? ""],
          ["自动批准", output.auto_approved === true ? "是" : (output.auto_approved === false ? "否" : "")],
          ["执行器", step.executor_type || ""],
          ["风险", step.risk_level || ""],
          ["命令/Skill", commandLabel],
        ])}
      </div>
    </section>
    <section class="detail-section">
      <h5>步骤事宜</h5>
      <div class="meta-grid">
        ${renderMetaRows([
          ["步骤 ID", step.id || ""],
          ["原因", step.reason || ""],
          ["预期效果", step.expected_effect || ""],
          ["脚本", step.skill_script || ""],
          ["命令", step.command || ""],
          ["参数", step.arguments ? JSON.stringify(step.arguments) : ""],
        ]) || '<p class="muted">本步骤没有计划元数据。</p>'}
      </div>
    </section>
    <section class="detail-section terminal-return-section">
      <h5>终端返回</h5>
      <div class="primary-output">
        ${renderTerminalReturnHtml(output)}
      </div>
    </section>
    <section class="detail-section">
      <h5>执行代理</h5>
      <div class="meta-grid">
        ${renderMetaRows([
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
        ${renderMetaRows([
          ["状态", observer.status || ""],
          ["后端", observer.backend || ""],
          ["生命周期", observer.lifecycle || ""],
          ["范围", observer.scope || ""],
        ]) || '<p class="muted">本步骤没有返回 observer 信息。</p>'}
      </div>
    </section>
    ${renderJsonDetails("策略审查", review || step.review || null)}
    ${renderJsonDetails("原始调试数据", { step, output, result_session: result?.session_id || "" }, false)}
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

async function createJob(resource, action, payload) {
  return api("/api/jobs", {
    method: "POST",
    body: { resource, action, payload },
  });
}

async function cancelJob(jobId) {
  if (!jobId) return { ok: false, status: "missing_job" };
  return api(`/api/jobs/${jobId}/cancel`, { method: "POST", body: {} });
}

async function pollJob(jobId, statusId, outputId, options = {}) {
  setStatus(statusId, "running", "running");
  if (outputId) printOutput(outputId, { status: "running" });
  for (;;) {
    if (options.suspendFlag && state[options.suspendFlag]) {
      setStatus(statusId, "suspended", "medium");
      return { status: "suspended", job_id: jobId };
    }
    const job = await api(`/api/jobs/${jobId}`);
    if (job.status === "queued" || job.status === "running") {
      await new Promise((resolve) => window.setTimeout(resolve, 900));
      continue;
    }
    const resultStatus = job.result?.status || job.status;
    const kind = resultStatus === "approval_required" ? "approval_required" : (job.status === "succeeded" ? "ok" : "failed");
    setStatus(statusId, resultStatus, kind);
    return job;
  }
}

async function connect() {
  state.token = $("tokenInput").value.trim();
  if (!state.token) {
    showToast("Token required");
    return;
  }
  localStorage.setItem("linuxAgentToken", state.token);
  const health = await api("/api/health");
  setLayoutRunId(health.web_server?.run_id || "");
  setStatus("connectionState", "online", "ok");
  setText("rootPath", health.root || "connected");
  await loadConfig();
  await loadSessionState();
  await loadObserverBootstrapStatus({ prompt: true });
  await loadSense();
  await loadTools();
  await loadSkillTree();
  await loadAuditList();
  await loadPolicies();
  showToast("Connected");
}

async function loadConfig() {
  const data = await api("/api/config");
  state.configSnapshot = data.config || {};
  state.configOriginal = collectEditableConfigValues(state.configSnapshot);
  state.configDraft = { ...state.configOriginal };
  renderConfigCenter(state.configSnapshot);
  syncThinkingTraceFromConfig();
  renderThinkingSummary();
  renderSessionTimeline();
  setConfigDirtyState(false);
}

async function loadSessionState() {
  const data = await api("/api/session/state");
  state.sessionInfo = data;
  state.restoredAuditSessionId = data.restored_from || "";
  updateSessionLeaveState();
  renderSessionTimeline();
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
  const result = await api("/api/session/leave", { method: "POST", body: {} });
  if (!result.ok) {
    showToast(result.error || result.status || "离开会话失败");
    return;
  }
  state.sessionInfo = result.session || state.sessionInfo;
  state.restoredAuditSessionId = "";
  state.sessionTurns = [];
  state.selectedTurnId = "";
  state.selectedStepKey = "";
  state.activeWorkTurnId = "";
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

function syncThinkingTraceFromConfig() {
  const enabled = Boolean(state.configSnapshot?.agent_loop?.thinking_trace_enabled);
  setThinkingSwitches(enabled);
}

async function updateThinkingTrace(next) {
  const preservedChanges = pendingConfigChanges(new Set([THINKING_TRACE_KEY]));
  const data = await api("/api/config/update", {
    method: "POST",
    body: { key: THINKING_TRACE_KEY, value: next },
  });
  if (!data.ok) {
    showToast(data.error || data.status || "config update failed");
    return;
  }
  state.configSnapshot = data.config || state.configSnapshot || {};
  state.configOriginal = collectEditableConfigValues(state.configSnapshot);
  state.configDraft = { ...state.configOriginal };
  renderConfigCenter(state.configSnapshot);
  syncThinkingTraceFromConfig();
  restoreConfigDraftChanges(preservedChanges);
  renderThinkingSummary();
  setConfigDirtyState(hasConfigChanges());
  const enabled = Boolean(state.configSnapshot?.agent_loop?.thinking_trace_enabled);
  showToast(`thinking_summary ${enabled ? "已开启" : "已关闭"}`);
}

async function toggleThinkingTraceFromWorkbench() {
  await updateThinkingTrace(!thinkingTraceEnabled());
}

async function toggleThinkingTraceFromConfig(button) {
  await updateThinkingTrace(!button.classList.contains("on"));
}

function collectEditableConfigValues(config) {
  const values = {};
  for (const group of CONFIG_GROUPS) {
    for (const field of group.fields) {
      if (field.writeOnly) {
        values[field.key] = "";
        continue;
      }
      values[field.key] = normalizeConfigFieldValue(field, getNestedValue(config, field.key));
    }
  }
  return values;
}

function normalizeConfigFieldValue(field, value) {
  if (field.type === "boolean") return Boolean(value);
  if (field.type === "number") {
    const next = Number(value);
    return Number.isFinite(next) ? next : 0;
  }
  if (field.writeOnly) return "";
  return String(value ?? "");
}

function renderConfigCenter(config) {
  renderConfigRuntimeSummary(config);
  renderConfigEditor(config);
}

function renderConfigRuntimeSummary(config) {
  const container = $("configRuntimeSummary");
  if (!container) return;
  const web = config.web || {};
  const apiKeySource = config.api_key_source || (config.api_key_configured ? "configured" : "missing");
  const apiKeyHint = [
    `source ${apiKeySource}`,
    config.api_key_configured_in_config ? "config set" : "",
  ].filter(Boolean).join(" · ");
  const rows = [
    ["model", config.model || "--", config.provider || "provider"],
    ["api_key", config.api_key_configured ? "configured" : "missing", apiKeyHint],
    ["audit", config.audit_mode || "--", `limit ${config.audit_text_limit ?? "--"}`],
    ["observer", config.observer?.enabled || "--", config.observer?.privilege || "privilege"],
    ["web", `${web.host || "--"}:${web.port || "--"}`, web.enabled === false ? "disabled" : "enabled"],
    ["token", web.token_configured ? "configured" : "runtime only", "不回显明文"],
  ];
  container.innerHTML = rows.map(([label, value, hint]) => `
    <div class="metric">
      <div class="label">${escapeHtml(label)}</div>
      <div class="value compact-value">${escapeHtml(value)}</div>
      <div class="hint">${escapeHtml(hint)}</div>
    </div>
  `).join("");
}

function renderConfigEditor(config) {
  const root = $("configEditorRoot");
  if (!root) return;
  const sections = CONFIG_GROUPS.map((group) => `
    <div class="config-section">
      <div><h4>${escapeHtml(group.title)}</h4><p class="small">${escapeHtml(group.note)}</p></div>
      <div class="config-field-list">
        ${group.fields.map((field) => renderConfigField(field, getNestedValue(config, field.key))).join("")}
      </div>
    </div>
  `);
  sections.push(`
    <div class="config-section">
      <div><h4>只读与敏感项</h4><p class="small">这些值用于确认后端状态，不允许在浏览器里直接修改。</p></div>
      <div class="config-field-list">
        ${CONFIG_READONLY_FIELDS.map((field) => renderReadonlyConfigField(field, getNestedValue(config, field.key))).join("")}
      </div>
    </div>
  `);
  root.innerHTML = sections.join("");
}

function renderConfigField(field, rawValue) {
  const value = normalizeConfigFieldValue(field, rawValue);
  if (field.type === "boolean") {
    return `
      <div class="toggle-row config-field-row">
        <div>
          <strong class="white">${escapeHtml(field.label)}</strong>
          <div class="small">${escapeHtml(field.comment)}</div>
        </div>
        <button class="switch config-switch${value ? " on" : ""}" id="${escapeHtml(configInputId(field.key))}" type="button" data-config-key="${escapeHtml(field.key)}" aria-pressed="${value ? "true" : "false"}"><span></span></button>
      </div>
    `;
  }
  if (field.type === "select") {
    return `
      <label class="small config-field-label" for="${escapeHtml(configInputId(field.key))}">
        <span>${escapeHtml(field.label)}</span>
        <select class="select" id="${escapeHtml(configInputId(field.key))}" data-config-key="${escapeHtml(field.key)}">
          ${field.options.map((option) => `<option value="${escapeHtml(option)}"${option === value ? " selected" : ""}>${escapeHtml(option)}</option>`).join("")}
        </select>
        <span class="config-comment">${escapeHtml(field.comment)}</span>
      </label>
    `;
  }
  return `
    <label class="small config-field-label" for="${escapeHtml(configInputId(field.key))}">
      <span>${escapeHtml(field.label)}</span>
      <input class="field" id="${escapeHtml(configInputId(field.key))}" data-config-key="${escapeHtml(field.key)}" type="${field.type === "number" ? "number" : field.type === "secret" ? "password" : "text"}" ${field.min !== undefined ? `min="${escapeHtml(field.min)}"` : ""} ${field.writeOnly ? 'autocomplete="new-password"' : ""} ${field.placeholder ? `placeholder="${escapeHtml(field.placeholder)}"` : ""} value="${escapeHtml(value)}">
      <span class="config-comment">${escapeHtml(field.comment)}</span>
    </label>
  `;
}

function renderReadonlyConfigField(field, value) {
  const display = typeof value === "boolean" ? (value ? "true" : "false") : String(value ?? "--");
  return `
    <div class="readonly-config-row">
      <div>
        <strong class="white">${escapeHtml(field.label)}</strong>
        <div class="small">${escapeHtml(field.comment)}</div>
      </div>
      <span class="pill">${escapeHtml(display)}</span>
    </div>
  `;
}

function updateConfigDraftFromControl(control) {
  const key = control.dataset.configKey;
  if (!key) return;
  const field = findConfigField(key);
  if (!field) return;
  if (field.type === "boolean") {
    const next = !control.classList.contains("on");
    control.classList.toggle("on", next);
    control.setAttribute("aria-pressed", next ? "true" : "false");
    state.configDraft[key] = next;
  } else if (field.type === "number") {
    state.configDraft[key] = Number(control.value);
  } else {
    state.configDraft[key] = control.value;
  }
  setConfigDirtyState(hasConfigChanges());
}

function findConfigField(key) {
  for (const group of CONFIG_GROUPS) {
    const field = group.fields.find((candidate) => candidate.key === key);
    if (field) return field;
  }
  return null;
}

function hasConfigChanges() {
  return Object.keys(state.configDraft).some((key) => state.configDraft[key] !== state.configOriginal[key]);
}

function pendingConfigChanges(excludeKeys = new Set()) {
  return Object.entries(state.configDraft).filter(([key, value]) => !excludeKeys.has(key) && value !== state.configOriginal[key]);
}

function restoreConfigDraftChanges(changes) {
  for (const [key, value] of changes) {
    const field = findConfigField(key);
    if (!field) continue;
    state.configDraft[key] = value;
    const control = $(configInputId(key));
    if (!control) continue;
    if (field.type === "boolean") {
      setSwitch(configInputId(key), value);
    } else {
      control.value = value;
    }
  }
}

function setConfigDirtyState(dirty) {
  const button = $("configSaveBtn");
  if (button) button.disabled = !dirty;
  setText("configDirtyState", dirty ? "modified" : "synced");
}

async function saveConfigChanges() {
  const changes = pendingConfigChanges();
  if (!changes.length) {
    showToast("没有配置变更");
    setConfigDirtyState(false);
    return;
  }
  for (const [key, value] of changes) {
    const data = await api("/api/config/update", {
      method: "POST",
      body: { key, value },
    });
    if (!data.ok) {
      showToast(data.error || data.status || `保存 ${key} 失败`);
      return;
    }
  }
  await loadConfig();
  showToast("配置已保存");
}

async function loadSense(topic = $("senseTopicSelect")?.value || "all") {
  setStatus("senseStatus", "loading", "medium");
  const data = await api("/api/sense", { method: "POST", body: { topic } });
  const sense = data.sense || {};
  renderSense(sense);
  setStatus("senseStatus", data.topic || topic, data.ok ? "ok" : "failed");
}

function renderSense(sense) {
  const grouped = sense.topic ? { [sense.topic]: sense } : sense;
  const resource = grouped.resource || {};
  const disk = grouped.disk || {};
  const service = grouped.service || {};
  const load = firstLine(resource.load_summary).match(/load average[s]?:\s*([^,]+)/i)?.[1] || "--";
  const diskLine = String(disk.df_summary || "").split("\n").find((line) => /\s[0-9]+%\s/.test(line)) || "";
  const diskUse = diskLine.match(/\s([0-9]+%)\s/)?.[1] || "--";
  const memoryLine = String(resource.memory_summary || "").split("\n").find((line) => line.toLowerCase().startsWith("mem:")) || "";
  const memory = memoryLine ? memoryLine.trim().replace(/\s+/g, " ") : "--";
  const failedServices = String(service.failed_summary || "").split("\n").filter((line) => /^\s*●/.test(line) || /\bfailed\b/i.test(line)).length;
  setText("metricLoad", load);
  setText("metricDisk", diskUse);
  setText("metricMemory", memory === "--" ? "--" : memory.split(" ").slice(2, 4).join("/"));
  setText("metricServices", String(failedServices));
  printOutput("environmentPayload", sense);
}

async function loadTools() {
  const data = await api("/api/tools");
  state.tools = data.scripts || [];
  const select = $("scriptSelect");
  select.innerHTML = "";
  for (const tool of state.tools) {
    const option = document.createElement("option");
    option.value = tool.ref;
    option.textContent = `${tool.ref} · ${tool.description || ""}`;
    select.appendChild(option);
  }
  renderToolCatalog();
}

async function loadSkillTree() {
  const data = await api("/api/skills/tree");
  if (!data.ok) return;
  state.skillTree = data.tree || [];
  state.skillFiles = { markdown: data.markdown_files || [], scripts: data.script_files || [] };
  renderSkillTree();
  renderMarkdownFileList();
  populateEditFolders();
  if (state.skillFiles.markdown.includes("INDEX.md")) {
    await readSkillFile("INDEX.md", "markdown");
  }
}

async function validateSkills() {
  setText("skillCodeTitle", "skills validate");
  $("skillCodeOutput").textContent = "正在校验 skills...";
  const data = await api("/api/skills/validate");
  $("skillCodeOutput").textContent = pretty(data);
  showToast(data.ok ? "Skill 校验通过" : "Skill 校验发现问题");
}

function renderToolCatalog() {
  const container = $("skillsCatalog");
  if (!container) return;
  container.innerHTML = "";
  if (!state.tools.length) {
    const row = document.createElement("tr");
    row.innerHTML = '<td colspan="5">暂无已登记 skill</td>';
    container.appendChild(row);
    return;
  }
  for (const tool of state.tools) {
    const parts = String(tool.ref || "").split("/");
    const name = parts[parts.length - 1] || tool.ref;
    const group = parts.length > 1 ? parts.slice(0, -1).join(" / ") : "skills";
    const row = document.createElement("tr");
    const scriptPath = `${group.replaceAll(" / ", "/")}/scripts/${name}.sh`;
    row.className = "clickable";
    row.dataset.path = scriptPath;
    row.innerHTML = `
      <td class="mono">${escapeHtml(name)}</td>
      <td>${escapeHtml(group)}</td>
      <td class="mono">${escapeHtml(scriptPath)}</td>
      <td><span class="pill risk low">low</span></td>
      <td>已登记</td>
    `;
    row.addEventListener("click", () => readSkillFile(scriptPath, "script"));
    container.appendChild(row);
  }
}

function renderSkillTree() {
  const container = $("skillTree");
  if (!container) return;
  container.innerHTML = "";
  const root = document.createElement("details");
  root.open = true;
  root.innerHTML = "<summary>skills/</summary>";
  for (const node of state.skillTree || []) {
    root.appendChild(renderTreeNode(node));
  }
  container.appendChild(root);
}

function renderTreeNode(node) {
  if (node.type === "dir") {
    const details = document.createElement("details");
    details.open = true;
    const summary = document.createElement("summary");
    summary.textContent = `${node.name}/`;
    details.appendChild(summary);
    for (const child of node.children || []) {
      details.appendChild(renderTreeNode(child));
    }
    return details;
  }
  const button = document.createElement("button");
  button.type = "button";
  button.textContent = node.name;
  button.addEventListener("click", () => readSkillFile(node.path, node.kind));
  return button;
}

function renderMarkdownFileList() {
  const container = $("skillMarkdownFiles");
  if (!container) return;
  container.innerHTML = "";
  if (!state.skillFiles.markdown.length) {
    container.appendChild(emptyItem("暂无 Markdown 索引文件"));
    return;
  }
  for (const path of state.skillFiles.markdown) {
    const item = document.createElement("article");
    item.className = "item";
    item.innerHTML = `<div class="item-head"><h4 class="mono">${escapeHtml(path)}</h4><span class="pill">md</span></div><p>点击查看 Markdown 渲染和从属关系。</p>`;
    item.addEventListener("click", () => readSkillFile(path, "markdown"));
    container.appendChild(item);
  }
}

function populateEditFolders() {
  const select = $("editFolderSelect");
  if (!select) return;
  const folders = new Set(["skills"]);
  for (const path of [...state.skillFiles.markdown, ...state.skillFiles.scripts]) {
    const parts = path.split("/");
    for (let index = 1; index < parts.length; index += 1) {
      folders.add(`skills/${parts.slice(0, index).join("/")}`);
    }
  }
  select.innerHTML = "";
  for (const folder of [...folders].sort()) {
    const option = document.createElement("option");
    option.value = folder;
    option.textContent = folder;
    select.appendChild(option);
  }
}

async function readSkillFile(path, kind = "") {
  const data = await api("/api/skills/read", { method: "POST", body: { path } });
  if (!data.ok) return showToast(data.error || data.status || "read failed");
  if ((kind || data.kind) === "markdown") {
    $("skillMarkdownPreview").innerHTML = renderMarkdown(data.content || "");
  } else {
    setText("skillCodeTitle", data.path);
    $("skillCodeOutput").textContent = data.content || "";
  }
}

function renderMarkdown(markdown) {
  const lines = String(markdown || "").split("\n");
  const html = [];
  let inCode = false;
  for (const line of lines) {
    if (line.startsWith("```")) {
      html.push(inCode ? "</code></pre>" : "<pre><code>");
      inCode = !inCode;
      continue;
    }
    if (inCode) {
      html.push(`${escapeHtml(line)}\n`);
      continue;
    }
    if (line.startsWith("# ")) html.push(`<h1>${escapeHtml(line.slice(2))}</h1>`);
    else if (line.startsWith("## ")) html.push(`<h2>${escapeHtml(line.slice(3))}</h2>`);
    else if (line.startsWith("### ")) html.push(`<h3>${escapeHtml(line.slice(4))}</h3>`);
    else if (line.startsWith("- ")) html.push(`<p>• ${inlineMarkdown(line.slice(2))}</p>`);
    else if (line.trim()) html.push(`<p>${inlineMarkdown(line)}</p>`);
  }
  if (inCode) html.push("</code></pre>");
  return html.join("");
}

function inlineMarkdown(value) {
  return escapeHtml(value).replace(/`([^`]+)`/g, "<code>$1</code>");
}

async function runWork() {
  if (state.workSubmitting || (state.activeWorkJobId && !state.workSuspended)) {
    showToast("Work job is already running.");
    return;
  }
  if (state.activeWorkJobId && state.workSuspended) {
    state.workSuspended = false;
    updateWorkActionLabel();
    const completed = await pollJob(state.activeWorkJobId, "workJobStatus", null, { suspendFlag: "workSuspended" });
    handleCompletedWork(completed, state.workPlanInput);
    return;
  }
  const input = $("workInput").value.trim();
  if (!input) return showToast("Work input required");
  closeApprovalDrawer();
  const payload = { input };
  state.workSubmitting = true;
  updateWorkActionLabel();
  try {
    const job = await createJob("work", "run", payload);
    state.activeWorkJobId = job.job_id;
    state.workSubmitting = false;
    state.workSuspended = false;
    updateWorkActionLabel();
    const completed = await pollJob(job.job_id, "workJobStatus", null, { suspendFlag: "workSuspended" });
    handleCompletedWork(completed, input);
  } finally {
    state.workSubmitting = false;
    updateWorkActionLabel();
  }
}

function handleCompletedWork(completed, input) {
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
  let turn = null;
  if (hasWorkbenchResult) {
    turn = renderTimelineReturns(result.status || "work_return", result);
  }
  if (result.status !== "approval_required" && hasWorkbenchResult) {
    printOutput("terminalOutput", renderSharedExecutionOutput(result.status || "work_return", result));
  }
  if (result.status === "approval_required") {
    state.activeWorkTurnId = turn?.id || state.activeWorkTurnId || "";
    openApprovalDrawer(result, input);
    showToast("需要审批后继续");
  } else {
    state.activeWorkTurnId = "";
    closeApprovalDrawer();
  }
}

async function cancelWork() {
  if (!state.activeWorkJobId) return;
  const data = await cancelJob(state.activeWorkJobId);
  printOutput("terminalOutput", data);
  state.activeWorkJobId = "";
  state.workSuspended = false;
  state.awaitingWorkApproval = false;
  closeApprovalDrawer();
  updateWorkActionLabel();
  setStatus("workJobStatus", data.status, data.ok ? "high" : "medium");
  renderTimelineReturns("cancelled", data.job || data);
}

function suspendWork() {
  if (!state.activeWorkJobId) return;
  state.workSuspended = true;
  updateWorkActionLabel();
  setStatus("workJobStatus", "suspended", "medium");
  showToast("Work polling suspended; job keeps running on server.");
}

async function reviewScript() {
  const ref = $("scriptSelect").value;
  if (!ref) return showToast("Skill required");
  const args = parseJsonText("scriptArgs");
  setStatus("scriptJobStatus", "review", "review");
  const data = await api("/api/script/review", { method: "POST", body: { ref, arguments: args } });
  setStatus("scriptJobStatus", data.status, data.ok ? "ok" : "failed");
  printOutput("scriptOutput", data);
}

async function runScript() {
  const ref = $("scriptSelect").value;
  if (!ref) return showToast("Skill required");
  const args = parseJsonText("scriptArgs");
  const job = await createJob("script", "run", { ref, arguments: args, approve: true });
  state.activeScriptJobId = job.job_id;
  $("scriptCancelBtn").disabled = false;
  const completed = await pollJob(job.job_id, "scriptJobStatus", "scriptOutput");
  state.activeScriptJobId = "";
  $("scriptCancelBtn").disabled = true;
  printOutput("scriptOutput", completed.result || completed);
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
    const review = await api("/api/terminal/review", { method: "POST", body: { command } });
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
    const job = await createJob("terminal", "run", { command, approve: false });
    state.activeTerminalJobId = job.job_id;
    state.terminalSubmitting = false;
    updateTerminalActionState();
    const completed = await pollJob(job.job_id, "terminalJobStatus", "terminalOutput");
    renderSharedProtocolExecution("终端输出", completed.result || completed, "terminalOutput");
  } finally {
    state.activeTerminalJobId = "";
    state.terminalSubmitting = false;
    updateTerminalActionState();
  }
}

async function cancelScript() {
  if (!state.activeScriptJobId) return;
  const data = await cancelJob(state.activeScriptJobId);
  printOutput("scriptOutput", data);
  state.activeScriptJobId = "";
  $("scriptCancelBtn").disabled = true;
  setStatus("scriptJobStatus", data.status, data.ok ? "high" : "medium");
}

function renderEditPackage(editPackage) {
  state.editPackage = editPackage;
  const container = $("editScripts");
  container.innerHTML = "";
  const scripts = editPackage?.scripts || [];
  const reviewButton = $("editReviewBtn");
  const applyButton = $("editApplyBtn");
  if (!scripts.length) {
    container.appendChild(emptyItem("暂无生成脚本"));
    if (reviewButton) reviewButton.disabled = true;
    if (applyButton) applyButton.disabled = true;
    markEditDirty();
    return;
  }
  for (const script of scripts) {
    const wrapper = document.createElement("article");
    wrapper.className = "item script-editor";
    wrapper.dataset.name = script.name;
    wrapper.dataset.description = script.description || "";
    wrapper.innerHTML = `
      <div class="item-head"><h4>${escapeHtml(script.name)}</h4><span class="pill risk medium">draft</span></div>
      <p>${escapeHtml(script.description || "")}</p>
      <textarea class="textarea mono" spellcheck="false"></textarea>
    `;
    wrapper.querySelector("textarea").value = script.content || "";
    wrapper.querySelector("textarea").addEventListener("input", markEditDirty);
    container.appendChild(wrapper);
  }
  markEditDirty();
  if (reviewButton) reviewButton.disabled = false;
  if (applyButton) applyButton.disabled = false;
}

function gatherEditPackage() {
  if (!state.editPackage) throw new Error("Generate an edit package first");
  const scripts = [];
  document.querySelectorAll("#editScripts .script-editor").forEach((item) => {
    scripts.push({
      name: item.dataset.name,
      description: item.dataset.description,
      content: item.querySelector("textarea").value,
    });
  });
  return { ...state.editPackage, scripts };
}

async function planEdit() {
  const input = $("editInput").value.trim();
  if (!input) return showToast("Edit input required");
  const folder = $("editFolderSelect")?.value || "skills";
  const request = `编辑入口: ${folder}\n需求: ${input}`;
  setStatus("editJobStatus", "planning", "planning");
  const data = await api("/api/edit/plan", { method: "POST", body: { input: request } });
  setStatus("editJobStatus", data.status, data.ok ? "ok" : "failed");
  renderEditPackage(data.edit);
  printOutput("editOutput", data);
}

async function reviewEdit() {
  const edit = gatherEditPackage();
  setStatus("editJobStatus", "review", "review");
  const data = await api("/api/edit/review", { method: "POST", body: { edit } });
  setStatus("editJobStatus", data.status, data.ok ? "ok" : "failed");
  printOutput("editOutput", data);
}

async function applyEdit() {
  const edit = gatherEditPackage();
  const job = await createJob("edit", "apply", { edit, approve: true });
  const completed = await pollJob(job.job_id, "editJobStatus", "editOutput");
  printOutput("editOutput", completed.result || completed);
  if (completed.status === "succeeded") {
    setText("editDirtyState", "clean");
    $("editReviewBtn").disabled = true;
    $("editApplyBtn").disabled = true;
    await loadSkillTree();
    await loadTools();
  }
}

function markEditDirty() {
  setText("editDirtyState", state.editPackage ? "unsaved" : "clean");
}

async function loadAuditList() {
  if (state.auditPaused) {
    showToast("Audit replay is paused");
    return;
  }
  const data = await api("/api/audit/list");
  state.auditSessions = data.sessions || [];
  state.auditEvents = [];
  state.auditWebTimeline = null;
  state.currentAuditSession = "";
  renderAuditSessionList();
  resetAuditSummary();
}

function renderAuditSessionList() {
  const container = $("auditList");
  if (!container) return;
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
          <span class="mini-pill risk ${statusKind(session.status)}">${escapeHtml(session.status || "unknown")}</span>
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
  const data = await api("/api/audit/read", { method: "POST", body: { session_id: sessionId } });
  state.currentAuditSession = sessionId;
  state.auditEvents = Array.isArray(data.events) ? data.events : [];
  state.auditWebTimeline = data.web_timeline || null;
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
  const events = filteredAuditEvents();
  container.innerHTML = "";
  if (!events.length) {
    container.appendChild(emptyEvent(state.currentAuditSession ? "当前筛选下没有事件" : "尚未选择 session"));
    return;
  }
  for (const event of events) {
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
          ${display.status ? `<span class="mini-pill risk ${statusKind(display.status)}">${escapeHtml(display.status)}</span>` : ""}
          ${display.badges.map((badge) => `<span class="mini-pill">${escapeHtml(badge)}</span>`).join("")}
        </div>
        ${display.details.length ? `<div class="event-lines">${display.details.map((line) => `<div class="event-line">${escapeHtml(line)}</div>`).join("")}</div>` : ""}
      </div>
    `;
    container.appendChild(item);
  }
}

function filteredAuditEvents() {
  const category = String($("auditEventFilter")?.value || "");
  const limit = Math.max(1, Math.min(200, Number($("auditLimitInput")?.value || 40)));
  return (state.auditEvents || [])
    .filter((event) => !category || auditProtocol.auditEventMatchesCategory(event, category, pretty))
    .slice(0, limit);
}

function auditSummaryText(event) {
  return auditProtocol.auditEventSummary(event, pretty) || "无摘要字段，完整内容见右侧报告。";
}

function renderAuditReadableReport(data) {
  const events = Array.isArray(data.events) ? data.events : [];
  const restored = data.web_timeline || {};
  const selectedSession = (state.auditSessions || []).find((session) => session.session_id === data.session_id) || {};
  const lines = [
    `Session: ${data.session_id || state.currentAuditSession || "--"}`,
    `来源: ${selectedSession.entrypoint_label || (selectedSession.entrypoint === "web" ? "Web" : "CLI") || "--"}`,
    `模式: ${auditModeLabel(selectedSession.modes || [], selectedSession.mode_label) || "--"}`,
    `状态: ${selectedSession.status || restored.status || data.status || "--"}`,
    `事件数: ${events.length}`,
    `可回放轮次: ${Array.isArray(restored.turns) ? restored.turns.length : 0}`,
    `可回放步骤: ${Array.isArray(restored.timeline) ? restored.timeline.length : 0}`,
    "",
    "事件时间线:",
  ];
  events.slice(0, 80).forEach((event, index) => {
    const display = auditProtocol.auditEventDisplay(event, pretty);
    lines.push(`${index + 1}. ${auditProtocol.compactAuditTime(auditProtocol.auditEventTime(event))} ${display.title} - ${display.summary || "已记录"}`);
    display.details.slice(0, 4).forEach((detail) => lines.push(`   ${detail}`));
  });
  if (events.length > 80) lines.push(`... 还有 ${events.length - 80} 个事件未在预览中展开。`);
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
  for (const event of observerEvents.slice(0, 12)) {
    const payload = event.payload || event.data || event;
    const display = auditProtocol.auditEventDisplay(event, pretty);
    const status = payload.status || payload.lifecycle || auditProtocol.auditEventName(event);
    const row = document.createElement("tr");
    row.innerHTML = `
      <td><span class="pill risk ${statusKind(status)}">${escapeHtml(status)}</span></td>
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
  const restored = state.auditWebTimeline;
  if (!restored?.timeline?.length && !restored?.turns?.length) {
    return showToast("当前审计 session 没有可恢复的工作时间线");
  }
  const sessionId = state.currentAuditSession || restored.session_id || "";
  const backend = await api("/api/session/restore", { method: "POST", body: { session_id: sessionId } });
  if (!backend.ok) {
    showToast(backend.error || backend.status || "恢复会话失败");
    return;
  }
  state.sessionInfo = backend.session || state.sessionInfo;
  state.restoredAuditSessionId = sessionId;
  state.lastProtocolResult = restored;
  state.workPlan = restored.response || null;
  state.workContext = { restored_from_audit: sessionId };
  state.workPlanInput = restored.input || "";
  state.awaitingWorkApproval = false;
  state.activeWorkTurnId = "";
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
  setStatus("workJobStatus", backend.status || restored.status || "restored", statusKind(backend.status || restored.status || "restored"));
  showScreen("workbench");
  showToast("已从审计恢复工作时间线和上下文");
}

async function runDoctor() {
  const data = await api("/api/doctor");
  const summary = $("doctorSummary");
  summary.innerHTML = "";
  const doctor = data.doctor || {};
  const rows = [
    ["overall", doctor.ok ? "ok" : "needs attention", doctor.ok ? "low" : "high"],
    ["config", doctor.config_ok ? "ok" : "failed", doctor.config_ok ? "low" : "high"],
    ["skills", doctor.skills_ok ? "ok" : "failed", doctor.skills_ok ? "low" : "high"],
  ];
  for (const [label, value, kind] of rows) {
    const item = document.createElement("div");
    item.className = "metric";
    item.innerHTML = `<div class="label">${escapeHtml(label)}</div><div class="value">${escapeHtml(value)}</div><div class="hint">${escapeHtml(kind)}</div>`;
    summary.appendChild(item);
  }
  printOutput("doctorOutput", data);
}

function updatePolicyEditState() {
  const unlocked = state.policySudoUnlocked;
  document.querySelectorAll(".policy-edit").forEach((el) => {
    el.disabled = !unlocked;
  });
  if ($("policyEditor")) $("policyEditor").disabled = !unlocked;
  if ($("policySaveBtn")) $("policySaveBtn").disabled = !unlocked || !state.currentPolicyPath;
  if ($("policyBoundaryOptions")) $("policyBoundaryOptions").hidden = !unlocked;
  setStatus("policyLockPill", unlocked ? "可编辑" : "已锁定", unlocked ? "ok" : "medium");
  setText("policyEditMode", unlocked ? "本次会话可编辑" : "只读");
}

async function loadPolicies() {
  const data = await api("/api/policies");
  state.policyFiles = data.files || [];
  const select = $("policyFileSelect");
  select.innerHTML = "";
  for (const file of state.policyFiles) {
    const option = document.createElement("option");
    option.value = file.path;
    option.textContent = `${file.path} · ${file.size_bytes} bytes`;
    select.appendChild(option);
  }
  updatePolicyEditState();
  if (!state.policyFiles.length) {
    $("policyEditor").value = "";
    printOutput("policyOutput", { ok: true, status: "no_policy_files" });
    renderRiskRules(null);
    renderAuditBoundaries(null);
    return;
  }
  const paths = state.policyFiles.map((file) => file.path);
  const preferred = paths.includes(state.currentPolicyPath)
    ? state.currentPolicyPath
    : (paths.includes("audit-boundaries.json") ? "audit-boundaries.json" : paths[0]);
  select.value = preferred;
  await readPolicy(preferred);
  await loadPolicySummaries(preferred);
}

async function loadPolicySummaries(currentPath) {
  const paths = state.policyFiles.map((file) => file.path);
  if (currentPath !== "risk-rules.json" && paths.includes("risk-rules.json")) {
    const data = await readPolicyJson("risk-rules.json");
    if (data?.ok) renderRiskRules(data.json);
  }
  if (currentPath !== "audit-boundaries.json" && paths.includes("audit-boundaries.json")) {
    const data = await readPolicyJson("audit-boundaries.json");
    if (data?.ok) renderAuditBoundaries(data.json);
  }
}

async function readPolicyJson(path) {
  try {
    return await api("/api/policies/read", { method: "POST", body: { path } });
  } catch (error) {
    console.error(error);
    return null;
  }
}

async function readPolicy(path) {
  const data = await api("/api/policies/read", { method: "POST", body: { path } });
  if (!data.ok) {
    printOutput("policyOutput", data);
    return;
  }
  state.currentPolicyPath = data.path;
  $("policyEditor").value = data.content || "";
  printOutput("policyOutput", { ok: true, status: "read", path: data.path });
  if (data.path === "risk-rules.json") renderRiskRules(data.json);
  if (data.path === "audit-boundaries.json") renderAuditBoundaries(data.json);
  updatePolicyEditState();
}

async function unlockPolicy() {
  const password = $("policyPassword").value;
  const data = await api("/api/policies/sudo-check", { method: "POST", body: { password } });
  printOutput("policyOutput", data);
  if (!data.ok) {
    state.policySudoPassword = "";
    state.policySudoUnlocked = false;
    updatePolicyEditState();
    showToast(data.error || data.status || "sudo failed");
    return;
  }
  state.policySudoPassword = password;
  state.policySudoUnlocked = true;
  $("policyPassword").value = "";
  updatePolicyEditState();
  showToast("策略编辑已解锁");
}

async function validatePolicy({ silent = false } = {}) {
  const data = await api("/api/policies/validate", {
    method: "POST",
    body: {
      path: state.currentPolicyPath,
      content: $("policyEditor").value,
    },
  });
  printOutput("policyOutput", data);
  if (!data.ok) {
    if (!silent) showToast(data.error || data.status || "策略校验失败");
    return data;
  }
  if (!silent) showToast("策略校验通过");
  return data;
}

function lockPolicy() {
  state.policySudoPassword = "";
  state.policySudoUnlocked = false;
  updatePolicyEditState();
  showToast("策略编辑已锁定");
}

async function savePolicy() {
  if (!state.policySudoUnlocked) return showToast("sudo unlock required");
  const validation = await validatePolicy({ silent: true });
  if (!validation.ok) {
    showToast(validation.error || validation.status || "策略校验失败，未保存");
    return;
  }
  const data = await api("/api/policies/write", {
    method: "POST",
    body: {
      path: state.currentPolicyPath,
      content: $("policyEditor").value,
      password: state.policySudoPassword,
    },
  });
  printOutput("policyOutput", data);
  if (!data.ok) {
    if (String(data.status || "").startsWith("sudo_")) lockPolicy();
    showToast(data.error || data.status || "保存失败");
    return;
  }
  showToast("策略已保存");
  await readPolicy(state.currentPolicyPath);
  await loadPolicySummaries(state.currentPolicyPath);
}

function startNewSkill() {
  showScreen("skills");
  const editTab = document.querySelector('[data-skill-mode="edit"]');
  if (editTab) editTab.click();
  $("editInput").focus();
}

async function openPolicyFile(path) {
  if ($("policyFileSelect")) $("policyFileSelect").value = path;
  await readPolicy(path);
  $("policyEditor").focus();
}

function appendRuleRow(container, level, pattern, action, reason) {
  const row = document.createElement("tr");
  row.innerHTML = `
    <td><span class="pill risk ${level === "warn" ? "medium" : "high"}">${escapeHtml(level)}</span></td>
    <td class="mono">${escapeHtml(pattern)}</td>
    <td>${escapeHtml(action)}</td>
    <td>${escapeHtml(reason)}</td>
  `;
  container.appendChild(row);
}

function renderRiskRules(json) {
  const container = $("riskRulesSummary");
  if (!container) return;
  container.innerHTML = "";
  if (!json) {
    const row = document.createElement("tr");
    row.innerHTML = '<td colspan="4">未加载 risk-rules.json</td>';
    container.appendChild(row);
    return;
  }
  for (const pattern of json.blocked_patterns || []) {
    appendRuleRow(container, "block", pattern, "禁止执行", "命中阻断规则。");
  }
  for (const pattern of json.warn_patterns || []) {
    appendRuleRow(container, "warn", pattern, "人工审批", "命中警告规则。");
  }
  for (const pattern of json.remote_script_blocked_patterns || []) {
    appendRuleRow(container, "block", pattern, "禁止远程脚本", "远程脚本下载审查边界。");
  }
}

function renderAuditBoundaries(json) {
  state.auditBoundaries = json;
  const list = $("policyBoundaryList");
  const options = $("policyBoundaryOptionsList");
  if (list) list.innerHTML = "";
  if (options) options.innerHTML = "";
  if (!json) {
    setText("activeBoundary", "safe_summary");
    if (list) list.innerHTML = '<div class="kv"><div class="k">audit_backend</div><div class="v">未加载 audit-boundaries.json</div></div>';
    return;
  }

  const running = json.running_detection_boundary || json.observing || {};
  const allowed = json.allowed_to_observe || {};
  const active = json.active_boundary || running.id || running.audit_payload_mode || running.audit_mode || "safe_summary";
  setText("activeBoundary", active);
  if (list) {
    list.className = "policy-boundary-raw";
    const sections = [
      ["observing", running, "当前生效字段"],
      ["allowed_to_observe", allowed, "允许范围上限"],
    ];
    if (Array.isArray(json.available_boundaries) && json.available_boundaries.length) {
      sections.push(["available_boundaries", json.available_boundaries, "可选预设"]);
    }
    list.innerHTML = sections.map(([title, value, note]) => renderBoundaryRawSection(title, value, note)).join("");
  }

  if (options) {
    const boundaryRows = json.available_boundaries || (allowed.audit_payload_modes || []).map((mode) => ({
      id: mode,
      description: mode === "redacted_verbose" ? "redacted verbose payload" : "safe summary payload",
    }));
    for (const boundary of boundaryRows) {
      const item = document.createElement("article");
      item.className = "item";
      item.innerHTML = `
        <div class="item-head"><h4 class="mono">${escapeHtml(boundary.id || boundary.name || "boundary")}</h4><span class="pill risk ${boundary.id === active ? "low" : "medium"}">${boundary.id === active ? "active" : "option"}</span></div>
        <p>${escapeHtml(boundary.description || boundary.name || "")}</p>
      `;
      options.appendChild(item);
    }
  }
}

function renderBoundaryRawSection(title, value, note) {
  return `
    <section class="policy-raw-section">
      <div class="policy-raw-head">
        <strong class="mono">${escapeHtml(title)}</strong>
        <span>${escapeHtml(note)}</span>
      </div>
      <pre class="code">${escapeHtml(pretty(value))}</pre>
    </section>
  `;
}

function showScreen(name) {
  document.querySelectorAll(".screen").forEach((el) => el.classList.toggle("active", el.id === `screen-${name}`));
  document.querySelectorAll(".nav button").forEach((el) => el.classList.toggle("active", el.dataset.screen === name));
  setText("screenTitle", titles[name] || name);
}

function bindNavigation() {
  $("nav").addEventListener("click", (event) => {
    const button = event.target.closest("button[data-screen]");
    if (!button) return;
    showScreen(button.dataset.screen);
  });
}

function bindModeTabs() {
  $("workTabs").addEventListener("click", (event) => {
    const button = event.target.closest("button[data-work-mode]");
    if (!button) return;
    document.querySelectorAll("[data-work-mode]").forEach((el) => {
      el.classList.toggle("active", el === button);
      el.classList.toggle("secondary", el !== button);
    });
    $("workModePanel").hidden = button.dataset.workMode !== "work";
    $("terminalModePanel").hidden = button.dataset.workMode !== "terminal";
  });

  $("skillTabs").addEventListener("click", (event) => {
    const button = event.target.closest("button[data-skill-mode]");
    if (!button) return;
    document.querySelectorAll("[data-skill-mode]").forEach((el) => {
      el.classList.toggle("active", el === button);
      el.classList.toggle("secondary", el !== button);
    });
    $("scriptPanel").hidden = button.dataset.skillMode !== "script";
    $("editPanel").hidden = button.dataset.skillMode !== "edit";
  });
}

function bindSwitches() {
  document.querySelectorAll(".switch").forEach((button) => {
    if (button.id === "thinkingTraceSwitch" || button.id === configInputId(THINKING_TRACE_KEY)) return;
    button.addEventListener("click", () => button.classList.toggle("on"));
  });
}

function on(id, eventName, handler) {
  const el = $(id);
  if (!el) return;
  el.addEventListener(eventName, handler);
}

function bindActions() {
  on("tokenForm", "submit", async (event) => {
    event.preventDefault();
    await safeAction(connect);
  });
  on("shutdownServerBtn", "click", () => safeAction(shutdownServer));
  on("observerAuditBtn", "click", () => safeAction(async () => openObserverAuditDialog(await loadObserverBootstrapStatus())));
  on("observerAuditEnableBtn", "click", () => safeAction(enableObserverAudit));
  on("observerAuditSkipBtn", "click", () => safeAction(skipObserverAudit));
  on("observerAuditDialog", "cancel", (event) => event.preventDefault());
  on("workRunBtn", "click", () => safeAction(runWork));
  on("workCancelBtn", "click", () => safeAction(cancelWork));
  on("workSuspendBtn", "click", suspendWork);
  on("sessionLeaveBtn", "click", () => safeAction(leaveWorkbenchSession));
  on("senseRefreshBtn", "click", () => safeAction(() => loadSense()));
  on("approvalApproveBtn", "click", () => safeAction(() => submitApprovalDecision("y")));
  on("approvalRejectBtn", "click", () => safeAction(() => submitApprovalDecision("n")));
  on("approvalSkipBtn", "click", () => safeAction(() => submitApprovalDecision("s")));
  on("approvalTerminateBtn", "click", () => safeAction(() => submitApprovalDecision("t")));
  on("terminalRunBtn", "click", () => safeAction(runTerminal));
  on("scriptReviewBtn", "click", () => safeAction(reviewScript));
  on("scriptRunBtn", "click", () => safeAction(runScript));
  on("scriptCancelBtn", "click", () => safeAction(cancelScript));
  on("skillsValidateBtn", "click", () => safeAction(validateSkills));
  on("newSkillBtn", "click", startNewSkill);
  on("editPlanBtn", "click", () => safeAction(planEdit));
  on("editReviewBtn", "click", () => safeAction(reviewEdit));
  on("editApplyBtn", "click", () => safeAction(applyEdit));
  on("auditRefreshBtn", "click", () => safeAction(loadAuditList));
  on("auditRestoreTimelineBtn", "click", () => safeAction(restoreAuditTimelineToWorkbench));
  on("auditSessionFilter", "input", renderAuditSessionList);
  on("auditStatusFilter", "change", renderAuditSessionList);
  on("auditEventFilter", "change", () => state.currentAuditSession ? renderAuditEventTimeline() : renderAuditSessionList());
  on("auditLimitInput", "input", () => state.currentAuditSession ? renderAuditEventTimeline() : renderAuditSessionList());
  on("configReloadBtn", "click", () => safeAction(loadConfig));
  on("configSaveBtn", "click", () => safeAction(saveConfigChanges));
  on("configEditorRoot", "input", (event) => updateConfigDraftFromControl(event.target));
  on("configEditorRoot", "change", (event) => updateConfigDraftFromControl(event.target));
  on("configEditorRoot", "click", (event) => {
    const button = event.target.closest(".config-switch");
    if (!button) return;
    if (button.dataset.configKey === THINKING_TRACE_KEY) {
      safeAction(() => toggleThinkingTraceFromConfig(button));
      return;
    }
    updateConfigDraftFromControl(button);
  });
  on("doctorRunBtn", "click", () => safeAction(runDoctor));
  on("policyUnlockBtn", "click", () => safeAction(unlockPolicy));
  on("policyLockBtn", "click", lockPolicy);
  on("policyReloadBtn", "click", () => safeAction(loadPolicies));
  on("policyValidateBtn", "click", () => safeAction(validatePolicy));
  on("policySaveBtn", "click", () => safeAction(savePolicy));
  on("policyFileSelect", "change", (event) => safeAction(() => readPolicy(event.target.value)));
  on("policyAddRuleBtn", "click", () => safeAction(() => openPolicyFile("risk-rules.json")));
  on("policyEditBoundaryBtn", "click", () => safeAction(() => openPolicyFile("audit-boundaries.json")));
  on("thinkingTraceSwitch", "click", () => safeAction(toggleThinkingTraceFromWorkbench));
  on("auditExportBtn", "click", exportAuditReport);
  on("auditPauseBtn", "click", toggleAuditPause);
  on("auditFindFailureBtn", "click", findAuditFailure);
  on("editInput", "input", markEditDirty);
  on("workInput", "keydown", (event) => {
    if (event.key !== "Enter" || event.shiftKey || event.isComposing) return;
    event.preventDefault();
    safeAction(runWork);
  });
  on("terminalCommand", "keydown", (event) => {
    if (event.key !== "Enter" || event.shiftKey || event.isComposing) return;
    event.preventDefault();
    safeAction(runTerminal);
  });

  window.addEventListener("keydown", (event) => {
    if (event.altKey || event.metaKey || event.ctrlKey) return;
    if (["INPUT", "TEXTAREA", "SELECT"].includes(document.activeElement.tagName)) return;
    const map = { "1": "workbench", "2": "skills", "3": "policy", "4": "audit", "5": "config" };
    if (map[event.key]) showScreen(map[event.key]);
  });
}

async function safeAction(fn) {
  try {
    await fn();
  } catch (error) {
    showToast(error.message);
    console.error(error);
  }
}

function init() {
  $("tokenInput").value = state.token;
  updateWorkActionLabel();
  updateTerminalActionState();
  updatePolicyEditState();
  initPanelLayout();
  bindNavigation();
  bindModeTabs();
  bindSwitches();
  bindPanelDrag();
  bindActions();
  if (state.token) safeAction(connect);
}

init();
