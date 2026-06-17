const state = {
  token: localStorage.getItem("linuxAgentToken") || "",
  tools: [],
  workPlan: null,
  workContext: null,
  workPlanInput: "",
  awaitingWorkApproval: false,
  editPackage: null,
  policyFiles: [],
  currentPolicyPath: "",
  policySudoPassword: "",
  policySudoUnlocked: false,
  auditBoundaries: null,
  skillTree: null,
  skillFiles: { markdown: [], scripts: [] },
  activeWorkJobId: "",
  activeScriptJobId: "",
  workSuspended: false,
  auditPaused: false,
  draggedPanelId: "",
  webRunId: "",
  layoutStorageKey: "",
  defaultLayout: { containers: {}, children: {} },
};

const $ = (id) => document.getElementById(id);
const LAYOUT_STORAGE_PREFIX = "assistant.panelLayout.v1";

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
  stdout_preview: "标准输出",
  stderr: "错误输出",
  stderr_preview: "错误输出",
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
};

const hiddenOutputKeys = new Set([
  "ok",
  "tool",
  "agent_exit_code",
  "job_id",
  "response_type",
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
  setSwitch("thinkingTraceSwitchConfig", enabled);
}

function firstLine(value) {
  return String(value || "").split("\n").find((line) => line.trim()) || "--";
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
  if (el) el.textContent = renderUserOutputText(value);
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
  if (typeof value.output?.raw === "string") return value.output.raw;
  if (typeof value.raw === "string" && Object.keys(value).every((key) => key === "raw" || hiddenOutputKeys.has(key))) {
    return value.raw;
  }
  for (const key of ["result", "output"]) {
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

function executionEntries(title, result) {
  const execution = result?.execution || result?.result || result || {};
  const results = Array.isArray(execution.results) ? execution.results : [];
  if (results.length) {
    return results.map((entry, index) => {
      const output = entry.result || entry.output || entry;
      return {
        index: index + 1,
        title: entry.title || entry.step_title || entry.status || output.status || "步骤输出",
        status: entry.status || output.status || "完成",
        output,
      };
    });
  }
  return [{
    index: 1,
    title,
    status: execution.status || result?.status || "完成",
    output: execution,
  }];
}

function renderExecutionText(title, result) {
  return executionEntries(title, result)
    .map((entry) => {
      const body = renderUserOutputText(entry.output);
      const header = `${entry.index}. ${entry.title}${entry.status ? ` (${entry.status})` : ""}`;
      return body.trim() ? `${header}\n${body}` : header;
    })
    .join("\n\n");
}

function authHeaders() {
  return {
    "Authorization": `Bearer ${state.token}`,
    "Content-Type": "application/json",
  };
}

async function api(path, options = {}) {
  const init = {
    method: options.method || "GET",
    headers: authHeaders(),
  };
  if (options.body !== undefined) init.body = JSON.stringify(options.body);
  const response = await fetch(path, init);
  const data = await response.json().catch(() => ({ ok: false, status: "invalid_json" }));
  if (!response.ok) {
    throw new Error(data.error || data.status || `HTTP ${response.status}`);
  }
  return data;
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

function stepDefaultDecision(step) {
  if (step.executor_type === "skill_script" && step.risk_level === "low") return "y";
  return "n";
}

function updateWorkActionLabel() {
  const button = $("workRunBtn");
  if (!button) return;
  button.textContent = state.awaitingWorkApproval ? "提交审批选择" : (state.workSuspended ? "继续" : "发送");
  if ($("workCancelBtn")) $("workCancelBtn").disabled = !state.activeWorkJobId;
  if ($("workSuspendBtn")) $("workSuspendBtn").disabled = !state.activeWorkJobId || state.workSuspended;
}

function renderWorkPlan(response, input = "", context = null, awaitingApproval = false) {
  state.workPlan = response;
  state.workContext = context;
  state.workPlanInput = input;
  state.awaitingWorkApproval = awaitingApproval;
  updateWorkActionLabel();

  const container = $("workPlan");
  container.innerHTML = "";
  if (!response) return;

  if (response.response_type === "answer") {
    const item = document.createElement("article");
    item.className = "item step-card";
    item.innerHTML = `
      <div class="step-index">A</div>
      <div>
        <div class="item-head"><h4>answer_received</h4><span class="pill risk low">answer</span></div>
        <p></p>
      </div>
    `;
    item.querySelector("p").textContent = response.answer || "";
    container.appendChild(item);
    return;
  }

  const steps = response.steps || [];
  if (!steps.length) {
    container.appendChild(emptyItem("暂无步骤"));
    return;
  }

  steps.forEach((step, index) => {
    const item = document.createElement("article");
    item.className = "item step-card";
    const decision = stepDefaultDecision(step);
    const decisionHtml = awaitingApproval ? `
        <div class="decision-row">
          <select class="select decision-select">
            <option value="y">approve</option>
            <option value="n">reject</option>
            <option value="s">skip</option>
            <option value="t">terminate</option>
          </select>
          <input class="field revision-input" placeholder="skip revision request">
        </div>
    ` : "";
    item.innerHTML = `
      <div class="step-index">${index + 1}</div>
      <div>
        <div class="item-head">
          <h4>${escapeHtml(step.title || step.id || "step")}</h4>
          <span class="pill risk ${riskKind(step.risk_level)}">${escapeHtml(step.risk_level || "unknown")}</span>
        </div>
        <p></p>
        ${decisionHtml}
      </div>
    `;
    item.querySelector("p").textContent = [
      step.executor_type,
      step.skill_script,
      step.command,
      step.expected_effect,
    ].filter(Boolean).join("\n");
    if (awaitingApproval) item.querySelector(".decision-select").value = decision;
    container.appendChild(item);
  });
}

function renderTerminalReturns(title, result) {
  const container = $("workPlan");
  container.innerHTML = "";
  for (const entry of executionEntries(title, result)) {
    appendReturnCard(container, entry.index, entry.title, entry.output, entry.status);
  }
}

function appendReturnCard(container, index, title, output, status = "") {
  const displayStatus = status || output?.status || (output?.ok ? "ok" : title);
  const item = document.createElement("article");
  item.className = "item step-card";
  item.innerHTML = `
    <div class="step-index">${index}</div>
    <div>
      <div class="item-head"><h4>${escapeHtml(title)}</h4><span class="pill risk ${pillKind(displayStatus)}">${escapeHtml(displayStatus)}</span></div>
      <pre class="output-text"></pre>
    </div>
  `;
  item.querySelector("pre").textContent = renderUserOutputText(output) || "无输出";
  container.appendChild(item);
}

function collectWorkDecisions() {
  const lines = [];
  document.querySelectorAll("#workPlan .item").forEach((item) => {
    const select = item.querySelector(".decision-select");
    if (!select) return;
    lines.push(select.value);
    if (select.value === "s") {
      lines.push(item.querySelector(".revision-input").value || "");
    }
  });
  return lines;
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
  await loadSense();
  await loadTools();
  await loadSkillTree();
  await loadAuditList();
  await loadPolicies();
  showToast("Connected");
}

async function loadConfig() {
  const data = await api("/api/config");
  const enabled = Boolean(data.config?.agent_loop?.thinking_trace_enabled);
  setThinkingSwitches(enabled);
}

async function updateThinkingTrace() {
  const next = !$("thinkingTraceSwitch").classList.contains("on");
  const data = await api("/api/config/update", {
    method: "POST",
    body: { key: "agent_loop.thinking_trace_enabled", value: next },
  });
  if (!data.ok) {
    showToast(data.error || data.status || "config update failed");
    return;
  }
  setThinkingSwitches(Boolean(data.config?.agent_loop?.thinking_trace_enabled));
  printOutput("workOutput", {
    config_updated: "agent_loop.thinking_trace_enabled",
    value: data.config?.agent_loop?.thinking_trace_enabled,
  });
}

async function loadSense() {
  const data = await api("/api/sense", { method: "POST", body: { topic: "all" } });
  const sense = data.sense || {};
  renderSense(sense);
}

function renderSense(sense) {
  const load = firstLine(sense.resource?.load_summary).match(/load average[s]?:\s*([^,]+)/i)?.[1] || "--";
  const diskLine = String(sense.disk?.df_summary || "").split("\n").find((line) => /\s[0-9]+%\s/.test(line)) || "";
  const diskUse = diskLine.match(/\s([0-9]+%)\s/)?.[1] || "--";
  const memoryLine = String(sense.resource?.memory_summary || "").split("\n").find((line) => line.toLowerCase().startsWith("mem:")) || "";
  const memory = memoryLine ? memoryLine.trim().replace(/\s+/g, " ") : "--";
  const failedServices = String(sense.service?.failed_summary || "").split("\n").filter((line) => /^\s*●/.test(line) || /\bfailed\b/i.test(line)).length;
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
  if (state.activeWorkJobId && !state.workSuspended) {
    showToast("Work job is already running.");
    return;
  }
  if (state.activeWorkJobId && state.workSuspended) {
    state.workSuspended = false;
    updateWorkActionLabel();
    const completed = await pollJob(state.activeWorkJobId, "workJobStatus", "workOutput", { suspendFlag: "workSuspended" });
    handleCompletedWork(completed, state.workPlanInput);
    return;
  }
  const input = $("workInput").value.trim();
  if (!input) return showToast("Work input required");
  const payload = { input };
  if (state.awaitingWorkApproval && state.workPlanInput === input && state.workPlan?.response_type === "work_plan") {
    payload.response = state.workPlan;
    payload.context = state.workContext || {};
    payload.decisions = collectWorkDecisions();
  }
  const job = await createJob("work", "run", payload);
  state.activeWorkJobId = job.job_id;
  state.workSuspended = false;
  updateWorkActionLabel();
  const completed = await pollJob(job.job_id, "workJobStatus", "workOutput", { suspendFlag: "workSuspended" });
  handleCompletedWork(completed, input);
}

function handleCompletedWork(completed, input) {
  if (completed.status === "suspended") return;
  state.activeWorkJobId = "";
  updateWorkActionLabel();
  const result = completed.result || {};
  if (result.response) {
    renderWorkPlan(result.response, input, result.context || null, result.status === "approval_required");
  } else if (result.status !== "approval_required") {
    state.awaitingWorkApproval = false;
    updateWorkActionLabel();
  }
  if (result.execution || result.result || result.status === "executed" || result.status === "failed" || result.status === "cancelled") {
    renderTerminalReturns(result.status || "work_return", result);
  }
  if (result.response?.thinking_summary) {
    printOutput("workOutput", { thinking_summary: result.response.thinking_summary });
  }
  if (result.status === "approval_required") showToast("Approval required");
}

async function cancelWork() {
  if (!state.activeWorkJobId) return;
  const data = await cancelJob(state.activeWorkJobId);
  printOutput("workOutput", data);
  state.activeWorkJobId = "";
  state.workSuspended = false;
  state.awaitingWorkApproval = false;
  updateWorkActionLabel();
  setStatus("workJobStatus", data.status, data.ok ? "high" : "medium");
  renderTerminalReturns("cancelled", data.job || data);
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
  printOutput("scriptOutput", renderExecutionText("Skill 输出", completed.result || completed));
}

async function runTerminal() {
  const command = $("terminalCommand").value.trim();
  if (!command) return showToast("Command required");
  const job = await createJob("terminal", "run", { command });
  const completed = await pollJob(job.job_id, "terminalJobStatus", "terminalOutput");
  printOutput("terminalOutput", renderExecutionText("终端输出", completed.result || completed));
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
  if (!scripts.length) {
    container.appendChild(emptyItem("暂无生成脚本"));
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
  $("editApplyBtn").disabled = false;
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
  const container = $("auditList");
  container.innerHTML = "";
  const sessions = data.sessions || [];
  if (!sessions.length) {
    container.appendChild(emptyEvent("暂无审计会话"));
    return;
  }
  for (const session of sessions) {
    const item = document.createElement("button");
    item.type = "button";
    item.className = "event";
    item.innerHTML = `
      <time>${escapeHtml(session.started_at || "--")}</time>
      <div class="body">
        <strong>${escapeHtml(session.session_id)}</strong>
        <span>status=${escapeHtml(session.status || "unknown")}</span>
      </div>
    `;
    item.addEventListener("click", () => readAudit(session.session_id));
    container.appendChild(item);
  }
}

async function readAudit(sessionId) {
  const data = await api("/api/audit/read", { method: "POST", body: { session_id: sessionId } });
  $("auditOutput").textContent = data.report || pretty(data);
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
  setStatus("policyLockPill", unlocked ? "editable" : "locked", unlocked ? "ok" : "medium");
  setText("policyEditMode", unlocked ? "editable for current session" : "read-only");
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
  showToast("Policy editing unlocked");
}

function lockPolicy() {
  state.policySudoPassword = "";
  state.policySudoUnlocked = false;
  updatePolicyEditState();
  showToast("Policy editing locked");
}

async function savePolicy() {
  if (!state.policySudoUnlocked) return showToast("sudo unlock required");
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
    showToast(data.error || data.status || "save failed");
    return;
  }
  showToast("Policy saved");
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
  const observer = $("auditBoundarySummary");
  if (list) list.innerHTML = "";
  if (options) options.innerHTML = "";
  if (observer) observer.innerHTML = "";
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
    const rows = [
      ["audit_backend", running.observer_backend || "auto"],
      ["audit_mode", running.audit_mode || running.audit_payload_mode || "safe_summary"],
      ["session_source", "logs/session/*.jsonl"],
      ["application_events", (running.event_sources || running.application_events || []).join(", ")],
      ["observer_syscalls", (running.observer_syscalls || []).join(", ")],
      ["observer_result_fields", (running.observer_result_fields || []).join(", ")],
      ["observer_max_events", String(running.observer_max_events || "")],
    ];
    for (const [key, value] of rows) {
      const item = document.createElement("div");
      item.className = "kv";
      item.innerHTML = `<div class="k">${escapeHtml(key)}</div><div class="v">${escapeHtml(value)}</div>`;
      list.appendChild(item);
    }
  }

  if (options) {
    const boundaryRows = json.available_boundaries || (allowed.audit_payload_modes || []).map((mode) => ({
      id: mode,
      description: `audit_payload_mode=${mode}`,
    }));
    for (const boundary of boundaryRows) {
      const item = document.createElement("article");
      item.className = "item";
      item.innerHTML = `
        <div class="item-head"><h4 class="mono">${escapeHtml(boundary.id)}</h4><span class="pill risk ${boundary.id === active ? "low" : "medium"}">${boundary.id === active ? "active" : "option"}</span></div>
        <p>${escapeHtml(boundary.description || boundary.name || "")}</p>
      `;
      options.appendChild(item);
    }
  }
  if (observer) {
    for (const eventName of running.application_events || running.event_sources || []) {
      const row = document.createElement("tr");
      row.innerHTML = `
        <td><span class="pill risk low">recording</span></td>
        <td class="mono">${escapeHtml(eventName)}</td>
        <td>observer 正在记录的应用事件。</td>
      `;
      observer.appendChild(row);
    }
  }
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
    if (button.id === "thinkingTraceSwitch" || button.id === "thinkingTraceSwitchConfig") return;
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
  on("workRunBtn", "click", () => safeAction(runWork));
  on("workCancelBtn", "click", () => safeAction(cancelWork));
  on("workSuspendBtn", "click", suspendWork);
  on("terminalRunBtn", "click", () => safeAction(runTerminal));
  on("scriptReviewBtn", "click", () => safeAction(reviewScript));
  on("scriptRunBtn", "click", () => safeAction(runScript));
  on("scriptCancelBtn", "click", () => safeAction(cancelScript));
  on("newSkillBtn", "click", startNewSkill);
  on("editPlanBtn", "click", () => safeAction(planEdit));
  on("editReviewBtn", "click", () => safeAction(reviewEdit));
  on("editApplyBtn", "click", () => safeAction(applyEdit));
  on("auditRefreshBtn", "click", () => safeAction(loadAuditList));
  on("doctorRunBtn", "click", () => safeAction(runDoctor));
  on("policyUnlockBtn", "click", () => safeAction(unlockPolicy));
  on("policyLockBtn", "click", lockPolicy);
  on("policyReloadBtn", "click", () => safeAction(loadPolicies));
  on("policySaveBtn", "click", () => safeAction(savePolicy));
  on("policyFileSelect", "change", (event) => safeAction(() => readPolicy(event.target.value)));
  on("policyAddRuleBtn", "click", () => safeAction(() => openPolicyFile("risk-rules.json")));
  on("policyEditBoundaryBtn", "click", () => safeAction(() => openPolicyFile("audit-boundaries.json")));
  on("thinkingTraceSwitch", "click", () => safeAction(updateThinkingTrace));
  on("thinkingTraceSwitchConfig", "click", () => safeAction(updateThinkingTrace));
  on("auditExportBtn", "click", exportAuditReport);
  on("auditPauseBtn", "click", toggleAuditPause);
  on("auditFindFailureBtn", "click", findAuditFailure);
  on("editInput", "input", markEditDirty);
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
