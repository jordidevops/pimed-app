import { useEffect, useRef } from 'react'
import { markEntityCommentMentionRead } from '../api/timelineService'

/**
 * Marca la tasca com a vista quan un usuari mencionat la veu a la pantalla.
 */
export function useMentionReadOnVisible(
  commentId: string,
  enabled: boolean,
  onMarked?: () => void,
) {
  const rootRef = useRef<HTMLDivElement>(null)
  const markedRef = useRef(false)

  useEffect(() => {
    markedRef.current = false
  }, [commentId, enabled])

  useEffect(() => {
    if (!enabled || markedRef.current) return
    const el = rootRef.current
    if (!el) return

    const observer = new IntersectionObserver(
      (entries) => {
        if (!entries.some((e) => e.isIntersecting) || markedRef.current) return
        markedRef.current = true
        void markEntityCommentMentionRead(commentId)
          .then((marked) => {
            if (marked) onMarked?.()
          })
          .catch(() => {
            markedRef.current = false
          })
      },
      { threshold: 0.4 },
    )

    observer.observe(el)
    return () => observer.disconnect()
  }, [commentId, enabled, onMarked])

  return rootRef
}
