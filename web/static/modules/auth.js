/**
 * Read and consume the one-time bootstrap value passed by the local launcher.
 * The value lives in the URL fragment so it is never sent in an HTTP request.
 * @param {Location} [location]
 * @param {{replaceState: Function}} [history]
 * @returns {string}
 */
export function consumeBootstrapFromLocation(
  location = window.location,
  history = window.history,
) {
  const rawHash = String(location.hash || "");
  if (!rawHash.startsWith("#")) return "";
  const params = new URLSearchParams(rawHash.slice(1));
  const bootstrap = String(params.get("bootstrap") || "").trim();
  if (!bootstrap) return "";

  params.delete("bootstrap");
  const nextHash = params.toString() ? `#${params.toString()}` : "";
  history.replaceState(null, "", `${location.pathname}${location.search}${nextHash}`);
  return bootstrap;
}

