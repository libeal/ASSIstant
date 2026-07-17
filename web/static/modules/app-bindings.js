import { $, on } from "./dom.js";
import { THINKING_TRACE_KEY } from "./constants.js";
import { configInputId } from "./config-utils.js";

/**
 * Wire DOM event handlers. Handlers live on the shared app bag.
 * @param {any} app
 * @param {{ safeAction: Function, showScreen: Function, connect: Function, shutdownServer: Function, state: Record<string, any> }} shell
 * @returns {void}
 */
export function bindApplicationEvents(app, shell) {
  const { safeAction, showScreen, connect, shutdownServer, state } = shell;

  /** @param {string} id @returns {string} */
  const controlValue = (id) => {
    const control = $(id);
    return control instanceof HTMLInputElement
      || control instanceof HTMLTextAreaElement
      || control instanceof HTMLSelectElement
      ? control.value
      : "";
  };

  // Navigation
    $("nav")?.addEventListener("click", (event) => {
      const target = event.target instanceof Element ? event.target : null;
      const button = target?.closest("button[data-screen]");
      if (!button) return;
      if (button instanceof HTMLElement) showScreen(button.dataset.screen);
    });

  // Mode tabs
    $("workTabs")?.addEventListener("click", (event) => {
      const target = event.target instanceof Element ? event.target : null;
      const button = target?.closest("button[data-work-mode]");
      if (!button) return;
      document.querySelectorAll("[data-work-mode]").forEach((el) => {
        el.classList.toggle("active", el === button);
        el.classList.toggle("secondary", el !== button);
      });
      const workModePanel = $("workModePanel");
      const terminalModePanel = $("terminalModePanel");
      if (workModePanel && button instanceof HTMLElement) workModePanel.hidden = button.dataset.workMode !== "work";
      if (terminalModePanel && button instanceof HTMLElement) terminalModePanel.hidden = button.dataset.workMode !== "terminal";
    });

    $("skillTabs")?.addEventListener("click", (event) => {
      const target = event.target instanceof Element ? event.target : null;
      const button = target?.closest("button[data-skill-mode]");
      if (!button) return;
      document.querySelectorAll("[data-skill-mode]").forEach((el) => {
        el.classList.toggle("active", el === button);
        el.classList.toggle("secondary", el !== button);
      });
      const scriptPanel = $("scriptPanel");
      const editPanel = $("editPanel");
      if (scriptPanel && button instanceof HTMLElement) scriptPanel.hidden = button.dataset.skillMode !== "script";
      if (editPanel && button instanceof HTMLElement) editPanel.hidden = button.dataset.skillMode !== "edit";
    });

  // Switches
    document.querySelectorAll(".switch").forEach((button) => {
      if (button.id === "thinkingTraceSwitch" || button.id === configInputId(THINKING_TRACE_KEY)) return;
      button.addEventListener("click", () => button.classList.toggle("on"));
    });

  // Actions
    on("tokenForm", "submit", async (event) => {
      event.preventDefault();
      await safeAction(connect);
    });
    on("shutdownServerBtn", "click", () => safeAction(shutdownServer));
    on("observerAuditBtn", "click", () => safeAction(async () => app.openObserverAuditDialog(await app.loadObserverBootstrapStatus())));
    on("observerAuditEnableBtn", "click", () => safeAction(app.enableObserverAudit));
    on("observerAuditSkipBtn", "click", () => safeAction(app.skipObserverAudit));
    on("observerAuditDialog", "cancel", (event) => event.preventDefault());
    on("workRunBtn", "click", () => safeAction(app.runWork));
    on("workCancelBtn", "click", () => safeAction(app.cancelWork));
    on("workSuspendBtn", "click", app.suspendWork);
    on("sessionLeaveBtn", "click", () => safeAction(app.leaveWorkbenchSession));
    on("senseRefreshBtn", "click", () => safeAction(() => app.loadSense()));
    on("approvalApproveBtn", "click", () => safeAction(() => app.submitApprovalDecision("y")));
    on("approvalRejectBtn", "click", () => safeAction(() => app.submitApprovalDecision("n")));
    on("approvalSkipBtn", "click", () => safeAction(() => app.submitApprovalDecision("s")));
    on("approvalTerminateBtn", "click", () => safeAction(() => app.submitApprovalDecision("t")));
    on("terminalRunBtn", "click", () => safeAction(app.runTerminal));
    on("scriptReviewBtn", "click", () => safeAction(app.reviewScript));
    on("scriptRunBtn", "click", () => safeAction(app.runScript));
    on("scriptCancelBtn", "click", () => safeAction(app.cancelScript));
    on("skillsValidateBtn", "click", () => safeAction(app.validateSkills));
    on("mcpReloadBtn", "click", () => safeAction(app.loadMcpRegistry));
    on("mcpToolsBtn", "click", () => safeAction(app.loadMcpTools));
    on("mcpValidateBtn", "click", () => safeAction(app.validateMcp));
    on("newSkillBtn", "click", app.startNewSkill);
    on("editPlanBtn", "click", () => safeAction(app.planEdit));
    on("editReviewBtn", "click", () => safeAction(app.reviewEdit));
    on("editApplyBtn", "click", () => safeAction(app.applyEdit));
    on("auditRefreshBtn", "click", () => safeAction(app.loadAuditList));
    on("auditRestoreTimelineBtn", "click", () => safeAction(app.restoreAuditTimelineToWorkbench));
    on("auditSessionFilter", "input", app.scheduleAuditListReload);
    on("auditStatusFilter", "change", app.renderAuditSessionList);
    on("auditEventFilter", "change", () => state.currentAuditSession ? app.renderAuditEventTimeline() : app.renderAuditSessionList());
    on("auditLimitInput", "input", () => state.currentAuditSession ? app.renderAuditEventTimeline() : app.scheduleAuditListReload());
    on("configReloadBtn", "click", () => safeAction(app.loadConfig));
    on("configSaveBtn", "click", () => safeAction(app.saveConfigChanges));
    on("configEditorRoot", "input", (event) => app.updateConfigDraftFromControl(event.target));
    on("configEditorRoot", "change", (event) => app.updateConfigDraftFromControl(event.target));
    on("configEditorRoot", "click", (event) => {
      const modelFetchButton = event.target.closest("[data-config-model-fetch]");
      if (modelFetchButton) {
        safeAction(app.fetchConfigModels);
        return;
      }
      const button = event.target.closest(".config-switch");
      if (!button) return;
      if (button.dataset.configKey === THINKING_TRACE_KEY) {
        safeAction(() => app.toggleThinkingTraceFromConfig(button));
        return;
      }
      app.updateConfigDraftFromControl(button);
    });
    on("doctorRunBtn", "click", () => safeAction(app.runDoctor));
    on("policyUnlockBtn", "click", () => safeAction(app.unlockPolicy));
    on("policyLockBtn", "click", app.lockPolicy);
    on("policyReloadBtn", "click", () => safeAction(app.loadPolicies));
    on("policyValidateBtn", "click", () => safeAction(app.validatePolicy));
    on("policySaveBtn", "click", () => safeAction(app.savePolicy));
    on("policyInspectBtn", "click", () => safeAction(() => app.openPolicyFile(controlValue("policyFileSelect"))));
    on("policyDialogValidateBtn", "click", () => safeAction(app.validatePolicy));
    on("policyFileDialogClose", "click", app.closePolicyFileDialog);
    on("policyFileDialog", "cancel", (event) => {
      event.preventDefault();
      app.closePolicyFileDialog();
    });
    on("policyGuardToggleBtn", "click", () => safeAction(app.toggleCommandGuard));
    on("policyFileSelect", "change", (event) => safeAction(() => app.readPolicy(event.target.value)));
    on("policyAddRuleBtn", "click", () => safeAction(() => app.openPolicyFile("risk-rules.json")));
    on("policyEditBoundaryBtn", "click", () => safeAction(() => app.openPolicyFile("audit-boundaries.json")));
    on("policyEditVaultBtn", "click", () => safeAction(() => app.openPolicyFile("file-vault.json")));
    on("thinkingTraceSwitch", "click", () => safeAction(app.toggleThinkingTraceFromWorkbench));
    on("auditExportBtn", "click", app.exportAuditReport);
    on("runtimeBackupBtn", "click", () => safeAction(app.downloadRuntimeBackup));
    on("auditPauseBtn", "click", app.toggleAuditPause);
    on("auditFindFailureBtn", "click", app.findAuditFailure);
    on("editInput", "input", app.markEditDirty);
    on("workInput", "keydown", (event) => {
      if (event.key !== "Enter" || event.shiftKey || event.isComposing) return;
      event.preventDefault();
      safeAction(app.runWork);
    });
    on("terminalCommand", "keydown", (event) => {
      if (event.key !== "Enter" || event.shiftKey || event.isComposing) return;
      event.preventDefault();
      safeAction(app.runTerminal);
    });

    window.addEventListener("keydown", (event) => {
      if (event.altKey || event.metaKey || event.ctrlKey) return;
      if (["INPUT", "TEXTAREA", "SELECT"].includes(document.activeElement?.tagName || "")) return;
      const map = { "1": "workbench", "2": "skills", "3": "mcp", "4": "policy", "5": "audit", "6": "config" };
      if (map[event.key]) showScreen(map[event.key]);
    });
}
