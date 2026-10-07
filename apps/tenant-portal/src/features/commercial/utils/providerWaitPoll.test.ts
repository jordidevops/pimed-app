import { describe, expect, it, vi, beforeEach, afterEach } from 'vitest'
import {
  nextProviderWaitDelayMs,
  PROVIDER_WAIT_BACKOFF_MS,
  PROVIDER_WAIT_MAX_MS,
  startProviderWaitPoll,
} from './providerWaitPoll'

describe('providerWaitPoll', () => {
  beforeEach(() => {
    vi.useFakeTimers()
  })
  afterEach(() => {
    vi.useRealTimers()
  })

  it('backoff sequence caps at 30s', () => {
    expect(nextProviderWaitDelayMs(0)).toBe(2_000)
    expect(nextProviderWaitDelayMs(1)).toBe(4_000)
    expect(nextProviderWaitDelayMs(2)).toBe(8_000)
    expect(nextProviderWaitDelayMs(3)).toBe(15_000)
    expect(nextProviderWaitDelayMs(4)).toBe(30_000)
    expect(nextProviderWaitDelayMs(10)).toBe(30_000)
    expect(PROVIDER_WAIT_BACKOFF_MS.length).toBe(5)
    expect(PROVIDER_WAIT_MAX_MS).toBe(180_000)
  })

  it('stops on done and does not keep ticking', async () => {
    const onTick = vi.fn().mockResolvedValue('done')
    const onTimeout = vi.fn()
    const stop = startProviderWaitPoll({ onTick, onTimeout })

    await vi.advanceTimersByTimeAsync(2_000)
    expect(onTick).toHaveBeenCalledTimes(1)
    await vi.advanceTimersByTimeAsync(60_000)
    expect(onTick).toHaveBeenCalledTimes(1)
    expect(onTimeout).not.toHaveBeenCalled()
    stop()
  })

  it('pauses while hidden and resumes when visible', async () => {
    let hidden = true
    const listeners = new Map<string, Set<() => void>>()
    const doc = {
      visibilityState: 'hidden' as string,
      addEventListener: (type: string, fn: () => void) => {
        if (!listeners.has(type)) listeners.set(type, new Set())
        listeners.get(type)!.add(fn)
      },
      removeEventListener: (type: string, fn: () => void) => {
        listeners.get(type)?.delete(fn)
      },
    }
    vi.stubGlobal('document', doc)

    const onTick = vi.fn().mockResolvedValue('continue')
    const stop = startProviderWaitPoll({
      onTick,
      onTimeout: () => {},
      isHidden: () => hidden,
    })

    await vi.advanceTimersByTimeAsync(2_000)
    expect(onTick).toHaveBeenCalledTimes(0)

    hidden = false
    doc.visibilityState = 'visible'
    for (const fn of listeners.get('visibilitychange') ?? []) fn()
    await vi.advanceTimersByTimeAsync(0)
    expect(onTick).toHaveBeenCalledTimes(1)
    stop()
    vi.unstubAllGlobals()
  })
})
