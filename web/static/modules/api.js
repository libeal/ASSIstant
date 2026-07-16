export async function requestJson(path, options = {}, getToken = () => "") {
  const init = {
    method: options.method || "GET",
    headers: {
      "Authorization": `Bearer ${getToken()}`,
      "Content-Type": "application/json",
    },
  };
  if (options.body !== undefined) init.body = JSON.stringify(options.body);
  const response = await fetch(path, init);
  const data = await response.json().catch(() => ({ ok: false, status: "invalid_json" }));
  if (!response.ok) {
    // Domain failures deliberately use their schema-defined HTTP status while
    // still returning a structured payload for the workbench to render. Only
    // throw when the peer did not provide that contract (for example a proxy
    // error page or a malformed response).
    if (data && data.ok === false) return data;
    throw new Error(data.error || data.status || `HTTP ${response.status}`);
  }
  return data;
}
