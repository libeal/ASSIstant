export function normalizeApprovalCard(result) {
  const card = result?.approval_card;
  if (card && typeof card === "object") return card;
  return null;
}
