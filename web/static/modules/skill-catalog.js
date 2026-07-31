/**
 * Pure presentation helpers for the Skill catalog table.
 *
 * These functions only relabel what `/api/tools` already decided. They never
 * infer risk, never infer whether a step will really run behind a privileged
 * helper, and never derive isolation state — the package's declared execution
 * class is not the same thing as the runtime identity reported by
 * `/api/health` → `execution.isolation`.
 */

/** @typedef {{execution_class?: string, capability?: string, origin?: string, materialization?: string, skill?: string, category?: string, risk?: string, approval_scope?: string, guards?: Array<Record<string, any>>, package_version?: string, core_api?: number, ref?: string, description?: string}} CatalogTool */

/**
 * Package-declared execution class. `host_helper` is reserved for the built-in
 * firewall/hosts capabilities and gets its own pill so it never reads as a
 * plain runner script — and never reuses the `risk high` styling, because this
 * is a capability statement, not a risk verdict.
 * @param {CatalogTool} tool
 * @returns {{kind: string, label: string, capability: string, title: string}}
 */
export function skillExecutionPresentation(tool) {
  const declared = String(tool?.execution_class || "").trim();
  const capability = String(tool?.capability || "").trim();
  if (declared === "host_helper") {
    return {
      kind: "exec-helper",
      label: "host_helper",
      capability,
      title: "包声明经由固定 capability 的 root helper 执行；实际隔离身份以标题栏 execution 药丸为准。",
    };
  }
  if (declared === "runner") {
    return {
      kind: "exec-runner",
      label: "runner",
      capability,
      title: "包声明经由 Runner 执行；实际隔离身份以标题栏 execution 药丸为准。",
    };
  }
  if (declared === "credential_helper") {
    return {
      kind: "exec-credential",
      label: "credential_helper",
      capability,
      title: "包声明经由固定 capability 的 credential helper 执行；凭据不会交给普通脚本，实际隔离身份以标题栏 execution 药丸为准。",
    };
  }
  return {
    kind: "exec-unknown",
    label: declared || "invalid",
    capability,
    title: "包未声明合法执行类，后端会按不可执行处理。",
  };
}

/**
 * @param {CatalogTool} tool
 * @returns {{label: string, title: string}}
 */
export function skillOriginPresentation(tool) {
  const origin = String(tool?.origin || "").trim();
  if (origin === "builtin") return { label: "builtin", title: "随仓库或签名 release 分发的内置包。" };
  if (origin === "user") return { label: "user", title: "用户创建的包，强制 runner 执行类且不得覆盖内置包名。" };
  return { label: origin || "unknown", title: "后端未给出来源。" };
}

/**
 * Materialization state as returned by `/api/tools` (`ready` / `available`),
 * plus the two client-side transients set while a materialize call is in
 * flight. There is deliberately no `local` state: the API maps `installed` to
 * `ready` and never emits `local`.
 * @param {CatalogTool} tool
 * @returns {{state: string, label: string, actionable: boolean, busy: boolean, title: string}}
 */
export function skillMaterializationPresentation(tool) {
  const state = String(tool?.materialization || "").trim();
  if (state === "ready") {
    return { state, label: "ready", actionable: false, busy: false, title: "包已物化到本机，可直接运行。" };
  }
  if (state === "materializing") {
    return { state, label: "加载中", actionable: false, busy: true, title: "正在校验并物化整包。" };
  }
  if (state === "failed") {
    return { state, label: "重试加载", actionable: true, busy: false, title: "上一次物化失败，可重试。" };
  }
  if (state === "available") {
    return { state, label: "加载 Skill", actionable: true, busy: false, title: "签名 release 中可用，尚未物化到本机。" };
  }
  return { state: state || "unknown", label: state || "unknown", actionable: false, busy: false, title: "后端未给出物化状态。" };
}

/**
 * Group catalog tools for the `<select>` as `category / skill`, applying a
 * free-text filter first so the option list stays navigable once a few
 * packages are installed.
 * @param {CatalogTool[]} tools
 * @param {string} [filter]
 * @returns {Array<{label: string, tools: CatalogTool[]}>}
 */
export function groupToolsForSelect(tools, filter = "") {
  const needle = String(filter || "").trim().toLowerCase();
  const groups = new Map();
  for (const tool of Array.isArray(tools) ? tools : []) {
    const any = /** @type {any} */ (tool);
    const ref = String(any?.ref || "");
    const skill = String(any?.skill || ref.split("/")[0] || "skills");
    const category = String(any?.category || "custom");
    if (needle) {
      const haystack = `${ref} ${skill} ${category} ${String(any?.description || "")}`.toLowerCase();
      if (!haystack.includes(needle)) continue;
    }
    const label = `${category} / ${skill}`;
    if (!groups.has(label)) groups.set(label, []);
    groups.get(label).push(tool);
  }
  return [...groups.entries()]
    .sort(([left], [right]) => left.localeCompare(right))
    .map(([label, entries]) => ({ label, tools: entries }));
}

/**
 * Package facts for the selected tool. Every value comes from `/api/tools`;
 * the console does not infer any of them.
 * @param {CatalogTool|null|undefined} tool
 * @returns {Array<[string, string]>}
 */
export function skillPackageRows(tool) {
  if (!tool) return [];
  const any = /** @type {any} */ (tool);
  const execution = skillExecutionPresentation(tool);
  return [
    ["Skill", String(any.skill || "")],
    ["package_version", String(any.package_version || "未提供")],
    ["core_api", String(any.core_api ?? "未提供")],
    ["来源", skillOriginPresentation(tool).label],
    ["分类", String(any.category || "custom")],
    ["风险", String(any.risk || "")],
    ["审批范围", String(any.approval_scope || "未声明")],
    ["执行类", execution.capability ? `${execution.label} · ${execution.capability}` : execution.label],
  ];
}

/**
 * Human-readable summary of one declared guard, so a precondition like
 * "apply 前必须携带备份凭据" is visible before the run rather than only in the
 * failure message.
 * @param {Record<string, any>} guard
 * @returns {string}
 */
export function guardSummary(guard) {
  const type = String(guard?.type || "unknown");
  if (guard?.message) return `${type}：${String(guard.message)}`;
  if (type === "backup_proof") {
    const source = guard?.source?.tool ? `，凭据来自 ${String(guard.source.tool)}` : "";
    return `backup_proof：apply 前必须提供备份凭据${source}。`;
  }
  if (type === "risk_by_value") {
    return `risk_by_value：风险随参数 ${String(guard?.field || "")} 变化。`;
  }
  if (type === "runner_fallthrough") {
    return `runner_fallthrough：参数 ${String(guard?.field || "")} 决定是否走 runner。`;
  }
  return `${type}：包声明的前置约束。`;
}

/**
 * @param {CatalogTool|null|undefined} tool
 * @returns {string[]}
 */
export function skillGuardSummaries(tool) {
  const guards = /** @type {any} */ (tool)?.guards;
  return (Array.isArray(guards) ? guards : []).map(guardSummary);
}
