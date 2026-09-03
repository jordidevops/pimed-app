'use client'

import type { ReactNode } from 'react'

export const inputClass =
  'w-full rounded-md border border-gray-200 px-2.5 py-1.5 text-sm text-gray-900 focus:border-indigo-400 focus:outline-none focus:ring-1 focus:ring-indigo-400 disabled:bg-gray-50 disabled:text-gray-400'

export const primaryButtonClass =
  'rounded-md bg-indigo-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-indigo-500 disabled:opacity-50'

export const secondaryButtonClass =
  'rounded-md border border-gray-200 px-3 py-1.5 text-sm font-medium text-gray-700 hover:bg-gray-50 disabled:opacity-50'

export const dangerButtonClass =
  'rounded-md border border-red-200 px-3 py-1.5 text-sm font-medium text-red-600 hover:bg-red-50 disabled:opacity-50'

export function Field({
  label,
  hint,
  className,
  children,
}: {
  label: string
  hint?: string
  className?: string
  children: ReactNode
}) {
  return (
    <label className={`block text-sm ${className ?? ''}`}>
      <span className="mb-1 block font-medium text-gray-700">{label}</span>
      {children}
      {hint && <span className="mt-1 block text-xs text-gray-500">{hint}</span>}
    </label>
  )
}

export function Chip({ children, tone = 'gray' }: { children: ReactNode; tone?: 'gray' | 'green' | 'amber' | 'indigo' }) {
  const tones: Record<string, string> = {
    gray: 'bg-gray-100 text-gray-600',
    green: 'bg-green-50 text-green-700',
    amber: 'bg-amber-50 text-amber-700',
    indigo: 'bg-indigo-50 text-indigo-700',
  }
  return (
    <span className={`inline-flex items-center rounded px-1.5 py-0.5 text-xs font-medium ${tones[tone]}`}>
      {children}
    </span>
  )
}

export function Banner({
  tone,
  message,
  onDismiss,
}: {
  tone: 'success' | 'error' | 'info'
  message: string
  onDismiss?: () => void
}) {
  const tones = {
    success: 'border-green-200 bg-green-50 text-green-800',
    error: 'border-red-200 bg-red-50 text-red-700',
    info: 'border-indigo-200 bg-indigo-50 text-indigo-800',
  }
  return (
    <div className={`flex items-start justify-between gap-3 rounded-lg border px-3 py-2 text-sm ${tones[tone]}`}>
      <span>{message}</span>
      {onDismiss && (
        <button type="button" onClick={onDismiss} className="text-xs underline opacity-70">
          Tancar
        </button>
      )}
    </div>
  )
}

export function Pager({
  page,
  pageCount,
  total,
  onChange,
  disabled,
}: {
  page: number
  pageCount: number
  total: number
  onChange: (page: number) => void
  disabled?: boolean
}) {
  if (pageCount <= 1) {
    return <p className="text-xs text-gray-500">{total} resultats</p>
  }

  return (
    <div className="flex items-center justify-between text-xs text-gray-500">
      <span>{total} resultats</span>
      <div className="flex items-center gap-2">
        <button
          type="button"
          className={secondaryButtonClass}
          disabled={disabled || page <= 1}
          onClick={() => onChange(page - 1)}
        >
          Anterior
        </button>
        <span className="tabular-nums">
          {page} / {pageCount}
        </span>
        <button
          type="button"
          className={secondaryButtonClass}
          disabled={disabled || page >= pageCount}
          onClick={() => onChange(page + 1)}
        >
          Següent
        </button>
      </div>
    </div>
  )
}

export function EmptyRow({ colSpan, children }: { colSpan: number; children: ReactNode }) {
  return (
    <tr>
      <td colSpan={colSpan} className="px-4 py-8 text-center text-sm text-gray-500">
        {children}
      </td>
    </tr>
  )
}
