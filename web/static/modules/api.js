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
    throw new Error(data.error || data.status || `HTTP ${response.status}`);
  }
  return data;
}
