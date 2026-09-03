import { useCallback, useEffect, useRef, useState } from 'react'

const DEFAULT_DEBOUNCE_MS = 1200

interface UseAutosaveHtmlOptions {
  initialValue?: string | null
  debounceMs?: number
  onSave: (html: string) => Promise<void>
  enabled?: boolean
}

/**
 * Local HTML state with debounce + flush on blur/unmount/manual save.
 */
export function useAutosaveHtml({
  initialValue,
  debounceMs = DEFAULT_DEBOUNCE_MS,
  onSave,
  enabled = true,
}: UseAutosaveHtmlOptions) {
  const [html, setHtml] = useState(initialValue ?? '')
  const [dirty, setDirty] = useState(false)
  const [saving, setSaving] = useState(false)
  const lastSaved = useRef(initialValue ?? '')
  const htmlRef = useRef(html)
  const dirtyRef = useRef(false)
  const timerRef = useRef<ReturnType<typeof setTimeout> | null>(null)
  const onSaveRef = useRef(onSave)
  onSaveRef.current = onSave
  htmlRef.current = html
  dirtyRef.current = dirty

  useEffect(() => {
    const next = initialValue ?? ''
    if (!dirtyRef.current) {
      setHtml(next)
      lastSaved.current = next
      htmlRef.current = next
    }
  }, [initialValue])

  const flush = useCallback(async () => {
    if (!enabled) return
    if (timerRef.current) {
      clearTimeout(timerRef.current)
      timerRef.current = null
    }
    const next = htmlRef.current
    if (next === lastSaved.current) {
      setDirty(false)
      dirtyRef.current = false
      return
    }
    setSaving(true)
    try {
      await onSaveRef.current(next)
      lastSaved.current = next
      setDirty(false)
      dirtyRef.current = false
    } finally {
      setSaving(false)
    }
  }, [enabled])

  const schedule = useCallback(() => {
    if (!enabled) return
    if (timerRef.current) clearTimeout(timerRef.current)
    timerRef.current = setTimeout(() => {
      timerRef.current = null
      void flush()
    }, debounceMs)
  }, [debounceMs, enabled, flush])

  function handleChange(next: string) {
    setHtml(next)
    htmlRef.current = next
    setDirty(true)
    dirtyRef.current = true
    schedule()
  }

  useEffect(() => {
    return () => {
      if (timerRef.current) clearTimeout(timerRef.current)
      if (!enabled) return
      const next = htmlRef.current
      if (dirtyRef.current && next !== lastSaved.current) {
        void onSaveRef.current(next).catch(() => {})
      }
    }
  }, [enabled])

  return {
    html,
    dirty,
    saving,
    handleChange,
    flush,
    onBlurFlush: () => {
      void flush()
    },
  }
}
