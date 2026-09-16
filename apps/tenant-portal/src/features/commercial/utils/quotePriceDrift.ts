import { eurosToDocumentCents } from './paymentAllocation'

export function liveProjectLinesTotalCents(
  lines: Array<{ total_with_tax?: number | null }>,
): number {
  return lines.reduce(
    (sum, line) => sum + eurosToDocumentCents(Number(line.total_with_tax ?? 0)),
    0,
  )
}

export function commercialDocumentDivergesFromLiveTotal(
  docTotal: number,
  liveCents: number,
): boolean {
  return eurosToDocumentCents(Number(docTotal)) !== liveCents
}
