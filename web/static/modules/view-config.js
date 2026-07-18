import {
  collectEditableConfigValues,
  configInputId,
  getNestedValue,
  normalizeConfigFieldValue,
  normalizeProviderId,
  pendingConfigChanges as configDiff,
  remoteSecretTransmissionBlocked,
} from "./config-utils.js";

/** @typedef {import("./types.js").AppContext} AppContext */
/** @typedef {import("./types.js").ConfigView} ConfigView */

/**
 * @param {AppContext} app
 * @param {{renderWorkbench?: Function, renderThinkingSummary?: Function, setThinkingSwitches?: Function, thinkingTraceEnabled?: Function, updateRemoteActionState?: Function}} [hooks]
 * @returns {ConfigView}
 */
export function createConfigView(app, hooks = {}) {
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
  const providerRules = () => state.domainSchema?.provider_normalization || null;
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

  async function loadConfig() {
    if (!state.configProviders.length) {
      await loadConfigProviders();
    }
    const data = await app.api("/api/config");
    state.configSnapshot = data.config || {};
    state.commandGuardEnabled = state.configSnapshot?.command_guard?.enabled !== false;
    state.configOriginal = collectEditableConfigValues(state.configSnapshot || {}, CONFIG_GROUPS, providerRules());
    state.configDraft = { ...state.configOriginal };
    renderConfigCenter(state.configSnapshot || {});
    syncThinkingTraceFromConfig();
    hooks.renderWorkbench?.();
    setConfigDirtyState(false);
    hooks.updateRemoteActionState?.();
  }

  async function loadConfigProviders() {
    const data = await app.api("/api/config/providers");
    if (!data.ok) {
      showToast(data.error || data.status || "provider 加载失败");
      state.configProviders = [];
      return;
    }
    state.configProviders = Array.isArray(data.providers) ? data.providers : [];
  }

  function syncThinkingTraceFromConfig() {
    const enabled = Boolean(state.configSnapshot?.agent_loop?.thinking_trace_enabled);
    hooks.setThinkingSwitches?.(enabled);
  }

  async function updateThinkingTrace(next) {
    const preservedChanges = pendingConfigChanges(new Set([THINKING_TRACE_KEY]));
    const data = await app.api("/api/config/update", {
      method: "POST",
      body: { key: THINKING_TRACE_KEY, value: next },
    });
    if (!data.ok) {
      showToast(data.error || data.status || "config update failed");
      return;
    }
    state.configSnapshot = data.config || state.configSnapshot || {};
    state.configOriginal = collectEditableConfigValues(state.configSnapshot || {}, CONFIG_GROUPS, providerRules());
    state.configDraft = { ...state.configOriginal };
    renderConfigCenter(state.configSnapshot || {});
    syncThinkingTraceFromConfig();
    restoreConfigDraftChanges(preservedChanges);
    hooks.renderThinkingSummary?.();
    setConfigDirtyState(hasConfigChanges());
    const enabled = Boolean(state.configSnapshot?.agent_loop?.thinking_trace_enabled);
    showToast(`thinking_summary ${enabled ? "已开启" : "已关闭"}`);
  }

  async function toggleThinkingTraceFromWorkbench() {
    await updateThinkingTrace(!Boolean(hooks.thinkingTraceEnabled?.()));
  }

  async function toggleThinkingTraceFromConfig(button) {
    await updateThinkingTrace(!button.classList.contains("on"));
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
      ["model", config.model || "--", providerLabel(config.provider_id || config.provider || "provider")],
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
          ${group.fields.map((field) => renderConfigField(field, configFieldValue(config, field))).join("")}
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

  function configFieldValue(config, field) {
    if (state.configDraft && Object.prototype.hasOwnProperty.call(state.configDraft, field.key)) {
      return state.configDraft[field.key];
    }
    if (field.key === "provider") return config.provider_id || config.provider;
    return getNestedValue(config, field.key);
  }

  function renderConfigField(field, rawValue) {
    const value = normalizeConfigFieldValue(field, rawValue, providerRules());
    if (field.type === "boolean") {
      const help = field.onEffect || field.offEffect
        ? `<div class="config-switch-effects small">
            ${field.onEffect ? `<span>开：${escapeHtml(field.onEffect)}</span>` : ""}
            ${field.offEffect ? `<span>关：${escapeHtml(field.offEffect)}</span>` : ""}
          </div>`
        : `<div class="small">${escapeHtml(field.comment)}</div>`;
      return `
        <div class="toggle-row config-field-row">
          <div>
            <strong class="white">${escapeHtml(field.label)}</strong>
            ${help}
          </div>
          <button class="switch config-switch${value ? " on" : ""}" id="${escapeHtml(configInputId(field.key))}" type="button" data-config-key="${escapeHtml(field.key)}" aria-label="${escapeHtml(field.label)}" aria-pressed="${value ? "true" : "false"}"><span></span></button>
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
    if (field.type === "provider") {
      const providers = state.configProviders.length ? state.configProviders : [{ id: value || "openai_compatible", label: value || "openai_compatible" }];
      return `
        <label class="small config-field-label" for="${escapeHtml(configInputId(field.key))}">
          <span>${escapeHtml(field.label)}</span>
          <select class="select" id="${escapeHtml(configInputId(field.key))}" data-config-key="${escapeHtml(field.key)}">
            ${providers.map((provider) => {
              const providerId = normalizeProviderId(provider.id, providerRules());
              return `<option value="${escapeHtml(providerId)}"${providerId === value ? " selected" : ""}>${escapeHtml(provider.label || providerId)}</option>`;
            }).join("")}
          </select>
          <span class="config-comment">${escapeHtml(field.comment)}</span>
        </label>
      `;
    }
    if (field.type === "model") {
      const models = state.configModelsProvider === currentProviderId() ? state.configModels : [];
      const hasCurrent = models.some((model) => model.id === value);
      const modelOptions = /** @type {Array<Record<string, any>>} */ (
        value && !hasCurrent ? [{ id: value }] : []
      ).concat(models);
      const control = modelOptions.length
        ? `<select class="select" id="${escapeHtml(configInputId(field.key))}" data-config-key="${escapeHtml(field.key)}">
            ${modelOptions.map((model) => `<option value="${escapeHtml(model.id)}"${model.id === value ? " selected" : ""}>${escapeHtml(model.id)}</option>`).join("")}
          </select>`
        : `<input class="field" id="${escapeHtml(configInputId(field.key))}" data-config-key="${escapeHtml(field.key)}" type="text" value="${escapeHtml(value)}">`;
      return `
        <label class="small config-field-label" for="${escapeHtml(configInputId(field.key))}">
          <span>${escapeHtml(field.label)}</span>
          <div class="config-control-row">
            ${control}
            <button class="btn secondary compact-btn" type="button" data-config-model-fetch${remoteSecretTransmissionBlocked(state.configSnapshot) ? ' disabled title="请先允许远程传输 API Key"' : ""}>获取模型</button>
          </div>
          <span class="config-comment">${escapeHtml(state.configModelStatus || field.comment)}</span>
        </label>
      `;
    }
    return `
      <label class="small config-field-label" for="${escapeHtml(configInputId(field.key))}">
        <span>${escapeHtml(field.label)}</span>
        <input class="field" id="${escapeHtml(configInputId(field.key))}" data-config-key="${escapeHtml(field.key)}" type="${field.type === "number" ? "number" : field.type === "secret" ? "password" : "text"}" ${field.min !== undefined ? `min="${escapeHtml(field.min)}"` : ""} ${field.max !== undefined ? `max="${escapeHtml(field.max)}"` : ""} ${field.writeOnly ? 'autocomplete="new-password"' : ""} ${field.placeholder ? `placeholder="${escapeHtml(field.placeholder)}"` : ""} value="${escapeHtml(value)}">
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
      if (key === REMOTE_API_KEY_TRANSMISSION_KEY && next && state.configSnapshot?.remote?.enabled === true) {
        const confirmed = window.confirm("开启后，当前 remote runtime 可将 API Key 发送到配置的 AI Provider。密钥不会写入远程配置文件。确认开启？");
        if (!confirmed) return;
      }
      control.classList.toggle("on", next);
      control.setAttribute("aria-pressed", next ? "true" : "false");
      state.configDraft[key] = next;
    } else if (field.type === "number") {
      state.configDraft[key] = Number(control.value);
    } else if (field.type === "provider") {
      applyProviderPreset(control.value);
      return;
    } else {
      state.configDraft[key] = control.value;
    }
    setConfigDirtyState(hasConfigChanges());
  }

  function applyProviderPreset(providerId) {
    const normalized = normalizeProviderId(providerId, providerRules());
    const provider = findConfigProvider(normalized);
    state.configDraft.provider = normalized;
    if (provider) {
      state.configDraft.api_url = provider.api_url || "";
      if (provider.default_model) {
        state.configDraft.model = provider.default_model;
      } else if (!provider.api_url) {
        state.configDraft.model = "";
      }
    }
    state.configModels = [];
    state.configModelsProvider = "";
    state.configModelStatus = provider?.model_fetch_reason || "";
    renderConfigEditor(state.configSnapshot || {});
    setConfigDirtyState(hasConfigChanges());
    if (provider?.model_fetch_supported && state.configSnapshot?.api_key_configured) {
      window.setTimeout(() => app.safeAction(fetchConfigModels), 0);
    }
  }

  async function fetchConfigModels() {
    if (remoteSecretTransmissionBlocked(state.configSnapshot)) {
      showToast("请先在配置中心允许远程传输 API Key");
      return;
    }
    const provider = currentProviderId();
    const apiKeyControl = $(configInputId("api_key"));
    const body = {
      provider,
      api_url: state.configDraft.api_url || "",
    };
    if (apiKeyControl?.value) {
      body.api_key = apiKeyControl.value;
    }
    state.configModelStatus = "正在获取模型...";
    renderConfigEditor(state.configSnapshot || {});
    const data = await app.api("/api/config/models", { method: "POST", body });
    if (!data.ok) {
      state.configModels = [];
      state.configModelsProvider = "";
      state.configModelStatus = data.error || data.status || "模型获取失败";
      renderConfigEditor(state.configSnapshot || {});
      setConfigDirtyState(hasConfigChanges());
      showToast(state.configModelStatus);
      return;
    }
    state.configModels = Array.isArray(data.models) ? data.models.filter((model) => model?.id) : [];
    state.configModelsProvider = provider;
    state.configModelStatus = state.configModels.length ? `已获取 ${state.configModels.length} 个模型` : "该 key 未返回可选模型";
    if (!state.configDraft.model && state.configModels[0]?.id) {
      state.configDraft.model = state.configModels[0].id;
    }
    renderConfigEditor(state.configSnapshot || {});
    setConfigDirtyState(hasConfigChanges());
    showToast(state.configModelStatus);
  }

  function findConfigField(key) {
    for (const group of CONFIG_GROUPS) {
      const field = group.fields.find((candidate) => candidate.key === key);
      if (field) return field;
    }
    return null;
  }

  function hasConfigChanges() {
    return Object.keys(configDiff(state.configDraft, state.configOriginal)).length > 0;
  }

  function pendingConfigChanges(excludeKeys = new Set()) {
    return Object.entries(configDiff(state.configDraft, state.configOriginal, excludeKeys));
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
    const data = await app.api("/api/config/update", {
      method: "POST",
      body: { changes: Object.fromEntries(changes) },
    });
    if (!data.ok) {
      showToast(data.error || data.status || "保存配置失败");
      return;
    }
    await loadConfig();
    showToast("配置已保存");
  }

  function findConfigProvider(providerId) {
    const normalized = normalizeProviderId(providerId, providerRules());
    return state.configProviders.find((provider) => normalizeProviderId(provider.id, providerRules()) === normalized) || null;
  }

  function currentProviderId(config = state.configSnapshot || {}) {
    return normalizeProviderId(
      state.configDraft?.provider || config.provider_id || config.provider,
      providerRules(),
    );
  }

  function providerLabel(providerId) {
    const provider = findConfigProvider(providerId);
    return provider?.label || providerId || "provider";
  }


  return {
    loadConfig,
    loadConfigProviders,
    syncThinkingTraceFromConfig,
    updateThinkingTrace,
    toggleThinkingTraceFromWorkbench,
    toggleThinkingTraceFromConfig,
    renderConfigCenter,
    renderConfigRuntimeSummary,
    renderConfigEditor,
    configFieldValue,
    renderConfigField,
    renderReadonlyConfigField,
    updateConfigDraftFromControl,
    applyProviderPreset,
    fetchConfigModels,
    findConfigField,
    hasConfigChanges,
    pendingConfigChanges,
    restoreConfigDraftChanges,
    setConfigDirtyState,
    saveConfigChanges,
    findConfigProvider,
    currentProviderId,
    providerLabel,
  };
}
