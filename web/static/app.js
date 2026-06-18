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
  selectedStepIndex: -1,
  approvalDrawerOpen: false,
  pendingApproval: null,
  lastExecution: null,
  lastThinkingSummary: "",
  workSuspended: false,
  auditSessions: [],
  auditEvents: [],
  currentAuditSession: "",
  configSnapshot: null,
  configOriginal: {},
  configDraft: {},
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
  execution_proxy: "执行代理",
  auto_approved: "自动批准",
  risk_level: "风险",
  executor_type: "执行器",
  skill_script: "Skill",
};

const hiddenOutputKeys = new Set([
  "ok",
  "tool",
  "agent_exit_code",
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

const CONFIG_GROUPS = [
  {
    title: "模型与 API",
    note: "控制 LLM 供应商、接口、模型和请求超时。api_key 只显示是否配置，不在前端回显。",
    fields: [
      { key: "provider", label: "provider", type: "text", comment: "供应商名称，用于提示当前适配的 OpenAI-compatible 后端。" },
      { key: "api_url", label: "api_url", type: "text", comment: "模型接口地址，通常是 chat/completions 兼容端点。" },
      { key: "model", label: "model", type: "text", comment: "work/edit 等请求调用的模型名。" },
      { key: "request_timeout_sec", label: "request_timeout_sec", type: "number", min: 1, comment: "单次模型请求最长等待秒数。" },
      { key: "context_turns", label: "context_turns", type: "number", min: 1, comment: "保留的上下文轮数，过大可能增加 token 消耗。" },
    ],
  },
  {
    title: "工作流",
    note: "控制自然语言 work、低风险自动执行和模型思考摘要。",
    fields: [
      { key: "agent_loop.enabled_for_work", label: "work_agent_loop", type: "boolean", comment: "执行后带 observation 继续反思，适合多步排障。" },
      { key: "agent_loop.auto_execute_low_risk", label: "auto_execute_low_risk_skill", type: "boolean", comment: "低风险且策略干净的 skill 步骤可自动执行。" },
      { key: "agent_loop.auto_execute_shell_low_risk", label: "auto_execute_low_risk_shell", type: "boolean", comment: "shell 命令即使低风险也建议保持谨慎。" },
      { key: "agent_loop.observation_text_limit", label: "observation_text_limit", type: "number", min: 200, comment: "回传给模型的命令输出摘要上限。" },
      { key: "agent_loop.checkpoint_turns", label: "checkpoint_turns", type: "number", min: 0, comment: "每隔多少轮强制 checkpoint；0 表示使用 context_turns。" },
      { key: "agent_loop.thinking_trace_enabled", label: "thinking_summary", type: "boolean", comment: "开启后会话摘要栏展示模型返回的简短 thinking_summary。" },
    ],
  },
  {
    title: "审计与 Observer",
    note: "控制审计脱敏、observer 后端和事件数量。",
    fields: [
      { key: "audit_mode", label: "audit_mode", type: "select", options: ["safe_summary", "redacted_verbose"], comment: "safe_summary 更克制；redacted_verbose 保留更多脱敏上下文。" },
      { key: "audit_text_limit", label: "audit_text_limit", type: "number", min: 40, comment: "写入审计报告的文本截断长度。" },
      { key: "observer.enabled", label: "observer_backend", type: "select", options: ["auto", "auditd", "disabled"], comment: "auto 会优先尝试 auditd，失败时降级记录诊断。" },
      { key: "observer.privilege", label: "observer_privilege", type: "text", comment: "observer 提权策略，例如 sudo_interactive。" },
      { key: "observer.max_events", label: "observer_max_events", type: "number", min: 0, comment: "单会话 observer 事件上限，避免报告过大。" },
    ],
  },
  {
    title: "执行策略与 Skill",
    note: "控制最小权限代理、远程脚本策略和 skill 根目录。",
    fields: [
      { key: "execution.min_privilege_proxy", label: "min_privilege_proxy", type: "boolean", comment: "尽量使用低权限用户执行命令，降低误操作影响面。" },
      { key: "execution.least_privilege_user", label: "least_privilege_user", type: "text", comment: "低权限代理使用的系统用户。" },
      { key: "remote_script_policy", label: "remote_script_policy", type: "select", options: ["download_review", "disabled"], comment: "远程脚本默认先下载审查；disabled 直接禁用。" },
      { key: "skills_dir", label: "skills_dir", type: "text", comment: "自定义 skill 根目录；空值表示使用项目默认 skills。" },
    ],
  },
];

const CONFIG_READONLY_FIELDS = [
  { key: "api_key_configured", label: "api_key", comment: "只显示是否已配置，避免在浏览器中暴露密钥。" },
  { key: "web.enabled", label: "web.enabled", comment: "web 服务开关，当前进程已启动时仅作状态展示。" },
  { key: "web.host", label: "web.host", comment: "当前配置文件中的监听地址，改动需重启生效。" },
  { key: "web.port", label: "web.port", comment: "当前配置文件中的监听端口，改动需重启生效。" },
  { key: "web.token_configured", label: "web.token", comment: "只显示 token 是否已配置，不回显 token 明文。" },
  { key: "web.job_retention_hours", label: "web.job_retention_hours", comment: "后端保留 job 文件的小时数，当前进程可能需重启才完全生效。" },
];

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
  setSwitch(configInputId("agent_loop.thinking_trace_enabled"), enabled);
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

function executionRoot(result) {
  return result?.execution || result?.result || result || {};
}

function normalizeExecutionEntries(title, result) {
  const root = executionRoot(result);
  const results = Array.isArray(root.results) ? root.results : [];
  if (results.length) {
    return results.map((entry, index) => {
      const step = entry.step || {};
      const output = entry.result || entry.output || entry;
      return {
        index,
        number: index + 1,
        title: step.title || entry.title || entry.step_title || output.status || "步骤输出",
        status: output.status || entry.status || (output.ok ? "executed" : "failed"),
        step,
        output,
      };
    });
  }
  return [{
    index: 0,
    number: 1,
    title,
    status: root.status || result?.status || (root.ok ? "executed" : "完成"),
    step: {},
    output: root,
  }];
}

function completedExecutionCount(result) {
  const root = executionRoot(result);
  return Array.isArray(root.results) ? root.results.length : 0;
}

function primaryOutputObject(output) {
  if (isPlainObject(output?.output)) return output.output;
  if (isPlainObject(output?.result?.output)) return output.result.output;
  return isPlainObject(output) ? output : {};
}

function outputSummaryText(output) {
  const payload = primaryOutputObject(output);
  for (const key of ["summary", "message", "action", "error", "stdout_preview", "stderr_preview", "raw"]) {
    if (typeof payload[key] === "string" && payload[key].trim()) return compactText(payload[key], 260);
    if (typeof output?.[key] === "string" && output[key].trim()) return compactText(output[key], 260);
  }
  const raw = extractRawOutput(output);
  if (raw) return compactText(raw, 260);
  const text = renderUserOutputText(payload);
  return compactText(text, 260) || "无摘要输出";
}

function tableFromText(text) {
  const lines = String(text || "").split("\n").filter((line) => line.trim());
  if (lines.length < 2) return "";
  const rows = lines.slice(0, 12).map((line) => line.trim().split(/\s{2,}|\t/).filter(Boolean));
  const width = Math.max(...rows.map((row) => row.length));
  if (width < 2) return "";
  const body = rows.map((row, index) => {
    const cells = [...row, ...Array(Math.max(0, width - row.length)).fill("")];
    const tag = index === 0 ? "th" : "td";
    return `<tr>${cells.map((cell) => `<${tag}>${escapeHtml(cell)}</${tag}>`).join("")}</tr>`;
  }).join("");
  return `<div class="data-table-wrap"><table class="data-table">${body}</table></div>`;
}

function renderOutputSection(key, value) {
  const label = outputLabel(key);
  const text = renderUserOutputText(value);
  const table = tableFromText(text);
  return `
    <section class="output-section">
      <h5>${escapeHtml(label)}</h5>
      ${table || `<pre class="inline-code">${escapeHtml(text)}</pre>`}
    </section>
  `;
}

function renderPrimaryOutputHtml(output) {
  const payload = primaryOutputObject(output);
  const chunks = [];
  const renderedKeys = new Set();
  const preferred = [
    "summary", "message", "error", "command", "stdout", "stderr", "load", "memory", "disk_usage", "df_summary",
    "top_dirs", "top_files", "top_processes", "processes", "journal", "journal_sample", "matches",
    "stdout_preview", "stderr_preview", "raw",
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
  const payload = primaryOutputObject(output);
  const merged = {};
  for (const key of ["command", "stdout", "stderr", "stdout_preview", "stderr_preview", "raw", "summary", "message", "error"]) {
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

function updateWorkActionLabel() {
  const button = $("workRunBtn");
  if (!button) return;
  button.textContent = state.awaitingWorkApproval ? "等待审批选择" : (state.workSuspended ? "继续" : "发送");
  button.disabled = state.awaitingWorkApproval;
  if ($("workCancelBtn")) $("workCancelBtn").disabled = !state.activeWorkJobId;
  if ($("workSuspendBtn")) $("workSuspendBtn").disabled = !state.activeWorkJobId || state.workSuspended;
}

function closeApprovalDrawer() {
  state.approvalDrawerOpen = false;
  state.pendingApproval = null;
  state.awaitingWorkApproval = false;
  document.body.classList.remove("terminal-approval");
  const drawer = $("approvalDrawer");
  if (drawer) drawer.hidden = true;
  updateWorkActionLabel();
}

function openApprovalDrawer(result, input) {
  const response = result.response || state.workPlan || {};
  const execution = result.execution || {};
  const completedCount = Array.isArray(execution.results) ? execution.results.length : 0;
  const steps = response.steps || [];
  const step = steps[completedCount] || steps.find((candidate) => candidate.risk_level !== "low") || steps[0] || {};
  state.pendingApproval = {
    type: "work",
    input,
    response,
    context: result.context || state.workContext || {},
    step,
    index: Math.max(0, steps.indexOf(step)),
    review: execution.review || result.review || null,
  };
  state.approvalDrawerOpen = true;
  state.awaitingWorkApproval = true;

  setText("approvalTitle", step.title || step.id || "待审批步骤");
  setStatus("approvalRisk", step.risk_level || "approval_required", riskKind(step.risk_level || "medium"));
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
  state.pendingApproval = { type: "terminal", command, review };
  state.approvalDrawerOpen = true;
  setText("approvalTitle", "终端命令需要审批");
  setStatus("approvalRisk", review.risk_level || "approval_required", riskKind(review.risk_level || "medium"));
  const body = $("approvalBody");
  if (body) {
    body.innerHTML = `
      <div class="approval-meta">
        ${renderMetaRows([
          ["执行器", "terminal"],
          ["命令", command],
          ["风险", review.risk_level || ""],
        ])}
      </div>
      ${renderJsonDetails("策略审查 findings", review.findings || [], true)}
    `;
  }
  const revision = $("approvalRevision");
  if (revision) revision.value = "";
  document.body.classList.add("terminal-approval");
  const drawer = $("approvalDrawer");
  if (drawer) drawer.hidden = false;
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
    const job = await createJob("terminal", "run", { command, approve: true });
    const completed = await pollJob(job.job_id, "terminalJobStatus", "terminalOutput");
    renderSharedExecution("终端输出", completed.result || completed, "terminalOutput");
    return;
  }

  const payload = {
    input: state.pendingApproval.input,
    response: state.pendingApproval.response,
    context: state.pendingApproval.context,
    decisions: [decision],
  };
  if (decision === "s") payload.decisions.push($("approvalRevision")?.value || "");
  closeApprovalDrawer();
  const job = await createJob("work", "run", payload);
  state.activeWorkJobId = job.job_id;
  state.workSuspended = false;
  updateWorkActionLabel();
  const completed = await pollJob(job.job_id, "workJobStatus", null, { suspendFlag: "workSuspended" });
  handleCompletedWork(completed, payload.input);
}

function renderPlanStep(step, index, awaitingApproval = false, pendingIndex = -1) {
  const item = document.createElement("article");
  const isPending = awaitingApproval && index === pendingIndex;
  item.className = `timeline-card plan-step${isPending ? " needs-decision" : ""}`;
  item.innerHTML = `
    <button class="timeline-step-button" type="button">
      <span class="step-index">${index + 1}</span>
      <span class="timeline-main">
        <span class="timeline-title">${escapeHtml(step.title || step.id || "step")}</span>
        <span class="timeline-copy">${escapeHtml([step.executor_type, step.skill_script || step.command, step.expected_effect].filter(Boolean).join(" · "))}</span>
      </span>
      <span class="pill risk ${riskKind(step.risk_level)}">${escapeHtml(isPending ? "待审批" : (step.risk_level || "unknown"))}</span>
    </button>
  `;
  item.querySelector("button").addEventListener("click", () => {
    state.selectedStepIndex = index;
    renderPendingStepDetail(step, index, isPending);
  });
  return item;
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
    item.className = "timeline-card answer-card";
    item.innerHTML = `
      <div class="timeline-step-button static">
        <span class="step-index">A</span>
        <span class="timeline-main">
          <span class="timeline-title">answer_received</span>
          <span class="timeline-copy"></span>
        </span>
        <span class="pill risk low">answer</span>
      </div>
    `;
    item.querySelector(".timeline-copy").textContent = response.answer || "";
    container.appendChild(item);
    renderStepDetail({ index: 0, number: "A", title: "answer_received", status: "answer", step: {}, output: { summary: response.answer || "" } });
    return;
  }

  const steps = response.steps || [];
  if (!steps.length) {
    container.appendChild(emptyItem("暂无步骤"));
    return;
  }
  const pendingIndex = awaitingApproval ? completedExecutionCount(state.lastExecution) : -1;
  steps.forEach((step, index) => container.appendChild(renderPlanStep(step, index, awaitingApproval, pendingIndex)));
  renderPendingStepDetail(steps[0], 0, awaitingApproval && pendingIndex === 0);
}

function renderTerminalReturns(title, result) {
  const container = $("workPlan");
  container.innerHTML = "";
  state.lastExecution = result;
  const entries = normalizeExecutionEntries(title, result);
  if (!entries.length) {
    container.appendChild(emptyItem("暂无执行结果"));
    return;
  }
  for (const entry of entries) {
    appendReturnCard(container, entry);
  }
  const selected = entries[Math.max(0, Math.min(state.selectedStepIndex, entries.length - 1))] || entries[0];
  renderStepDetail(selected);
}

function renderSharedExecution(title, result, outputId = "terminalOutput") {
  state.lastExecution = result;
  const text = renderExecutionText(title, result);
  if (outputId) printOutput(outputId, text);
  renderTerminalReturns(title, result);
}

function appendReturnCard(container, entry) {
  const output = entry.output || {};
  const displayStatus = entry.status || output.status || (output.ok ? "ok" : "failed");
  const item = document.createElement("article");
  item.className = `timeline-card result-step ${statusKind(displayStatus)}`;
  item.innerHTML = `
    <button class="timeline-step-button" type="button">
      <span class="step-index">${entry.number}</span>
      <span class="timeline-main">
        <span class="timeline-title">${escapeHtml(entry.title)}</span>
        <span class="timeline-copy">${escapeHtml(outputSummaryText(output))}</span>
      </span>
      <span class="pill risk ${statusKind(displayStatus)}">${escapeHtml(displayStatus)}</span>
    </button>
  `;
  item.querySelector("button").addEventListener("click", () => {
    state.selectedStepIndex = entry.index;
    renderStepDetail(entry);
  });
  container.appendChild(item);
}

function renderStepDetail(entry) {
  const container = $("workDetail");
  if (!container) return;
  if (!entry) {
    container.className = "detail-empty";
    container.textContent = "选择时间线中的步骤查看详情。";
    updateSelectedStepStatus(null);
    return;
  }
  updateSelectedStepStatus(entry);
  const step = entry.step || {};
  const output = entry.output || {};
  const proxy = output.execution_proxy || {};
  const observer = output.observer || {};
  const commandLabel = step.skill_script || step.command || output.command || primaryOutputObject(output).command || "";
  container.className = "step-detail";
  container.innerHTML = `
    <div class="detail-title-row">
      <div>
        <h4>${escapeHtml(entry.title || step.title || "步骤详情")}</h4>
        <p>${escapeHtml(step.reason || outputSummaryText(output))}</p>
      </div>
      <span class="pill risk ${statusKind(entry.status)}">${escapeHtml(entry.status || "selected")}</span>
    </div>
    <section class="detail-section">
      <h5>执行摘要</h5>
      <div class="meta-grid">
        ${renderMetaRows([
          ["状态", entry.status || output.status || ""],
          ["退出码", output.exit_code ?? ""],
          ["自动批准", output.auto_approved === true ? "是" : (output.auto_approved === false ? "否" : "")],
          ["执行器", step.executor_type || ""],
          ["风险", step.risk_level || ""],
          ["命令/Skill", commandLabel],
        ])}
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
    ${renderJsonDetails("策略审查", output.review || step.review || null)}
    ${renderJsonDetails("原始调试数据", { step, output }, false)}
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
  const enabled = Boolean(state.configSnapshot?.agent_loop?.thinking_trace_enabled);
  setThinkingSwitches(enabled);
  renderThinkingSummary();
  setConfigDirtyState(false);
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
  state.configSnapshot = data.config || state.configSnapshot || {};
  state.configOriginal = collectEditableConfigValues(state.configSnapshot);
  state.configDraft = { ...state.configOriginal };
  const enabled = Boolean(state.configSnapshot?.agent_loop?.thinking_trace_enabled);
  setThinkingSwitches(enabled);
  renderThinkingSummary();
  renderConfigCenter(state.configSnapshot);
  setConfigDirtyState(false);
  showToast(`thinking_summary ${enabled ? "已开启" : "已关闭"}`);
}

function collectEditableConfigValues(config) {
  const values = {};
  for (const group of CONFIG_GROUPS) {
    for (const field of group.fields) {
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
  const rows = [
    ["model", config.model || "--", config.provider || "provider"],
    ["api_key", config.api_key_configured ? "configured" : "missing", "只显示状态"],
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
      <input class="field" id="${escapeHtml(configInputId(field.key))}" data-config-key="${escapeHtml(field.key)}" type="${field.type === "number" ? "number" : "text"}" ${field.min !== undefined ? `min="${escapeHtml(field.min)}"` : ""} value="${escapeHtml(value)}">
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

function setConfigDirtyState(dirty) {
  const button = $("configSaveBtn");
  if (button) button.disabled = !dirty;
  setText("configDirtyState", dirty ? "modified" : "synced");
}

async function saveConfigChanges() {
  const changes = Object.entries(state.configDraft).filter(([key, value]) => value !== state.configOriginal[key]);
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
  if (state.activeWorkJobId && !state.workSuspended) {
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
  const job = await createJob("work", "run", payload);
  state.activeWorkJobId = job.job_id;
  state.workSuspended = false;
  updateWorkActionLabel();
  const completed = await pollJob(job.job_id, "workJobStatus", null, { suspendFlag: "workSuspended" });
  handleCompletedWork(completed, input);
}

function handleCompletedWork(completed, input) {
  if (completed.status === "suspended") return;
  state.activeWorkJobId = "";
  const result = completed.result || {};
  state.lastExecution = result;
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
  if (result.status !== "approval_required" && (result.execution || result.result || result.status === "executed" || result.status === "failed" || result.status === "cancelled")) {
    renderTerminalReturns(result.status || "work_return", result);
    printOutput("terminalOutput", renderExecutionText(result.status || "work_return", result));
  }
  if (result.status === "approval_required") {
    openApprovalDrawer(result, input);
    showToast("需要审批后继续");
  } else {
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
  const review = await api("/api/terminal/review", { method: "POST", body: { command } });
  if (review.status === "blocked") {
    setStatus("terminalJobStatus", "blocked", "high");
    printOutput("terminalOutput", review);
    return;
  }
  if (review.status === "approval_required") {
    setStatus("terminalJobStatus", "approval_required", "medium");
    printOutput("terminalOutput", review);
    openTerminalApprovalDrawer(command, review.review || review);
    return;
  }
  const job = await createJob("terminal", "run", { command, approve: false });
  const completed = await pollJob(job.job_id, "terminalJobStatus", "terminalOutput");
  renderSharedExecution("终端输出", completed.result || completed, "terminalOutput");
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
    item.className = "event";
    item.innerHTML = `
      <time>${escapeHtml(compactAuditTime(session.started_at || session.updated_at || ""))}</time>
      <div class="body">
        <strong>${escapeHtml(session.session_id || session.path || "session")}</strong>
        <span>status=${escapeHtml(session.status || "unknown")} · file=${escapeHtml(session.path || session.file || "logs/session")}</span>
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
      const haystack = [session.session_id, session.status, session.started_at, session.updated_at, session.path, session.file].join(" ").toLowerCase();
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
  renderAuditEventTimeline();
  renderAuditObserverSummary();
  updateAuditMetrics();
  $("auditOutput").textContent = data.report || pretty(data);
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
    const name = auditEventName(event);
    item.innerHTML = `
      <time>${escapeHtml(compactAuditTime(auditEventTime(event)))}</time>
      <div class="body">
        <strong>${escapeHtml(name)}</strong>
        <span>${escapeHtml(auditEventSummary(event))}</span>
      </div>
    `;
    container.appendChild(item);
  }
}

function filteredAuditEvents() {
  const category = String($("auditEventFilter")?.value || "");
  const limit = Math.max(1, Math.min(200, Number($("auditLimitInput")?.value || 40)));
  return (state.auditEvents || [])
    .filter((event) => !category || auditEventMatchesCategory(event, category))
    .slice(0, limit);
}

function auditEventMatchesCategory(event, category) {
  const text = `${auditEventName(event)} ${pretty(event)}`.toLowerCase();
  if (category === "observer") return text.includes("observer") || text.includes("auditd");
  if (category === "policy") return text.includes("policy") || text.includes("review") || text.includes("risk");
  if (category === "execution") return text.includes("execution") || text.includes("command") || text.includes("terminal") || text.includes("script");
  if (category === "decision") return text.includes("decision") || text.includes("approve") || text.includes("reject") || text.includes("skip") || text.includes("terminate");
  return true;
}

function auditEventName(event) {
  return event.event || event.type || event.name || event.status || event.kind || "event";
}

function auditEventTime(event) {
  return event.timestamp || event.time || event.started_at || event.created_at || "";
}

function compactAuditTime(value) {
  const text = String(value || "");
  if (!text) return "--";
  return text.includes("T") ? text.split("T").pop().replace(/Z$/, "") : text;
}

function auditEventSummary(event) {
  const payload = event.payload || event.data || event;
  const rows = [
    payload.status ? `status=${payload.status}` : "",
    payload.mode ? `mode=${payload.mode}` : "",
    payload.command ? `command=${payload.command}` : "",
    payload.skill_script ? `skill=${payload.skill_script}` : "",
    payload.risk_level ? `risk=${payload.risk_level}` : "",
    payload.decision ? `decision=${payload.decision}` : "",
    payload.error ? `error=${payload.error}` : "",
  ].filter(Boolean);
  return rows.join(" · ") || compactText(renderUserOutputText(payload), 180) || "无摘要字段，完整内容见右侧报告。";
}

function renderAuditObserverSummary() {
  const container = $("auditObserverSummary");
  if (!container) return;
  const observerEvents = (state.auditEvents || []).filter((event) => auditEventMatchesCategory(event, "observer"));
  container.innerHTML = "";
  if (!observerEvents.length) {
    container.innerHTML = '<tr><td colspan="3">当前 session 没有 observer 事件。</td></tr>';
    return;
  }
  for (const event of observerEvents.slice(0, 12)) {
    const payload = event.payload || event.data || event;
    const status = payload.status || payload.lifecycle || auditEventName(event);
    const row = document.createElement("tr");
    row.innerHTML = `
      <td><span class="pill risk ${statusKind(status)}">${escapeHtml(status)}</span></td>
      <td class="mono">${escapeHtml(auditEventName(event))}</td>
      <td>${escapeHtml(auditEventSummary(event))}</td>
    `;
    container.appendChild(row);
  }
}

function updateAuditMetrics() {
  const events = state.auditEvents || [];
  const textFor = (event) => `${auditEventName(event)} ${pretty(event)}`.toLowerCase();
  const decisions = events.filter((event) => /decision|approve|reject|skip|terminate/.test(textFor(event))).length;
  const commands = events.filter((event) => /command|terminal|script|execution/.test(textFor(event))).length;
  const observer = events.filter((event) => auditEventMatchesCategory(event, "observer")).length;
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
    if (button.id === "thinkingTraceSwitch" || button.id === configInputId("agent_loop.thinking_trace_enabled")) return;
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
    if (button) updateConfigDraftFromControl(button);
  });
  on("doctorRunBtn", "click", () => safeAction(runDoctor));
  on("policyUnlockBtn", "click", () => safeAction(unlockPolicy));
  on("policyLockBtn", "click", lockPolicy);
  on("policyReloadBtn", "click", () => safeAction(loadPolicies));
  on("policySaveBtn", "click", () => safeAction(savePolicy));
  on("policyFileSelect", "change", (event) => safeAction(() => readPolicy(event.target.value)));
  on("policyAddRuleBtn", "click", () => safeAction(() => openPolicyFile("risk-rules.json")));
  on("policyEditBoundaryBtn", "click", () => safeAction(() => openPolicyFile("audit-boundaries.json")));
  on("thinkingTraceSwitch", "click", () => safeAction(updateThinkingTrace));
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
