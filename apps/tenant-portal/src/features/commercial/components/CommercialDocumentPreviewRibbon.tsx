import { cn } from '@/lib/utils'

export type CommercialPreviewRibbonTone = 'cancelled' | 'invoiced'

const TONE_CLASS: Record<CommercialPreviewRibbonTone, string> = {
  cancelled:
    'bg-red-600 text-white shadow-[0_0_0_3px_rgba(255,255,255,0.95),0_8px_16px_rgba(0,0,0,0.45)]',
  invoiced:
    'bg-emerald-500 text-white shadow-[0_0_0_3px_rgba(255,255,255,0.95),0_8px_16px_rgba(0,0,0,0.45)]',
}

/** Diagonal corner ribbon over the PDF/HTML preview. */
export function CommercialDocumentPreviewRibbon({
  label,
  tone,
}: {
  label: string
  tone: CommercialPreviewRibbonTone
}) {
  return (
    <div
      className="pointer-events-none absolute left-0 top-0 z-20 h-28 w-28 overflow-hidden rounded-tl-xl"
      aria-hidden
    >
      <div
        className={cn(
          'absolute left-[-38%] top-[22%] w-[170%] rotate-[-45deg] py-1.5 text-center text-xs font-extrabold uppercase tracking-[0.2em]',
          TONE_CLASS[tone],
        )}
      >
        {label}
      </div>
    </div>
  )
}
