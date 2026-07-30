/** @typedef {import("/modules/types.js").AppContext} AppContext */
/** @typedef {Record<string, Function>} DatabaseView */

/** @param {AppContext} app @returns {DatabaseView} */
export function createDatabaseView(app) {
  const state = app.state;
  const $ = app.$;

  const value = (id) => {
    const control = $(id);
    return control instanceof HTMLInputElement || control instanceof HTMLSelectElement
      ? control.value.trim()
      : "";
  };

  const checked = (id) => $(id) instanceof HTMLInputElement && $(id).checked;

  function remoteMode() {
    return state.databaseMode === "remote";
  }

  function selectedProfile() {
    const id = value("databaseProfileSelect");
    return state.databaseProfiles.find((profile) => profile.id === id) || null;
  }

  function credentialMatchesSelectedProfile(credential) {
    if (remoteMode()) return credential.mode === "remote";
    const profileId = selectedProfile()?.id || "";
    return credential.mode === "managed" && credential.profile_id === profileId;
  }

  function syncDatabaseJobControls() {
    const busy = state.databaseJobSubmitting || Boolean(state.activeDatabaseJobId);
    for (const id of ["databaseHealthBtn", "databaseMetricsBtn"]) {
      const button = $(id);
      if (button instanceof HTMLButtonElement) button.disabled = busy;
    }
    const cancel = $("databaseCancelBtn");
    if (cancel instanceof HTMLButtonElement) cancel.disabled = !state.activeDatabaseJobId;
  }

  function syncProfileControls() {
    const profile = selectedProfile();
    const stored = $("databaseUseStored");
    const save = $("databaseCredentialSaveBtn");
    const supportsStored = ["stored", "stored_or_temporary"].includes(profile?.credential_mode || "");
    const supportsTemporary = ["temporary", "stored_or_temporary"].includes(profile?.credential_mode || "");
    if (stored instanceof HTMLInputElement) {
      stored.disabled = !supportsStored;
      if (!supportsStored) stored.checked = false;
      if (profile?.credential_mode === "stored") stored.checked = true;
    }
    if (save instanceof HTMLButtonElement) save.disabled = !remoteMode() && !supportsTemporary;
  }

  function syncTransportControls() {
    const socket = value("databaseTransport") === "socket";
    document.querySelectorAll(".database-tcp-field").forEach((element) => {
      if (element instanceof HTMLElement) element.hidden = socket;
    });
    document.querySelectorAll(".database-socket-field").forEach((element) => {
      if (element instanceof HTMLElement) element.hidden = !socket;
    });
  }

  function renderProfiles() {
    const select = $("databaseProfileSelect");
    const list = $("databaseProfileList");
    if (!(select instanceof HTMLSelectElement) || !list) return;
    const previous = select.value;
    select.innerHTML = "";
    if (!state.databaseProfiles.length) {
      select.appendChild(new Option("无已登记 profile", ""));
    } else {
      for (const profile of state.databaseProfiles) {
        const location = profile.socket || `${profile.endpoint}:${profile.port}`;
        select.appendChild(new Option(`${profile.id} · ${profile.engine} · ${location}`, profile.id));
      }
      if (state.databaseProfiles.some((profile) => profile.id === previous)) select.value = previous;
    }
    list.innerHTML = "";
    for (const profile of state.databaseProfiles) {
      const item = document.createElement("div");
      item.className = "item";
      const location = profile.socket || `${profile.endpoint}:${profile.port}`;
      item.innerHTML = `<div class="item-head"><h4>${app.escapeHtml(profile.id)}</h4><span class="pill">${app.escapeHtml(profile.engine)}</span></div><p class="mono">${app.escapeHtml(location)}</p><p>${app.escapeHtml(profile.database)} · ${app.escapeHtml(profile.tls)} · ${app.escapeHtml(profile.credential_mode)}</p>`;
      list.appendChild(item);
    }
    if (!state.databaseProfiles.length) list.appendChild(app.emptyItem(remoteMode() ? "Remote 模式使用临时 endpoint。" : "暂无已登记 profile。"));
    syncProfileControls();
  }

  function renderCredentials() {
    const select = $("databaseCredentialSelect");
    const list = $("databaseCredentialList");
    if (!(select instanceof HTMLSelectElement) || !list) return;
    const previous = state.databaseCredentialRef || select.value;
    select.innerHTML = "";
    select.appendChild(new Option("未选择", ""));
    list.innerHTML = "";
    const selectableCredentials = state.databaseCredentials.filter(credentialMatchesSelectedProfile);
    for (const credential of state.databaseCredentials) {
      const reference = String(credential.credential_ref || "");
      const label = `${credential.profile_id || credential.engine || "database"} · ${credential.username_hint || "user"} · ${reference.slice(0, 8)}`;
      if (selectableCredentials.includes(credential)) select.appendChild(new Option(label, reference));
      const item = document.createElement("div");
      item.className = "item";
      item.innerHTML = `<div class="item-head"><h4>${app.escapeHtml(credential.profile_id || credential.engine || "database")}</h4><span class="pill">${app.escapeHtml(credential.mode || "temporary")}</span></div><p>${app.escapeHtml(credential.username_hint || "user")} · <span class="mono">${app.escapeHtml(reference.slice(0, 8))}</span></p>`;
      list.appendChild(item);
    }
    if (selectableCredentials.some((credential) => credential.credential_ref === previous)) {
      select.value = previous;
      state.databaseCredentialRef = previous;
    } else {
      select.value = "";
      state.databaseCredentialRef = "";
    }
    if (!state.databaseCredentials.length) list.appendChild(app.emptyItem("暂无临时凭据。"));
    app.setText("databaseCredentialCount", `${state.databaseCredentials.length} / 8`);
  }

  async function loadDatabaseCredentials() {
    const result = await app.api("/api/database/credentials");
    state.databaseCredentials = Array.isArray(result.credentials) ? result.credentials : [];
    renderCredentials();
    return result;
  }

  async function loadDatabase() {
    const result = await app.api("/api/database/profiles");
    state.databaseMode = result.mode || (state.configSnapshot?.remote?.enabled ? "remote" : "managed");
    state.databaseProfiles = Array.isArray(result.profiles) ? result.profiles : [];
    app.setStatus("databaseMode", state.databaseMode, result.ok ? "ok" : "failed");
    const managed = $("databaseManagedFields");
    const remote = $("databaseRemoteFields");
    if (managed) managed.hidden = remoteMode();
    if (remote) remote.hidden = !remoteMode();
    renderProfiles();
    await loadDatabaseCredentials();
    if (!result.ok) app.printOutput("databaseOutput", result);
    return result;
  }

  async function saveDatabaseCredential() {
    let body;
    const passwordControl = $(remoteMode() ? "databaseRemotePassword" : "databasePassword");
    try {
      if (remoteMode()) {
        const socket = value("databaseTransport") === "socket";
        body = {
          engine: value("databaseEngine"),
          database: value("databaseName"),
          tls: socket ? "disable" : value("databaseTls"),
          username: value("databaseRemoteUsername"),
          password: value("databaseRemotePassword"),
          acknowledge_authorized_scope: checked("databaseScopeAck"),
        };
        if (socket) {
          body.socket = value("databaseSocket");
        } else {
          body.endpoint = value("databaseEndpoint");
          body.port = Number(value("databasePort"));
        }
      } else {
        body = {
          profile_id: value("databaseProfileSelect"),
          username: value("databaseUsername"),
          password: value("databasePassword"),
        };
      }
      const result = await app.api("/api/database/credentials", { method: "POST", body });
      if (!result.ok) {
        app.printOutput("databaseOutput", result);
        throw new Error(result.error || result.message || result.status);
      }
      state.databaseCredentialRef = result.credential_ref || "";
      await loadDatabaseCredentials();
      app.showToast("临时凭据已保存");
    } finally {
      if (passwordControl instanceof HTMLInputElement) passwordControl.value = "";
    }
  }

  async function clearDatabaseCredentials() {
    const result = await app.api("/api/database/credentials/clear", { method: "POST", body: {} });
    state.databaseCredentialRef = "";
    await loadDatabaseCredentials();
    app.printOutput("databaseOutput", result);
  }

  async function runDatabaseInspect(action) {
    if (state.databaseJobSubmitting || state.activeDatabaseJobId) {
      app.showToast("已有数据库巡检正在运行");
      return;
    }
    state.databaseJobSubmitting = true;
    syncDatabaseJobControls();
    let jobId = "";
    try {
      const profileId = remoteMode() ? "" : value("databaseProfileSelect");
      const useStored = !remoteMode() && checked("databaseUseStored");
      const credentialRef = useStored ? "" : value("databaseCredentialSelect");
      const job = await app.createJob("database", action, {
        profile_id: profileId,
        credential_ref: credentialRef,
      });
      if (!job.ok || !job.job_id) {
        app.printOutput("databaseOutput", job);
        return;
      }
      jobId = job.job_id;
      state.activeDatabaseJobId = jobId;
      state.databaseJobSubmitting = false;
      syncDatabaseJobControls();
      const completed = await app.pollJob(jobId, "databaseJobStatus", "databaseOutput");
      app.printOutput("databaseOutput", completed.result || completed);
    } finally {
      if (!jobId || state.activeDatabaseJobId === jobId) state.activeDatabaseJobId = "";
      state.databaseJobSubmitting = false;
      syncDatabaseJobControls();
      if (jobId) await loadDatabaseCredentials();
    }
  }

  async function cancelDatabaseInspect() {
    if (!state.activeDatabaseJobId) return;
    const result = await app.cancelJob(state.activeDatabaseJobId);
    app.printOutput("databaseOutput", result);
  }

  function databaseProfileChanged() {
    renderCredentials();
    syncProfileControls();
  }

  function databaseCredentialChanged() {
    state.databaseCredentialRef = value("databaseCredentialSelect");
  }

  function databaseEngineChanged() {
    const port = $("databasePort");
    if (port instanceof HTMLInputElement) port.value = value("databaseEngine") === "postgresql" ? "5432" : "3306";
  }

  return {
    loadDatabase,
    loadDatabaseCredentials,
    saveDatabaseCredential,
    clearDatabaseCredentials,
    runDatabaseInspect,
    cancelDatabaseInspect,
    databaseProfileChanged,
    databaseCredentialChanged,
    databaseEngineChanged,
    syncTransportControls,
  };
}

/** Register the package-owned view and its DOM bindings. */
export function registerSkillWebComponent(app) {
  Object.assign(app.state, {
    databaseMode: "managed",
    databaseProfiles: [],
    databaseCredentials: [],
    databaseCredentialRef: "",
    activeDatabaseJobId: "",
    databaseJobSubmitting: false,
  });
  Object.assign(app, createDatabaseView(app));
  const safe = (function_) => app.safeAction(function_);
  app.on("databaseReloadBtn", "click", () => safe(app.loadDatabase));
  app.on("databaseCredentialSaveBtn", "click", () => safe(app.saveDatabaseCredential));
  app.on("databaseCredentialClearBtn", "click", () => safe(app.clearDatabaseCredentials));
  app.on("databaseHealthBtn", "click", () => safe(() => app.runDatabaseInspect("health")));
  app.on("databaseMetricsBtn", "click", () => safe(() => app.runDatabaseInspect("metrics")));
  app.on("databaseCancelBtn", "click", () => safe(app.cancelDatabaseInspect));
  app.on("databaseProfileSelect", "change", app.databaseProfileChanged);
  app.on("databaseCredentialSelect", "change", app.databaseCredentialChanged);
  app.on("databaseTransport", "change", app.syncTransportControls);
  app.on("databaseEngine", "change", app.databaseEngineChanged);
  return { onConnect: app.loadDatabase };
}
