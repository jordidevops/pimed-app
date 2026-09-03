'use client'

export function PrintButton({ label = 'Imprimir' }: { label?: string }) {
  return (
    <button
      type="button"
      className="mt-4 rounded-md border border-[var(--line)] bg-white px-3 py-1.5 text-[var(--ink)]"
      onClick={() => window.print()}
    >
      {label}
    </button>
  )
}
