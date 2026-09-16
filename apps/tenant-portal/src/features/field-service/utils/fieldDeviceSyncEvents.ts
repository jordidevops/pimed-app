export const FIELD_DEVICE_SYNC_REQUEST_EVENT = 'field-device-sync:request'

export interface FieldDeviceSyncRequestDetail {
  resolve: () => void
  reject: (error: unknown) => void
}

/**
 * Requests the app-wide FieldSyncCoordinator to drain every local lane in the
 * required order. Callers must never drain field_ops directly when a close-out
 * may be present.
 */
export function requestFieldDeviceSync(): Promise<void> {
  if (typeof window === 'undefined') return Promise.resolve()

  return new Promise<void>((resolve, reject) => {
    const timeout = window.setTimeout(
      () => reject(new Error('field_sync_coordinator_unavailable')),
      45_000,
    )
    window.dispatchEvent(
      new CustomEvent<FieldDeviceSyncRequestDetail>(
        FIELD_DEVICE_SYNC_REQUEST_EVENT,
        {
          detail: {
            resolve: () => {
              window.clearTimeout(timeout)
              resolve()
            },
            reject: (error) => {
              window.clearTimeout(timeout)
              reject(error)
            },
          },
        },
      ),
    )
  })
}
