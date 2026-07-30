import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const databaseViewSource = await readFile(
  new URL("../skills/database-inspect/assets/web/view-database.js", import.meta.url),
  "utf8",
);
const { createDatabaseView } = await import(
  `data:text/javascript;base64,${Buffer.from(databaseViewSource).toString("base64")}`
);

class FakeElement {
  constructor(value = "") {
    this.value = value;
    this.checked = false;
    this.disabled = false;
    this.hidden = false;
    this.children = [];
    this.textContent = "";
  }

  appendChild(child) {
    this.children.push(child);
    return child;
  }

  set innerHTML(_value) {
    this.children = [];
  }

  get innerHTML() {
    return "";
  }
}

class FakeInput extends FakeElement {}
class FakeSelect extends FakeElement {}
class FakeButton extends FakeElement {}

globalThis.HTMLElement = FakeElement;
globalThis.HTMLInputElement = FakeInput;
globalThis.HTMLSelectElement = FakeSelect;
globalThis.HTMLButtonElement = FakeButton;
globalThis.Option = class {
  constructor(text, value) {
    this.text = text;
    this.value = value;
  }
};
globalThis.document = {
  createElement() { return new FakeElement(); },
  querySelectorAll() { return []; },
};

const controls = {
  databaseProfileSelect: new FakeSelect("primary"),
  databaseCredentialSelect: new FakeSelect("credential-primary"),
  databaseCredentialList: new FakeElement(),
  databaseCredentialCount: new FakeElement(),
  databaseUseStored: new FakeInput(),
  databaseCredentialSaveBtn: new FakeButton(),
  databaseHealthBtn: new FakeButton(),
  databaseMetricsBtn: new FakeButton(),
  databaseCancelBtn: new FakeButton(),
};
const state = {
  databaseMode: "managed",
  databaseProfiles: [
    { id: "primary", credential_mode: "stored_or_temporary" },
    { id: "analytics", credential_mode: "stored_or_temporary" },
  ],
  databaseCredentials: [
    { credential_ref: "credential-primary", mode: "managed", profile_id: "primary" },
    { credential_ref: "credential-analytics", mode: "managed", profile_id: "analytics" },
  ],
  databaseCredentialRef: "credential-primary",
  activeDatabaseJobId: "",
  databaseJobSubmitting: false,
};
const toasts = [];
let createJobCalls = 0;
let resolveCreateJob;
const createJobResult = new Promise((resolve) => { resolveCreateJob = resolve; });
const app = {
  state,
  $(id) { return controls[id] || null; },
  emptyItem(message) { return { message }; },
  escapeHtml: String,
  setText(id, text) { if (controls[id]) controls[id].textContent = text; },
  showToast(message) { toasts.push(message); },
  printOutput() {},
  createJob() {
    createJobCalls += 1;
    return createJobResult;
  },
  async pollJob() { throw new Error("pollJob must not run for a rejected Job"); },
};
const view = createDatabaseView(app);

controls.databaseProfileSelect.value = "analytics";
view.databaseProfileChanged();
assert.equal(state.databaseCredentialRef, "");
assert.equal(controls.databaseCredentialSelect.value, "");
assert.deepEqual(
  controls.databaseCredentialSelect.children.map((option) => option.value),
  ["", "credential-analytics"],
);

const firstRun = view.runDatabaseInspect("health");
const secondRun = view.runDatabaseInspect("metrics");
assert.equal(createJobCalls, 1);
assert.equal(controls.databaseHealthBtn.disabled, true);
assert.equal(controls.databaseMetricsBtn.disabled, true);
assert.match(toasts.at(-1), /正在运行/);

resolveCreateJob({ ok: false, status: "rejected" });
await Promise.all([firstRun, secondRun]);
assert.equal(state.databaseJobSubmitting, false);
assert.equal(controls.databaseHealthBtn.disabled, false);
assert.equal(controls.databaseMetricsBtn.disabled, false);
assert.equal(controls.databaseCancelBtn.disabled, true);

console.log("web_database_view: ok");
