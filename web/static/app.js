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
};

const $ = (id) => document.getElementById(id);

const titles = {
  workbench: "工作台",
  skills: "Skill 库",
  policy: "策略",
  audit: "审计与回放",
  config: "配置中心",
};

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

function pretty(value) {
  if (value === undefined) return "";
  if (typeof value === "string") return value;
  return JSON.stringify(value, null, 2);
}

function printOutput(id, value) {
  const el = $(id);
  if (el) el.textContent = pretty(value);
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
  button.textContent = state.awaitingWorkApproval ? "提交审批选择" : "生成 work_plan";
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
    item.innerHTML = `
      <div class="step-index">${index + 1}</div>
      <div>
        <div class="item-head">
          <h4>${escapeHtml(step.title || step.id || "step")}</h4>
          <span class="pill risk ${riskKind(step.risk_level)}">${escapeHtml(step.risk_level || "unknown")}</span>
        </div>
        <p></p>
        <div class="decision-row">
          <select class="select decision-select">
            <option value="y">approve</option>
            <option value="n">reject</option>
            <option value="s">skip</option>
            <option value="t">terminate</option>
          </select>
          <input class="field revision-input" placeholder="skip revision request">
        </div>
      </div>
    `;
    item.querySelector("p").textContent = [
      step.executor_type,
      step.skill_script,
      step.command,
      step.expected_effect,
    ].filter(Boolean).join("\n");
    item.querySelector(".decision-select").value = decision;
    container.appendChild(item);
  });
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

async function pollJob(jobId, statusId, outputId) {
  setStatus(statusId, "running", "running");
  for (;;) {
    const job = await api(`/api/jobs/${jobId}`);
    if (job.status === "queued" || job.status === "running") {
      await new Promise((resolve) => window.setTimeout(resolve, 900));
      continue;
    }
    const resultStatus = job.result?.status || job.status;
    const kind = resultStatus === "approval_required" ? "approval_required" : (job.status === "succeeded" ? "ok" : "failed");
    setStatus(statusId, resultStatus, kind);
    printOutput(outputId, job.result || job);
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
  setStatus("connectionState", "online", "ok");
  setText("rootPath", health.root || "connected");
  await loadTools();
  await loadAuditList();
  await loadPolicies();
  showToast("Connected");
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
    row.innerHTML = `
      <td class="mono">${escapeHtml(name)}</td>
      <td>${escapeHtml(group)}</td>
      <td class="mono">${escapeHtml(tool.script || `scripts/${name}.sh`)}</td>
      <td><span class="pill risk low">low</span></td>
      <td>已登记</td>
    `;
    container.appendChild(row);
  }
}

async function runWork() {
  const input = $("workInput").value.trim();
  if (!input) return showToast("Work input required");
  const payload = { input };
  if (state.awaitingWorkApproval && state.workPlanInput === input && state.workPlan?.response_type === "work_plan") {
    payload.response = state.workPlan;
    payload.context = state.workContext || {};
    payload.decisions = collectWorkDecisions();
  }
  const job = await createJob("work", "run", payload);
  const completed = await pollJob(job.job_id, "workJobStatus", "workOutput");
  const result = completed.result || {};
  if (result.response) {
    renderWorkPlan(result.response, input, result.context || null, result.status === "approval_required");
  } else if (result.status !== "approval_required") {
    state.awaitingWorkApproval = false;
    updateWorkActionLabel();
  }
  if (result.status === "approval_required") showToast("Approval required");
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
  await pollJob(job.job_id, "scriptJobStatus", "scriptOutput");
}

async function runTerminal() {
  const command = $("terminalCommand").value.trim();
  if (!command) return showToast("Command required");
  const job = await createJob("terminal", "run", { command });
  await pollJob(job.job_id, "terminalJobStatus", "terminalOutput");
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
    container.appendChild(wrapper);
  }
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
  setStatus("editJobStatus", "planning", "planning");
  const data = await api("/api/edit/plan", { method: "POST", body: { input } });
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
  await pollJob(job.job_id, "editJobStatus", "editOutput");
}

async function loadAuditList() {
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
  const observer = $("auditBoundarySummary");
  if (list) list.innerHTML = "";
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

  if (observer) {
    const boundaryRows = json.available_boundaries || (allowed.audit_payload_modes || []).map((mode) => ({
      id: mode,
      description: `audit_payload_mode=${mode}`,
    }));
    for (const boundary of boundaryRows) {
      const row = document.createElement("tr");
      const activeClass = boundary.id === active ? "low" : "medium";
      row.innerHTML = `
        <td><span class="pill risk ${activeClass}">${boundary.id === active ? "active" : "option"}</span></td>
        <td class="mono">${escapeHtml(boundary.id)}</td>
        <td>${escapeHtml(boundary.description || boundary.name || "")}</td>
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
  on("workRunBtn", "click", () => safeAction(runWork));
  on("scriptReviewBtn", "click", () => safeAction(reviewScript));
  on("scriptRunBtn", "click", () => safeAction(runScript));
  on("terminalRunBtn", "click", () => safeAction(runTerminal));
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
  bindNavigation();
  bindModeTabs();
  bindSwitches();
  bindActions();
  if (state.token) safeAction(connect);
}

init();
