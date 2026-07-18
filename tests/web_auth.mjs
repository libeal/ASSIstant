import assert from "node:assert/strict";

import { consumeBootstrapFromLocation } from "../web/static/modules/auth.js";

const historyCalls = [];
const location = {
  pathname: "/",
  search: "?view=workbench",
  hash: "#bootstrap=one-time-value&view=workbench",
};
const bootstrap = consumeBootstrapFromLocation(location, {
  replaceState: (...args) => historyCalls.push(args),
});

assert.equal(bootstrap, "one-time-value");
assert.deepEqual(historyCalls, [[null, "", "/?view=workbench#view=workbench"]]);

const untouched = { pathname: "/", search: "", hash: "#screen=workbench" };
assert.equal(
  consumeBootstrapFromLocation(untouched, { replaceState: () => assert.fail("must not replace") }),
  "",
);

console.log("web_auth: ok");
