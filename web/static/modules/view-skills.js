import { remoteSecretTransmissionBlocked } from "./config-utils.js";

/** @typedef {import("./types.js").AppContext} AppContext */
/** @typedef {import("./types.js").SkillsView} SkillsView */

/** @param {AppContext} app @returns {SkillsView} */
export function createSkillsView(app) {
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

  async function loadSense(topic = $("senseTopicSelect")?.value || "all") {
    setStatus("senseStatus", "loading", "medium");
    const data = await app.api("/api/sense", { method: "POST", body: { topic } });
    const sense = data.sense || {};
    renderSense(sense);
    setStatus("senseStatus", data.topic || topic, data.ok ? "ok" : "failed");
  }

  function renderSense(sense) {
    const grouped = sense.topic ? { [sense.topic]: sense } : sense;
    const resource = grouped.resource || {};
    const disk = grouped.disk || {};
    const service = grouped.service || {};
    const load = app.firstLine(resource.load_summary).match(/load average[s]?:\s*([^,]+)/i)?.[1] || "--";
    const diskLine = String(disk.df_summary || "").split("\n").find((line) => /\s[0-9]+%\s/.test(line)) || "";
    const diskUse = diskLine.match(/\s([0-9]+%)\s/)?.[1] || "--";
    const memoryLine = String(resource.memory_summary || "").split("\n").find((line) => line.toLowerCase().startsWith("mem:")) || "";
    const memory = memoryLine ? memoryLine.trim().replace(/\s+/g, " ") : "--";
    const failedServices = String(service.failed_summary || "").split("\n").filter((line) => /^\s*●/.test(line) || /\bfailed\b/i.test(line)).length;
    setText("metricLoad", load);
    setText("metricDisk", diskUse);
    setText("metricMemory", memory === "--" ? "--" : memory.split(" ").slice(2, 4).join("/"));
    setText("metricServices", String(failedServices));
    app.printOutput("environmentPayload", sense);
  }

  async function loadTools() {
    const data = await app.api("/api/tools");
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
    const data = await app.api("/api/skills/tree");
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
    const data = await app.api("/api/skills/validate");
    $("skillCodeOutput").textContent = pretty(data);
    showToast(data.ok ? "Skill 校验通过" : "Skill 校验发现问题");
  }

  async function loadMcpRegistry() {
    const data = await app.api("/api/mcp");
    state.mcpRoot = data.root || "";
    state.mcpServers = Array.isArray(data.servers) ? data.servers : [];
    state.mcpTools = [];
    state.mcpFindings = Array.isArray(data.findings) ? data.findings : [];
    renderMcpRegistry();
    renderMcpTools();
    setStatus("mcpStatus", data.status || "listed", state.mcpFindings.length ? "medium" : "ok");
    app.printOutput("mcpOutput", data);
  }

  async function loadMcpTools() {
    setStatus("mcpStatus", "loading tools", "medium");
    const data = await app.api("/api/mcp/tools");
    state.mcpRoot = data.root || state.mcpRoot || "";
    state.mcpServers = Array.isArray(data.servers) ? data.servers : state.mcpServers;
    state.mcpTools = Array.isArray(data.tools) ? data.tools : [];
    state.mcpFindings = Array.isArray(data.findings) ? data.findings : [];
    renderMcpRegistry();
    renderMcpTools();
    setStatus("mcpStatus", data.status || "listed", state.mcpFindings.length ? "medium" : "ok");
    app.printOutput("mcpOutput", data);
  }

  async function validateMcp() {
    setStatus("mcpStatus", "validating", "medium");
    const data = await app.api("/api/mcp/validate");
    state.mcpFindings = Array.isArray(data.validation?.findings) ? data.validation.findings : [];
    await loadMcpRegistry();
    setStatus("mcpStatus", data.ok ? "validated" : "invalid", data.ok ? "ok" : "failed");
    app.printOutput("mcpOutput", data);
    showToast(data.ok ? "MCP 校验通过" : "MCP 校验发现问题");
  }

  function renderMcpRegistry() {
    setText("mcpRoot", state.mcpRoot || "--");
    setText("mcpCount", String(state.mcpServers.length));
    setText("mcpValidCount", String(state.mcpServers.filter((server) => server.valid).length));
    setText("mcpToolCount", String(state.mcpTools.length));
    const container = $("mcpCatalog");
    if (!container) return;
    container.innerHTML = "";
    if (!state.mcpServers.length) {
      const row = document.createElement("tr");
      row.innerHTML = '<td colspan="5">暂无 MCP manifest。可在项目根目录 mcp/&lt;id&gt;/mcp.json 安装外部 MCP 能力。</td>';
      container.appendChild(row);
      return;
    }
    for (const server of state.mcpServers) {
      const findingCount = Array.isArray(server.findings) ? server.findings.length : 0;
      const row = document.createElement("tr");
      row.className = "clickable";
      row.innerHTML = `
        <td><span class="mono">${escapeHtml(server.id || server.name || "mcp")}</span><div class="small">${escapeHtml(server.description || server.name || "")}</div></td>
        <td><span class="pill">${escapeHtml(server.transport || "unknown")}</span></td>
        <td>${server.enabled === false ? "false" : "true"}</td>
        <td><span class="pill risk ${server.valid ? "low" : "high"}">${escapeHtml(server.valid ? `valid · ${server.tool_count ?? 0} tools` : `${findingCount} issue${findingCount === 1 ? "" : "s"}`)}</span></td>
        <td class="mono">${escapeHtml(server.path || "")}</td>
      `;
      row.addEventListener("click", () => {
        setStatus("mcpStatus", server.valid ? "selected" : "invalid", server.valid ? "ok" : "failed");
        app.printOutput("mcpOutput", server);
      });
      container.appendChild(row);
    }
  }

  function renderMcpTools() {
    setText("mcpToolCount", String(state.mcpTools.length));
    const container = $("mcpToolCatalog");
    if (!container) return;
    container.innerHTML = "";
    if (!state.mcpTools.length) {
      const row = document.createElement("tr");
      row.innerHTML = '<td colspan="4">暂无 MCP tools。点击“加载工具”后会对有效且启用的 server 执行 tools/list。</td>';
      container.appendChild(row);
      return;
    }
    for (const tool of state.mcpTools) {
      const row = document.createElement("tr");
      row.className = "clickable";
      const schema = tool.inputSchema && Object.keys(tool.inputSchema).length ? JSON.stringify(tool.inputSchema) : "{}";
      row.innerHTML = `
        <td><span class="mono">${escapeHtml(tool.ref || `${tool.server_id || "mcp"}/${tool.name || "tool"}`)}</span><div class="small">${escapeHtml(tool.server_name || tool.server_id || "")}</div></td>
        <td><span class="pill">${escapeHtml(tool.transport || "unknown")}</span></td>
        <td>${escapeHtml(tool.description || "")}</td>
        <td class="mono">${escapeHtml(schema)}</td>
      `;
      row.addEventListener("click", () => {
        setStatus("mcpStatus", "tool selected", "ok");
        app.printOutput("mcpOutput", tool);
      });
      container.appendChild(row);
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
      const risk = tool.risk || "low";
      const row = document.createElement("tr");
      const scriptPath = `${group.split(" / ").join("/")}/scripts/${name}.sh`;
      const materialization = tool.materialization || "local";
      const remoteCell = materialization === "local"
        ? '<span class="pill">local</span>'
        : materialization === "ready"
          ? '<span class="pill risk low">ready</span>'
          : materialization === "materializing"
            ? '<button class="btn secondary compact-btn" type="button" disabled aria-busy="true">加载中</button>'
            : `<button class="btn secondary compact-btn" type="button" data-materialize-skill="${escapeHtml(tool.skill || group)}">${materialization === "failed" ? "重试加载" : "加载 Skill"}</button>`;
      row.className = "clickable";
      row.dataset.path = scriptPath;
      row.innerHTML = `
        <td class="mono">${escapeHtml(name)}</td>
        <td>${escapeHtml(group)}</td>
        <td><span class="pill risk ${riskKind(risk)}">${escapeHtml(risk)}</span></td>
        <td>已登记</td>
        <td>${remoteCell}</td>
      `;
      row.addEventListener("click", (event) => {
        const target = event.target instanceof Element ? event.target : null;
        const button = target?.closest("[data-materialize-skill]");
        if (button instanceof HTMLElement) {
          event.stopPropagation();
          app.safeAction(() => materializeSkill(button.dataset.materializeSkill));
          return;
        }
        if (materialization === "available") {
          app.safeAction(() => materializeSkill(tool.skill || group));
          return;
        }
        readSkillFile(scriptPath, "script");
      });
      container.appendChild(row);
    }
  }

  async function materializeSkill(skill) {
    if (!skill) return;
    state.tools.forEach((tool) => {
      if (tool.skill === skill) tool.materialization = "materializing";
    });
    renderToolCatalog();
    const data = await app.api("/api/skills/materialize", { method: "POST", body: { skill } });
    if (!data.ok) {
      state.tools.forEach((tool) => {
        if (tool.skill === skill) tool.materialization = "failed";
      });
      renderToolCatalog();
      showToast(data.error || data.status || "Skill 加载失败");
      return;
    }
    await loadTools();
    await loadSkillTree();
    showToast(`${skill} 已完成整包校验与加载`);
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
      details.open = false;
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
    const data = await app.api("/api/skills/read", { method: "POST", body: { path } });
    if (!data.ok) return showToast(data.error || data.status || "read failed");
    if ((kind || data.kind) === "markdown") {
      $("skillMarkdownPreview").innerHTML = renderMarkdown(data.content || "");
    } else {
      setText("skillCodeTitle", data.path);
      $("skillCodeOutput").textContent = data.content || "";
    }
  }

  async function reviewScript() {
    const ref = $("scriptSelect").value;
    if (!ref) return showToast("Skill required");
    const args = app.parseJsonText("scriptArgs");
    setStatus("scriptJobStatus", "review", "review");
    const data = await app.api("/api/script/review", { method: "POST", body: { ref, arguments: args } });
    setStatus("scriptJobStatus", data.status, data.ok ? "ok" : "failed");
    app.printOutput("scriptOutput", data);
  }

  async function runScript() {
    const ref = $("scriptSelect").value;
    if (!ref) return showToast("Skill required");
    const args = app.parseJsonText("scriptArgs");
    const job = await app.createJob("script", "run", { ref, arguments: args, approve: true });
    state.activeScriptJobId = job.job_id;
    $("scriptCancelBtn").disabled = false;
    const completed = await app.pollJob(job.job_id, "scriptJobStatus", "scriptOutput");
    state.activeScriptJobId = "";
    $("scriptCancelBtn").disabled = true;
    app.printOutput("scriptOutput", completed.result || completed);
  }

  async function cancelScript() {
    if (!state.activeScriptJobId) return;
    const data = await app.cancelJob(state.activeScriptJobId);
    app.printOutput("scriptOutput", data);
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
      const textarea = wrapper.querySelector("textarea");
      if (!(textarea instanceof HTMLTextAreaElement)) {
        throw new Error(`脚本编辑器缺少 textarea: ${script.name}`);
      }
      textarea.value = script.content || "";
      textarea.addEventListener("input", markEditDirty);
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
      if (!(item instanceof HTMLElement)) return;
      const textarea = item.querySelector("textarea");
      if (!(textarea instanceof HTMLTextAreaElement)) {
        throw new Error(`脚本编辑器缺少 textarea: ${item.dataset.name || "unknown"}`);
      }
      scripts.push({
        name: item.dataset.name,
        description: item.dataset.description,
        content: textarea.value,
      });
    });
    return { ...state.editPackage, scripts };
  }

  async function planEdit() {
    if (remoteSecretTransmissionBlocked(state.configSnapshot)) {
      showToast("请先在配置中心允许远程传输 API Key");
      return;
    }
    const input = $("editInput").value.trim();
    if (!input) return showToast("Edit input required");
    const folder = $("editFolderSelect")?.value || "skills";
    const request = `编辑入口: ${folder}\n需求: ${input}`;
    setStatus("editJobStatus", "planning", "planning");
    const data = await app.api("/api/edit/plan", { method: "POST", body: { input: request } });
    setStatus("editJobStatus", data.status, data.ok ? "ok" : "failed");
    renderEditPackage(data.edit);
    app.printOutput("editOutput", data);
  }

  async function reviewEdit() {
    const edit = gatherEditPackage();
    setStatus("editJobStatus", "review", "review");
    const data = await app.api("/api/edit/review", { method: "POST", body: { edit } });
    setStatus("editJobStatus", data.status, data.ok ? "ok" : "failed");
    app.printOutput("editOutput", data);
  }

  async function applyEdit() {
    const edit = gatherEditPackage();
    const job = await app.createJob("edit", "apply", { edit, approve: true });
    const completed = await app.pollJob(job.job_id, "editJobStatus", "editOutput");
    app.printOutput("editOutput", completed.result || completed);
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

  function startNewSkill() {
    app.showScreen("skills");
    const editTab = document.querySelector('[data-skill-mode="edit"]');
    if (editTab instanceof HTMLElement) editTab.click();
    $("editInput").focus();
  }


  return {
    loadSense,
    renderSense,
    loadTools,
    loadSkillTree,
    validateSkills,
    loadMcpRegistry,
    loadMcpTools,
    validateMcp,
    renderMcpRegistry,
    renderMcpTools,
    renderToolCatalog,
    materializeSkill,
    renderSkillTree,
    renderTreeNode,
    renderMarkdownFileList,
    populateEditFolders,
    readSkillFile,
    reviewScript,
    runScript,
    cancelScript,
    renderEditPackage,
    gatherEditPackage,
    planEdit,
    reviewEdit,
    applyEdit,
    markEditDirty,
    startNewSkill,
  };
}
