/**
 * CF-28 scale: DocuSeal waiting_provider poll with backoff (not fixed 40×3s).
 */
export const PROVIDER_WAIT_BACKOFF_MS = [2_000, 4_000, 8_000, 15_000, 30_000] as const
export const PROVIDER_WAIT_MAX_MS = 180_000

export function nextProviderWaitDelayMs(tickIndex: number): number {
  const i = Math.max(0, Math.min(tickIndex, PROVIDER_WAIT_BACKOFF_MS.length - 1))
  return PROVIDER_WAIT_BACKOFF_MS[i]!
}

export type ProviderWaitTickResult = 'done' | 'continue' | 'rate_limited'

export function startProviderWaitPoll(args: {
  onTick: () => Promise<ProviderWaitTickResult>
  onTimeout: () => void
  onRateLimited?: () => void
  isHidden?: () => boolean
  maxMs?: number
}): () => void {
  const maxMs = args.maxMs ?? PROVIDER_WAIT_MAX_MS
  const isHidden =
    args.isHidden ??
    (() =>
      typeof document !== 'undefined' && document.visibilityState === 'hidden')

  let cancelled = false
  let tickIndex = 0
  let timer: ReturnType<typeof setTimeout> | undefined
  const started = Date.now()
  let visibilityHandler: (() => void) | undefined

  const clearVis = () => {
    if (visibilityHandler && typeof document !== 'undefined') {
      document.removeEventListener('visibilitychange', visibilityHandler)
      visibilityHandler = undefined
    }
  }

  const stop = () => {
    cancelled = true
    if (timer !== undefined) clearTimeout(timer)
    timer = undefined
    clearVis()
  }

  const schedule = (delayMs: number) => {
    if (cancelled) return
    timer = setTimeout(() => {
      void run()
    }, delayMs)
  }

  const waitUntilVisible = () => {
    if (cancelled || typeof document === 'undefined') return
    clearVis()
    visibilityHandler = () => {
      if (cancelled) return
      if (document.visibilityState === 'visible') {
        clearVis()
        schedule(0)
      }
    }
    document.addEventListener('visibilitychange', visibilityHandler)
  }

  const run = async () => {
    if (cancelled) return
    if (Date.now() - started >= maxMs) {
      stop()
      args.onTimeout()
      return
    }
    if (isHidden()) {
      if (typeof document === 'undefined') {
        const delay = nextProviderWaitDelayMs(tickIndex)
        tickIndex += 1
        schedule(delay)
        return
      }
      waitUntilVisible()
      return
    }

    let result: ProviderWaitTickResult
    try {
      result = await args.onTick()
    } catch {
      result = 'continue'
    }
    if (cancelled) return

    if (result === 'done') {
      stop()
      return
    }
    if (result === 'rate_limited') {
      stop()
      args.onRateLimited?.()
      return
    }

    const delay = nextProviderWaitDelayMs(tickIndex)
    tickIndex += 1
    if (Date.now() - started >= maxMs) {
      stop()
      args.onTimeout()
      return
    }
    schedule(delay)
  }

  schedule(nextProviderWaitDelayMs(0))
  return stop
}
