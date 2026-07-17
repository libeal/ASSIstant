/** @returns {Record<string, any>} */
export function createInitialState() {
  return {
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
    mcpServers: [],
    mcpTools: [],
    mcpFindings: [],
    mcpRoot: "",
    activeWorkJobId: "",
    activeScriptJobId: "",
    activeTerminalJobId: "",
    workSubmitting: false,
    workApprovalSubmitting: false,
    terminalSubmitting: false,
    selectedStepIndex: -1,
    selectedTurnId: "",
    selectedStepKey: "",
    approvalDrawerOpen: false,
    pendingApproval: null,
    lastProtocolResult: null,
    sessionTurns: [],
    sessionInfo: null,
    restoredAuditSessionId: "",
    lastThinkingSummary: "",
    workSuspended: false,
    auditSessions: [],
    auditEvents: [],
    auditWebTimeline: null,
    auditTimelineUnavailableReason: "",
    currentAuditSession: "",
    configSnapshot: null,
    commandGuardEnabled: true,
    configOriginal: {},
    configDraft: {},
    configProviders: [],
    configModels: [],
    configModelsProvider: "",
    configModelStatus: "",
    domainSchema: null,
    observerBootstrap: null,
    observerBootstrapPrompted: false,
    auditPaused: false,
    draggedPanelId: "",
    webRunId: "",
    layoutStorageKey: "",
    defaultLayout: { containers: {}, children: {} },
  };
}

/**
 * Create a shallow observable store for modules that do not need a reducer.
 * @param {Record<string, any>} initialState
 * @returns {{get: () => Record<string, any>, set: (patch: object|Function) => Record<string, any>, subscribe: (listener: Function) => Function}}
 */
export function createStore(initialState = {}) {
  let value = { ...initialState };
  const listeners = new Set();

  return {
    get() {
      return value;
    },
    set(patch) {
      const nextPatch = typeof patch === "function" ? patch(value) : patch;
      if (!nextPatch || typeof nextPatch !== "object" || Array.isArray(nextPatch)) {
        throw new TypeError("store patch must be an object or updater function");
      }
      const previous = value;
      value = { ...value, ...nextPatch };
      for (const listener of listeners) listener(value, previous);
      return value;
    },
    subscribe(listener) {
      if (typeof listener !== "function") throw new TypeError("store listener must be a function");
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
  };
}
