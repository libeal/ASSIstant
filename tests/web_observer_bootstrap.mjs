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
    observerAuditPassword: {
      value: "",
      focus() {},
    },
    observerAuditOutput: { textContent: "" },
  };
  const app = {
    state: { token: "web-token", observerBootstrap: null },
    request: async () => ({}),
    api: async (...args) => {
      apiCalls.push(args);
      return { ok: true, status: "enabled", method: "sudo" };
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
    method: "sudo",
    requires_permission: true,
  };

  assert.equal(view.observerHelperNeedsRepair(pending), false);
  view.openObserverAuditDialog(pending);
  assert.equal(harness.elements.observerAuditDialog.open, true);
}

console.log("web_observer_bootstrap: ok");
