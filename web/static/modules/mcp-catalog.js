/**
 * Pure presentation helpers for the MCP manifest table.
 *
 * Everything here relabels backend negotiation facts. The frontend never
 * negotiates and never treats a server's self-description as a security
 * guarantee; declared legacy-only transports are used only as compatibility
 * facts when an older backend snapshot lacks `protocol_family`.
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
  const family = String(server?.protocol_family || "").trim();
  const declaredMode = String(server?.protocol?.mode || "").trim();
  const declaredLegacy = declaredMode === "legacy_only" || server?.transport === "sse";
  if (family === "legacy" || server?.fallback_used === true || declaredLegacy) {
    const reason = String(server?.fallback_reason || "").trim();
    const detail = reason
      || (declaredMode === "legacy_only"
        ? "server 使用 manifest 声明的 legacy_only 协议。"
        : server?.transport === "sse"
          ? "SSE transport 使用 legacy 协议。"
          : "server 未提供回退原因。");
    return {
      state: "legacy",
      label: "legacy",
      detail,
      kind: "medium",
    };
  }
  const version = String(server?.protocol_version || "").trim();
  if (family === "modern" || version) {
    return { state: "modern", label: version || "modern", detail: "", kind: "low" };
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
