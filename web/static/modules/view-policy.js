/** @typedef {import("./types.js").AppContext} AppContext */
/** @typedef {import("./types.js").PolicyView} PolicyView */

/** @param {AppContext} app @returns {PolicyView} */
export function createPolicyView(app) {
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

  async function runDoctor() {
    const data = await app.api("/api/doctor");
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
    app.printOutput("doctorOutput", data);
  }

  function updatePolicyEditState() {
    const unlocked = state.policySudoUnlocked;
    document.querySelectorAll(".policy-edit").forEach((el) => {
      if (el instanceof HTMLButtonElement
        || el instanceof HTMLInputElement
        || el instanceof HTMLSelectElement
        || el instanceof HTMLTextAreaElement) {
        el.disabled = !unlocked;
      }
    });
    if ($("policyEditor")) $("policyEditor").disabled = !unlocked;
    if ($("policySaveBtn")) $("policySaveBtn").disabled = !unlocked || !state.currentPolicyPath;
    if ($("policyBoundaryOptions")) $("policyBoundaryOptions").hidden = !unlocked;
    setStatus("policyLockPill", unlocked ? "可编辑" : "已锁定", unlocked ? "ok" : "medium");
    setText("policyEditMode", unlocked ? "本次会话可编辑" : "只读");
    renderCommandGuardState();
    renderPolicyFileDialog();
  }

  function renderCommandGuardState() {
    const enabled = state.commandGuardEnabled !== false;
    setStatus("policyGuardPill", enabled ? "已启用" : "已关闭", enabled ? "ok" : "medium");
    setText("policyGuardStatus", enabled ? "命令安全检查已启用" : "命令安全检查已关闭");
    setText(
      "policyGuardDescription",
      enabled
        ? "用于拦截高风险命令；关闭后仍保留正则规则和文件保险箱保护。"
        : "当前只保留正则规则和文件保险箱保护；重新启用需要 sudo 核对。",
    );
    const button = $("policyGuardToggleBtn");
    if (button) {
      button.disabled = !state.policySudoUnlocked;
      button.textContent = enabled ? "关闭检查" : "启用检查";
      button.title = state.policySudoUnlocked ? "需要 sudo 授权才能切换" : "请先核对服务器密码";
    }
  }

  async function loadPolicies() {
    const data = await app.api("/api/policies");
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
      renderPolicyFileDialog();
      app.printOutput("policyOutput", { ok: true, status: "no_policy_files" });
      renderRiskRules(null);
      renderAuditBoundaries(null);
      renderFileVault(null);
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
    if (currentPath !== "file-vault.json" && paths.includes("file-vault.json")) {
      const data = await readPolicyJson("file-vault.json");
      if (data?.ok) renderFileVault(data.json);
    }
  }

  async function readPolicyJson(path) {
    try {
      return await app.api("/api/policies/read", { method: "POST", body: { path } });
    } catch (error) {
      console.error(error);
      return null;
    }
  }

  async function readPolicy(path) {
    const data = await app.api("/api/policies/read", { method: "POST", body: { path } });
    if (!data.ok) {
      app.printOutput("policyOutput", data);
      return data;
    }
    state.currentPolicyPath = data.path;
    $("policyEditor").value = data.content || "";
    renderPolicyFileDialog();
    app.printOutput("policyOutput", { ok: true, status: "read", path: data.path });
    if (data.path === "risk-rules.json") renderRiskRules(data.json);
    if (data.path === "audit-boundaries.json") renderAuditBoundaries(data.json);
    if (data.path === "file-vault.json") renderFileVault(data.json);
    updatePolicyEditState();
    return data;
  }

  async function unlockPolicy() {
    const password = $("policyPassword").value;
    const data = await app.api("/api/policies/sudo-check", { method: "POST", body: { password } });
    app.printOutput("policyOutput", data);
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
    const data = await app.api("/api/policies/validate", {
      method: "POST",
      body: {
        path: state.currentPolicyPath,
        content: $("policyEditor").value,
      },
    });
    app.printOutput("policyOutput", data);
    if (!data.ok) {
      if (!silent) showToast(data.error || data.status || "策略校验失败");
      return data;
    }
    if (!silent) showToast("策略校验通过");
    return data;
  }

  function renderPolicyFileDialog() {
    const path = state.currentPolicyPath || "未选择文件";
    const editing = state.policySudoUnlocked;
    const editor = $("policyEditor");
    const preview = $("policyFilePreview");
    const saveButton = $("policySaveBtn");
    setText("policyFileDialogTitle", path);
    setText(
      "policyFileDialogMeta",
      state.currentPolicyPath
        ? (editing ? "编辑状态：修改内容后保存当前文件。" : "只读状态：查看当前策略文件的完整内容。")
        : "选择文件后点击“查阅文件”。",
    );
    if (editor) {
      editor.disabled = !editing;
      editor.hidden = !editing;
    }
    if (preview) {
      preview.textContent = editor?.value || "暂无文件内容。";
      preview.hidden = editing;
    }
    if (saveButton) saveButton.disabled = !editing || !state.currentPolicyPath;
  }

  function openPolicyFileDialog() {
    const dialog = $("policyFileDialog");
    if (!dialog) return;
    renderPolicyFileDialog();
    if (typeof dialog.showModal === "function") {
      if (!dialog.open) dialog.showModal();
    } else {
      dialog.setAttribute("open", "");
    }
    if (state.policySudoUnlocked) $("policyEditor")?.focus();
  }

  function closePolicyFileDialog() {
    const dialog = $("policyFileDialog");
    if (!dialog) return;
    if (typeof dialog.close === "function" && dialog.open) dialog.close();
    else dialog.removeAttribute("open");
  }

  async function toggleCommandGuard() {
    if (!state.policySudoUnlocked) {
      showToast("请先核对服务器密码");
      return;
    }
    const enabled = state.commandGuardEnabled === false;
    const data = await app.api("/api/policies/command-guard", {
      method: "POST",
      body: { enabled, password: state.policySudoPassword },
    });
    app.printOutput("policyOutput", data);
    if (!data.ok) {
      if (String(data.status || "").startsWith("sudo_")) lockPolicy();
      showToast(data.error || data.status || "命令安全检查切换失败");
      return;
    }
    state.commandGuardEnabled = data.command_guard?.enabled !== false;
    state.configSnapshot = data.config || state.configSnapshot;
    renderCommandGuardState();
    showToast(state.commandGuardEnabled ? "命令安全检查已启用" : "命令安全检查已关闭");
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
    const data = await app.api("/api/policies/write", {
      method: "POST",
      body: {
        path: state.currentPolicyPath,
        content: $("policyEditor").value,
        password: state.policySudoPassword,
      },
    });
    app.printOutput("policyOutput", data);
    if (!data.ok) {
      if (String(data.status || "").startsWith("sudo_")) lockPolicy();
      showToast(data.error || data.status || "保存失败");
      return;
    }
    showToast("策略已保存");
    await readPolicy(state.currentPolicyPath);
    await loadPolicySummaries(state.currentPolicyPath);
  }

  async function openPolicyFile(path) {
    if (!path) {
      showToast("当前没有可查阅的策略文件");
      return;
    }
    if ($("policyFileSelect")) $("policyFileSelect").value = path;
    const data = await readPolicy(path);
    if (!data?.ok) return;
    openPolicyFileDialog();
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

  function renderFileVault(json) {
    const container = $("policyVaultSummary");
    if (!container) return;
    const paths = Array.isArray(json?.paths) ? json.paths : [];
    if (!json) {
      container.innerHTML = '<div class="vault-empty">未加载文件保险箱策略。</div>';
      return;
    }
    container.innerHTML = `
      <div class="vault-summary-head">
        <div><strong>文件保险箱</strong><span>工作模式写入会阻断，读取与终端访问需要人工确认。</span></div>
        <span class="pill risk high">${paths.length} 条保护路径</span>
      </div>
      <div class="vault-path-grid">${paths.length ? paths.map((path) => {
        const wildcard = typeof path === "string" && path.endsWith("/*");
        return `<article class="vault-path-card"><div class="vault-path-icon" aria-hidden="true">▣</div><div class="vault-path-body"><strong class="mono">${escapeHtml(path)}</strong><span>${wildcard ? "目录及嵌套文件" : "单个文件"}</span></div><span class="pill risk high">保护中</span></article>`;
      }).join("") : '<div class="vault-empty">当前没有加入保险箱的保护路径。</div>'}</div>
    `;
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


  return {
    runDoctor,
    updatePolicyEditState,
    renderCommandGuardState,
    loadPolicies,
    loadPolicySummaries,
    readPolicyJson,
    readPolicy,
    unlockPolicy,
    validatePolicy,
    renderPolicyFileDialog,
    openPolicyFileDialog,
    closePolicyFileDialog,
    toggleCommandGuard,
    lockPolicy,
    savePolicy,
    openPolicyFile,
    appendRuleRow,
    renderRiskRules,
    renderAuditBoundaries,
    renderFileVault,
    renderBoundaryRawSection,
  };
}
