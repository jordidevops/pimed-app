export function agreementBlocksProjectWork(
  agreements: Array<{ work_gate: string | null; status: string | null }>,
): boolean {
  return agreements.some(
    (agreement) =>
      agreement.work_gate === 'require_signed_agreement' &&
      agreement.status !== 'active' &&
      agreement.status !== 'cancelled' &&
      agreement.status !== 'finished',
  )
}
