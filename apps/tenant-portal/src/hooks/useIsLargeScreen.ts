import { useEffect, useState } from 'react'

/** Tailwind `lg` — same breakpoint as the desktop sidebar in AppLayout. */
export const LG_MEDIA_QUERY = '(min-width: 1024px)'

export function getIsLargeScreen(): boolean {
  return typeof window !== 'undefined' && window.matchMedia(LG_MEDIA_QUERY).matches
}

export function useIsLargeScreen(): boolean {
  const [isLarge, setIsLarge] = useState(getIsLargeScreen)

  useEffect(() => {
    const media = window.matchMedia(LG_MEDIA_QUERY)
    const onChange = () => setIsLarge(media.matches)
    onChange()
    media.addEventListener('change', onChange)
    return () => media.removeEventListener('change', onChange)
  }, [])

  return isLarge
}
