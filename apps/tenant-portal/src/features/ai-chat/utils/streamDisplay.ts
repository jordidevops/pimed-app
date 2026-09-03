export type StreamDisplay = {
  push: (delta: string) => void
  flush: () => void
  reset: (options?: { silent?: boolean }) => void
}

export function createStreamDisplay(
  onUpdate: (text: string) => void,
  options?: { tickMs?: number; charsPerTick?: number },
): StreamDisplay {
  const tickMs = options?.tickMs ?? 28
  const charsPerTick = options?.charsPerTick ?? 2

  let displayed = ''
  let pending = ''
  let timer: ReturnType<typeof setTimeout> | null = null

  function emit() {
    onUpdate(displayed)
  }

  function tick() {
    if (!pending.length) {
      timer = null
      return
    }
    const take = pending.slice(0, charsPerTick)
    pending = pending.slice(charsPerTick)
    displayed += take
    emit()
    timer = setTimeout(tick, tickMs)
  }

  return {
    push(delta: string) {
      if (!delta) return
      pending += delta
      if (timer == null) tick()
    },
    flush() {
      if (timer != null) {
        clearTimeout(timer)
        timer = null
      }
      if (pending.length > 0) {
        displayed += pending
        pending = ''
        emit()
      }
    },
    reset(options) {
      if (timer != null) {
        clearTimeout(timer)
        timer = null
      }
      displayed = ''
      pending = ''
      if (!options?.silent) emit()
    },
  }
}
