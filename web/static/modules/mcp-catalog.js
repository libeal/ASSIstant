/**
 * Pure presentation helpers for the MCP manifest table.
 *
 * Everything here relabels values the backend already decided. The frontend
 * never negotiates, never infers whether a session was modern, and never
 * treats a server's self-description as a security guarantee.
 */

/** @typedef {Record<string, any>} McpServerSummary */

/**
 * Negotiated protocol truth for one server.
 *
 * `contacted` is set by lib/mcp.sh only when a tools/list attempt actually
 * happened, so "not probed yet" stays distinguishable from "probed and got
 * nothing" — and a legacy fallback stays distinguishable from a modern
 * session, which is the whole point of manifest v2's protocol block.
 * @param {McpServerSummary|null} server
 * @returns {{state: string, label: string, detail: string, kind: string}}
 */
export function mcpProtocolPresentation(server) {
  if (server?.contacted !== true) {
    return {
      state: "unprobed",
      label: "未探测",
      detail: "尚未与该 server 协商；点击「加载工具」后才会得到协议版本。",
      kind: "",
    };
  }
  if (server?.fallback_used === true) {
    const reason = String(server?.fallback_reason || "").trim();
    return {
      state: "legacy",
      label: "legacy",
      detail: reason || "server 未提供回退原因。",
      kind: "medium",
    };
  }
  const version = String(server?.protocol_version || "").trim();
  if (version) {
    return { state: "modern", label: version, detail: "", kind: "low" };
  }
  return {
    state: "unreachable",
    label: "未协商",
    detail: "已尝试连接但没有取得协议版本。",
    kind: "medium",
  };
}

/**
 * Manifest-declared protocol constraints. Purely a declaration — it says what
 * the manifest permits, not what actually happened on the wire.
 * @param {McpServerSummary|null} server
 * @returns {string}
 */
export function mcpDeclaredProtocolLabel(server) {
  const protocol = server?.protocol;
  if (!protocol || typeof protocol !== "object") return "";
  const mode = String(protocol.mode || "").trim();
  if (!mode) return "";
  return protocol.require_modern === true ? `声明 ${mode} · require_modern` : `声明 ${mode}`;
}

/**
 * Credential binding, as a read-only summary. The manifest only ever stores a
 * profile id; the profile itself is Runner's private file and is never read,
 * so profile type and token status are deliberately absent until there is a
 * dedicated safe summary contract for them.
 * @param {McpServerSummary|null} server
 * @returns {{bound: boolean, label: string, profileId: string}}
 */
export function mcpCredentialPresentation(server) {
  const profileId = String(server?.credential_profile_id || "").trim();
  if (server?.credential_bound === true && profileId) {
    return { bound: true, label: `credential: ${profileId}`, profileId };
  }
  return { bound: false, label: "credential: 未绑定", profileId: "" };
}

/**
 * @param {McpServerSummary|null} server
 * @returns {string}
 */
export function mcpManifestVersionLabel(server) {
  const version = Number(server?.manifest_version);
  return Number.isFinite(version) && version > 0 ? `v${version}` : "";
}
