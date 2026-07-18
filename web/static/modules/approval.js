/** @typedef {import("./types.js").ApprovalCard} ApprovalCard */

/**
 * Extract a structured approval card from an execution result.
 * @param {Record<string, any>|null|undefined} result
 * @returns {ApprovalCard|null}
 */
export function normalizeApprovalCard(result) {
  const card = result?.approval_card;
  if (card && typeof card === "object") return card;
  return null;
}
