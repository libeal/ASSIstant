import assert from "node:assert/strict";

import { createStore } from "../web/static/modules/store.js";

const store = createStore({ count: 1, label: "initial" });
const notifications = [];
const unsubscribe = store.subscribe((next, previous) => {
  notifications.push({ next, previous });
});

const first = store.set({ count: 2 });
assert.deepEqual(first, { count: 2, label: "initial" });
assert.deepEqual(store.get(), first);
assert.equal(notifications.length, 1);
assert.deepEqual(notifications[0].previous, { count: 1, label: "initial" });
assert.deepEqual(notifications[0].next, { count: 2, label: "initial" });

store.set((current) => ({ count: current.count + 3, label: "updated" }));
assert.deepEqual(store.get(), { count: 5, label: "updated" });
assert.equal(notifications.length, 2);

unsubscribe();
store.set({ count: 6 });
assert.equal(notifications.length, 2);
assert.throws(() => store.set(null), /store patch/);
assert.throws(() => store.subscribe("listener"), /store listener/);

console.log("web_store: ok");
