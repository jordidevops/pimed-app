import * as React from 'react'

/** Ignore outside dismiss briefly after open (slow paint / double-click race). */
export const DISMISS_GRACE_MS = 400

type PreventableEvent = { preventDefault: () => void }

/**
 * Returns a handler that calls `preventDefault` on outside-dismiss events
 * for {@link DISMISS_GRACE_MS} after the content mounts.
 */
export function useDismissGracePeriod(): (event: PreventableEvent) => void {
  const openedAtRef = React.useRef(0)
  React.useLayoutEffect(() => {
    openedAtRef.current = Date.now()
  }, [])
  return React.useCallback((event: PreventableEvent) => {
    if (Date.now() - openedAtRef.current < DISMISS_GRACE_MS) {
      event.preventDefault()
    }
  }, [])
}
