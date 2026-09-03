export interface PortalTokenBatchSummary {
  requested: number
  created: number
  skipped: number
  errors: number
}

export interface StartPortalTokenBatchResult {
  batchId: string
  status: 'pending' | 'processing' | 'completed' | 'failed' | 'expired'
  expiresAt: string
  summary: PortalTokenBatchSummary
  idempotentReplay: boolean
}

export type PortalTokenBatchRowStatus = 'created' | 'skipped' | 'error'

export interface PortalTokenBatchResultRow {
  employeeId: string
  employeeName: string | null
  employeeCode: string | null
  status: PortalTokenBatchRowStatus
  errorCode: string | null
  portalUrl: string | null
  secret: string | null
  tokenId: string | null
  supersededTokenId: string | null
  label: string | null
}

export interface FetchPortalTokenBatchResults {
  batchId: string
  expiresAt: string
  rows: PortalTokenBatchResultRow[]
}

export interface PortalTokenBatchListItem {
  batchId: string
  status: string
  expiresAt: string
  label: string | null
  employeeCount: number
  createdCount: number
  skippedCount: number
  errorCount: number
  createdAt: string
  lastFetchedAt: string | null
  fetchCount: number
}

export interface StartPortalTokenBatchInput {
  employeeIds: string[]
  pinMustSet?: boolean
  label?: string
  skipInactive?: boolean
  idempotencyKey: string
  forceNew?: boolean
}

export interface PendingPortalBatchSession {
  batchId: string
  expiresAt: string
}
