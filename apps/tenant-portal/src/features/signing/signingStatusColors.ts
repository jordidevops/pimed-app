import type { SigningStatus } from './api/signingService'

export const SIGNING_STATUS_CLASSES: Record<SigningStatus, string> = {
  draft:       'bg-gray-100 text-gray-700',
  pending:     'bg-yellow-100 text-yellow-800',
  in_progress: 'bg-blue-100 text-blue-800',
  completed:   'bg-green-100 text-green-800',
  declined:    'bg-red-100 text-red-800',
  expired:     'bg-orange-100 text-orange-800',
  cancelled:   'bg-gray-200 text-gray-800',
  error:       'bg-red-100 text-red-800',
}
