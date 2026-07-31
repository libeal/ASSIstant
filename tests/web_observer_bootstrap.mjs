#!/usr/bin/env node

import assert from "node:assert/strict";
import { createObserverBootstrap } from "../web/static/modules/observer-bootstrap.js";

function createHarness() {
  const toasts = [];
  const apiCalls = [];
  const elements = {
    observerAuditBtn: { className: "", title: "" },
    observerAuditDialog: {
      open: false,
      showModal() { this.open = true; },
      close() { this.open = false; },
      removeAttribute() { this.open = false; },
    },
    observerAuditOutput: { textContent: "" },
    observerAuditDescription: { textContent: "" },
    observerAuditPasswordField: { hidden: true },
    observerAuditPassword: {
      value: "",
      disabled: true,
      focused: false,
      focus() { this.focused = true; },
    },
  };
  const app = {
    state: { token: "web-token", observerBootstrap: null },
    request: async () => ({}),
    api: async (...args) => {
      apiCalls.push(args);
      return { ok: true, status: "enabled", method: "helper" };
    },
    $: (id) => elements[id] || null,
    on() {},
    setText() {},
    setStatus() {},
    setSwitch() {},
    showToast: (message) => toasts.push(message),
    pretty: (value) => JSON.stringify(value),
  };
  return { app, apiCalls, elements, toasts };
}

{
  const harness = createHarness();
  const view = createObserverBootstrap(harness.app);
  const failure = {
    ok: false,
    status: "observer_helper_failed",
    method: "helper",
    error: "permission denied for socket; run repair-observer",
    diagnostic: "helper failure does not fall back to sudo",
    requires_permission: false,
  };

  assert.equal(view.observerHelperNeedsRepair(failure), true);
  view.openObserverAuditDialog(failure);
  assert.equal(harness.elements.observerAuditDialog.open, false);
  assert.deepEqual(harness.toasts, [failure.error]);

  harness.app.state.observerBootstrap = failure;
  await view.enableObserverAudit();
  assert.equal(harness.apiCalls.length, 0);
  assert.equal(harness.elements.observerAuditDialog.open, false);
  assert.deepEqual(harness.toasts, [failure.error, failure.error]);
}

{
  const harness = createHarness();
  const view = createObserverBootstrap(harness.app);
  const pending = {
    ok: false,
    status: "sudo_required",
    method: "none",
    requires_permission: true,
    password_allowed: true,
    authorization_mode: "sudo_interactive",
  };

  assert.equal(view.observerHelperNeedsRepair(pending), false);
  view.openObserverAuditDialog(pending);
  assert.equal(harness.elements.observerAuditDialog.open, true);
  assert.equal(harness.elements.observerAuditPasswordField.hidden, false);
  assert.equal(harness.elements.observerAuditPassword.disabled, false);
  assert.equal(harness.elements.observerAuditPassword.focused, true);
}

{
  const harness = createHarness();
  const view = createObserverBootstrap(harness.app);
  harness.app.state.observerBootstrap = {
    ok: true,
    status: "pending",
    method: "helper",
    requires_permission: true,
    password_allowed: false,
    authorization_mode: "helper",
  };
  harness.elements.observerAuditPassword.value = "must-not-be-sent";

  await view.enableObserverAudit();
  assert.equal(harness.apiCalls.length, 1);
  assert.equal(harness.apiCalls[0][0], "/api/observer/bootstrap");
  assert.deepEqual(harness.apiCalls[0][1], {
    method: "POST",
    body: { action: "enable" },
  });
  assert.equal("password" in harness.apiCalls[0][1].body, false);
  assert.equal(harness.elements.observerAuditPassword.value, "");
  assert.equal(harness.elements.observerAuditPasswordField.hidden, true);
}

{
  const harness = createHarness();
  const view = createObserverBootstrap(harness.app);
  harness.app.state.observerBootstrap = {
    ok: false,
    status: "sudo_required",
    method: "sudo_helper",
    requires_permission: true,
    password_allowed: true,
    authorization_mode: "sudo_interactive",
  };
  harness.elements.observerAuditPassword.value = "source-password";

  await view.enableObserverAudit();

  assert.deepEqual(harness.apiCalls[0][1], {
    method: "POST",
    body: { action: "enable", password: "source-password" },
  });
  assert.equal(harness.elements.observerAuditPassword.value, "");
}

console.log("web_observer_bootstrap: ok");
