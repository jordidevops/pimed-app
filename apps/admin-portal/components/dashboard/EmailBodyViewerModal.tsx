'use client'

import { useState } from 'react'

// ---------------------------------------------------------------------------
// Tab type
// ---------------------------------------------------------------------------

type BodyTab = 'preview' | 'html' | 'text'

// ---------------------------------------------------------------------------
// Props
// ---------------------------------------------------------------------------

interface EmailBodyViewerModalProps {
  subject: string | null
  fromName: string | null
  fromEmail: string | null
  toEmails: string[]
  ccEmails: string[] | null
  bccEmails: string[] | null
  replyTo: string | null
  htmlBody: string | null
  textBody: string | null
  onClose: () => void
}

// ---------------------------------------------------------------------------
// Component
// ---------------------------------------------------------------------------

export function EmailBodyViewerModal({
  subject,
  fromName,
  fromEmail,
  toEmails,
  ccEmails,
  bccEmails,
  replyTo,
  htmlBody,
  textBody,
  onClose,
}: EmailBodyViewerModalProps) {
  const [activeTab, setActiveTab] = useState<BodyTab>('preview')

  const tabs: { id: BodyTab; label: string; disabled?: boolean }[] = [
    { id: 'preview', label: 'Vista prèvia HTML', disabled: !htmlBody },
    { id: 'html', label: 'Codi HTML', disabled: !htmlBody },
    { id: 'text', label: 'Text pla', disabled: !textBody },
  ]

  const availableTab = tabs.find((t) => !t.disabled)
  const tab = tabs.find((t) => t.id === activeTab && !t.disabled)?.id ?? availableTab?.id ?? 'preview'

  return (
    <div
      className="fixed inset-0 z-[60] flex items-center justify-center p-4"
      aria-modal="true"
      role="dialog"
    >
      {/* Backdrop */}
      <div
        className="absolute inset-0 bg-black/60"
        onClick={onClose}
        aria-hidden="true"
      />

      {/* Panel */}
      <div className="relative z-10 w-full max-w-4xl bg-white rounded-2xl shadow-2xl flex flex-col max-h-[92vh]">
        {/* Header */}
        <div className="flex items-start justify-between px-6 py-4 border-b border-gray-100 shrink-0">
          <div className="min-w-0">
            <h2 className="text-base font-semibold text-gray-900 truncate">
              {subject ?? <span className="italic text-gray-400">(sense assumpte)</span>}
            </h2>
            <p className="mt-0.5 text-xs text-gray-500 truncate">
              <span className="font-medium">De:</span>{' '}
              {fromName ? `${fromName} <${fromEmail}>` : fromEmail}
              {' '}
              <span className="ml-2 font-medium">Per a:</span>{' '}
              {toEmails.join(', ')}
              {ccEmails && ccEmails.length > 0 && (
                <> <span className="ml-2 font-medium">CC:</span> {ccEmails.join(', ')}</>
              )}
              {bccEmails && bccEmails.length > 0 && (
                <> <span className="ml-2 font-medium">BCC:</span> {bccEmails.join(', ')}</>
              )}
              {replyTo && (
                <> <span className="ml-2 font-medium">Reply-To:</span> {replyTo}</>
              )}
            </p>
          </div>
          <button
            type="button"
            onClick={onClose}
            className="ml-4 shrink-0 rounded-full p-1.5 text-gray-400 hover:text-gray-600 hover:bg-gray-100 transition-colors"
            aria-label="Tancar"
          >
            <svg className="w-5 h-5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
              <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M6 18L18 6M6 6l12 12" />
            </svg>
          </button>
        </div>

        {/* Tabs */}
        <div className="flex border-b border-gray-100 px-6 shrink-0">
          {tabs.map((t) => (
            <button
              key={t.id}
              type="button"
              disabled={t.disabled}
              onClick={() => setActiveTab(t.id)}
              className={`px-4 py-2.5 text-sm font-medium border-b-2 transition-colors -mb-px ${
                tab === t.id
                  ? 'border-indigo-600 text-indigo-600'
                  : t.disabled
                    ? 'border-transparent text-gray-300 cursor-not-allowed'
                    : 'border-transparent text-gray-500 hover:text-gray-700'
              }`}
            >
              {t.label}
            </button>
          ))}
        </div>

        {/* Content */}
        <div className="flex-1 overflow-hidden">
          {tab === 'preview' && htmlBody && (
            <iframe
              srcDoc={htmlBody}
              className="w-full h-full border-0"
              title="Vista prèvia del correu"
              sandbox="allow-same-origin"
            />
          )}
          {tab === 'html' && htmlBody && (
            <pre className="h-full overflow-auto p-6 text-xs text-gray-700 bg-gray-50 leading-relaxed whitespace-pre-wrap break-all font-mono">
              {htmlBody}
            </pre>
          )}
          {tab === 'text' && textBody && (
            <pre className="h-full overflow-auto p-6 text-sm text-gray-700 bg-gray-50 leading-relaxed whitespace-pre-wrap font-sans">
              {textBody}
            </pre>
          )}
          {!htmlBody && !textBody && (
            <div className="flex items-center justify-center h-full text-sm text-gray-400 italic">
              No hi ha cos disponible per a aquest correu.
            </div>
          )}
        </div>

        {/* Footer */}
        <div className="px-6 py-3 border-t border-gray-100 flex justify-end shrink-0">
          <button
            type="button"
            onClick={onClose}
            className="px-4 py-2 rounded-lg border border-gray-300 text-sm text-gray-700 hover:bg-gray-50 transition-colors"
          >
            Tancar
          </button>
        </div>
      </div>
    </div>
  )
}
