import { useEffect, useState, type ReactNode } from 'react'
import { Loader2, CheckCircle, XCircle, AlertTriangle, FileText } from 'lucide-react'
import { SignaturePad } from '@/features/signing/components/SignaturePad'
import { generateClientOpId } from '@/features/attendance/api/clientOpId'
import { supabase } from '@/lib/supabase'
import {
  commercialDecisionPublicCopy,
  fillCopy,
} from '../utils/commercialDecisionPublicCopy'
import { startProviderWaitPoll } from '../utils/providerWaitPoll'

const SUPABASE_URL = import.meta.env.VITE_SUPABASE_URL as string
const SUPABASE_KEY = import.meta.env.VITE_SUPABASE_PUBLISHABLE_DEFAULT_KEY as string

export type CommercialDecisionReceipt = {
  outcome: string
  decided_at: string | null
  decided_via: string | null
  provider: string | null
  signer_name: string | null
  reason: string | null
  trace_id: string | null
  content_hash: string | null
}

export type CommercialDecisionResolve = {
  kind: 'commercial_decision'
  request_status: string
  purpose: string
  expires_at: string
  decided_at: string | null
  decided_via: string | null
  active_provider: string | null
  content_hash: string
  document_version_id: string
  can_decide: boolean
  provider_continue_available?: boolean | null
  receipt?: CommercialDecisionReceipt | null
  snapshot: {
    kind?: string | null
    doc_type?: string | null
    doc_number?: string | null
    formalization_mode?: string | null
    total?: number | null
    currency?: string | null
    locale?: string | null
    valid_until?: string | null
    show_prices?: boolean | null
    version_no?: number | null
    purpose?: string | null
  }
  tenant: {
    name?: string | null
    logo_url?: string | null
  }
}

type PageState =
  | 'loading'
  | 'ready'
  | 'signing'
  | 'declining'
  | 'waiting_provider'
  | 'accepted'
  | 'declined'
  | 'expired'
  | 'revoked'
  | 'superseded'
  | 'error'

function documentLabel(
  snapshot: CommercialDecisionResolve['snapshot'],
  copy: ReturnType<typeof commercialDecisionPublicCopy>,
): string {
  if (snapshot.kind === 'agreement_version') return copy.agreement
  if (snapshot.doc_type === 'delivery_note') return copy.delivery
  if (snapshot.doc_type === 'quote_amendment') return copy.amendment
  return copy.budget
}

function consequenceCopy(
  snapshot: CommercialDecisionResolve['snapshot'],
  copy: ReturnType<typeof commercialDecisionPublicCopy>,
): string {
  if (snapshot.kind === 'agreement_version') return copy.consequenceAgreement
  if (snapshot.doc_type === 'delivery_note') return copy.consequenceDelivery
  return copy.consequenceQuote
}

function formatWhen(iso: string | null | undefined, locale?: string | null): string {
  if (!iso) return '—'
  try {
    return new Date(iso).toLocaleString(locale || 'ca', {
      dateStyle: 'medium',
      timeStyle: 'short',
      timeZone: 'UTC',
    }) + ' UTC'
  } catch {
    return iso
  }
}

async function fetchReceipt(token: string): Promise<CommercialDecisionReceipt | null> {
  const { data, error } = await supabase.rpc('get_commercial_decision_receipt' as never, {
    p_token: token,
  } as never)
  if (error || !data) return null
  const row = data as { kind?: string } & Partial<CommercialDecisionReceipt>
  if (row.kind !== 'commercial_decision_receipt') return null
  return {
    outcome: String(row.outcome ?? ''),
    decided_at: row.decided_at ?? null,
    decided_via: row.decided_via ?? null,
    provider: row.provider ?? null,
    signer_name: row.signer_name ?? null,
    reason: row.reason ?? null,
    trace_id: row.trace_id ?? null,
    content_hash: row.content_hash ?? null,
  }
}

async function refreshResolve(token: string): Promise<CommercialDecisionResolve | null> {
  const res = await fetch(`${SUPABASE_URL}/functions/v1/resolve-commercial-decision-token`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      apikey: SUPABASE_KEY,
      Authorization: `Bearer ${SUPABASE_KEY}`,
    },
    body: JSON.stringify({ token, mark_opened: false }),
  })
  if (res.status === 429) {
    throw Object.assign(new Error('rate_limited'), { code: 'rate_limited' })
  }
  if (!res.ok) return null
  const row = (await res.json().catch(() => null)) as
    | ({ kind?: string } & Partial<CommercialDecisionResolve>)
    | null
  if (!row || row.kind !== 'commercial_decision') return null
  return row as CommercialDecisionResolve
}

export function CommercialDecisionPage({
  token,
  initial,
}: {
  token: string
  initial: CommercialDecisionResolve
}) {
  const [pageState, setPageState] = useState<PageState>(() => {
    switch (initial.request_status) {
      case 'accepted':
        return 'accepted'
      case 'declined':
        return 'declined'
      case 'expired':
        return 'expired'
      case 'revoked':
        return 'revoked'
      case 'superseded':
        return 'superseded'
      default:
        return 'ready'
    }
  })
  const [payload, setPayload] = useState(initial)
  const [receipt, setReceipt] = useState<CommercialDecisionReceipt | null>(
    initial.receipt ?? null,
  )
  const [pdfUrl, setPdfUrl] = useState<string | null>(null)
  const [errorMsg, setErrorMsg] = useState<string | null>(null)
  const [signerName, setSignerName] = useState('')
  const [authorityChecked, setAuthorityChecked] = useState(false)
  const [showDecline, setShowDecline] = useState(false)
  const [declineReason, setDeclineReason] = useState('')
  const [showReceipt, setShowReceipt] = useState(
    initial.request_status === 'accepted' || initial.request_status === 'declined',
  )

  useEffect(() => {
    let cancelled = false
    void (async () => {
      try {
        const res = await fetch(`${SUPABASE_URL}/functions/v1/get-document-url`, {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            apikey: SUPABASE_KEY,
            Authorization: `Bearer ${SUPABASE_KEY}`,
          },
          body: JSON.stringify({
            version_id: payload.document_version_id,
            commercial_decision_token: token,
            source: 'preview',
          }),
        })
        if (!res.ok || cancelled) return
        const data = (await res.json()) as { url?: string }
        if (!cancelled) setPdfUrl(data.url ?? null)
      } catch {
        /* preview optional */
      }
    })()
    return () => {
      cancelled = true
    }
  }, [payload.document_version_id, token])

  useEffect(() => {
    if (pageState !== 'accepted' && pageState !== 'declined') return
    if (receipt) return
    void (async () => {
      const next = await fetchReceipt(token)
      if (next) setReceipt(next)
    })()
  }, [pageState, receipt, token])

  // After DocuSeal redirect: backoff poll until webhook applies (not fixed 40×3s).
  useEffect(() => {
    if (pageState !== 'waiting_provider') return
    const localeHint = payload.snapshot?.locale
    return startProviderWaitPoll({
      onTick: async () => {
        try {
          const resolved = await refreshResolve(token)
          if (!resolved) return 'continue'
          setPayload(resolved)
          if (
            resolved.request_status === 'accepted' ||
            resolved.request_status === 'declined'
          ) {
            if (resolved.receipt) setReceipt(resolved.receipt)
            else {
              const r = await fetchReceipt(token)
              if (r) setReceipt(r)
            }
            setPageState(
              resolved.request_status === 'accepted' ? 'accepted' : 'declined',
            )
            setShowReceipt(true)
            return 'done'
          }
          return 'continue'
        } catch (err) {
          if ((err as { code?: string })?.code === 'rate_limited') {
            return 'rate_limited'
          }
          return 'continue'
        }
      },
      onTimeout: () => {
        setPageState('ready')
        setErrorMsg(
          commercialDecisionPublicCopy(localeHint).waitingProvider,
        )
      },
      onRateLimited: () => {
        setPageState('ready')
        setErrorMsg(commercialDecisionPublicCopy(localeHint).rateLimited)
      },
    })
  }, [pageState, token, payload.snapshot?.locale])

  async function processDecision(body: Record<string, unknown>) {
    const res = await fetch(`${SUPABASE_URL}/functions/v1/process-commercial-decision-token`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        apikey: SUPABASE_KEY,
        Authorization: `Bearer ${SUPABASE_KEY}`,
      },
      body: JSON.stringify({
        token,
        client_op_id: generateClientOpId(),
        user_agent: navigator.userAgent,
        ...body,
      }),
    })
    const data = (await res.json().catch(() => ({}))) as {
      error?: string
      code?: string
      success?: boolean
    }
    if (res.status === 429 || data.code === 'rate_limited' || data.error === 'rate_limited') {
      throw Object.assign(new Error('rate_limited'), { code: 'rate_limited' })
    }
    if (!res.ok || data.error) {
      throw new Error(data.error || `HTTP ${res.status}`)
    }
    return data
  }

  async function loadTerminalState(preferred: 'accepted' | 'declined') {
    const localeCopy = commercialDecisionPublicCopy(payload.snapshot?.locale)
    for (let i = 0; i < 5; i += 1) {
      try {
        const resolved = await refreshResolve(token)
        if (resolved?.request_status === 'accepted' || resolved?.request_status === 'declined') {
          setPayload(resolved)
          if (resolved.receipt) setReceipt(resolved.receipt)
          else {
            const r = await fetchReceipt(token)
            if (r) setReceipt(r)
          }
          setPageState(resolved.request_status === 'accepted' ? 'accepted' : 'declined')
          setShowReceipt(true)
          return
        }
      } catch (err) {
        if ((err as { code?: string })?.code === 'rate_limited') {
          setPageState('ready')
          setErrorMsg(localeCopy.rateLimited)
          return
        }
      }
      await new Promise((r) => setTimeout(r, 400))
    }
    // Do not fake terminal UI — server still open (B5).
    setPageState('ready')
    setErrorMsg(
      preferred === 'accepted' ? localeCopy.waitingProvider : localeCopy.refuseFailed,
    )
  }

  const snap = payload.snapshot
  const showPrices = snap.show_prices !== false
  const locale = snap.locale || 'ca'
  const copy = commercialDecisionPublicCopy(locale)
  const label = documentLabel(snap, copy)

  const isDocuseal = payload.active_provider === 'docuseal'

  async function handleContinueDocuseal() {
    setErrorMsg(null)
    setPageState('signing')
    try {
      const { data, error } = await supabase.rpc(
        'resolve_commercial_docuseal_continue' as never,
        { p_token: token } as never,
      )
      if (error) throw new Error(error.message)
      const row = data as { ok?: boolean; code?: string; redirect_url?: string } | null
      if (!row?.ok || typeof row.redirect_url !== 'string' || !row.redirect_url) {
        throw new Error(
          row?.code === 'provider_pending' ? copy.providerPending : copy.continueFailed,
        )
      }
      setPageState('waiting_provider')
      window.location.assign(row.redirect_url)
    } catch (err) {
      setPageState('ready')
      setErrorMsg(err instanceof Error ? err.message : copy.continueFailed)
    }
  }

  async function handleAccept(signatureDataUrl: string) {
    if (!authorityChecked || !signerName.trim()) {
      setErrorMsg(copy.needNameAuthority)
      return
    }
    setPageState('signing')
    setErrorMsg(null)
    try {
      await processDecision({
        action: 'accept',
        signature_base64: signatureDataUrl,
        signer_name: signerName.trim(),
      })
      await loadTerminalState('accepted')
    } catch (err) {
      setPageState('ready')
      const code = (err as { code?: string })?.code
      setErrorMsg(
        code === 'rate_limited' || (err instanceof Error && err.message === 'rate_limited')
          ? copy.rateLimited
          : err instanceof Error
            ? err.message
            : copy.acceptFailed,
      )
    }
  }

  async function handleDecline() {
    setPageState('declining')
    setErrorMsg(null)
    try {
      await processDecision({
        action: 'decline',
        reason: declineReason.trim() || null,
      })
      await loadTerminalState('declined')
    } catch (err) {
      setPageState('ready')
      const code = (err as { code?: string })?.code
      setErrorMsg(
        code === 'rate_limited' || (err instanceof Error && err.message === 'rate_limited')
          ? copy.rateLimited
          : err instanceof Error
            ? err.message
            : copy.refuseFailed,
      )
    }
  }

  if (pageState === 'loading') {
    return (
      <div className="flex min-h-dvh items-center justify-center bg-slate-50">
        <Loader2 className="h-8 w-8 animate-spin text-slate-500" />
      </div>
    )
  }

  if (pageState === 'accepted' || pageState === 'declined') {
    const ok = pageState === 'accepted'
    return (
      <div className="min-h-dvh bg-slate-50 px-4 py-8 text-slate-900">
        <div className="mx-auto flex max-w-lg flex-col items-center gap-3 text-center">
          {ok ? (
            <CheckCircle className="h-10 w-10 text-emerald-600" aria-hidden />
          ) : (
            <XCircle className="h-10 w-10 text-rose-600" aria-hidden />
          )}
          <h1 className="text-xl font-semibold">{ok ? copy.accepted : copy.declined}</h1>
          <p className="text-sm text-slate-600" aria-live="polite">
            {receipt?.decided_at || payload.decided_at
              ? fillCopy(copy.registeredAt, {
                  when: formatWhen(receipt?.decided_at ?? payload.decided_at, locale),
                })
              : copy.registeredOk}
          </p>
          {receipt?.signer_name ? (
            <p className="text-sm text-slate-600">
              {copy.signer}: {receipt.signer_name}
            </p>
          ) : null}
          {!ok && receipt?.reason ? (
            <p className="text-sm text-slate-600">
              {copy.reason}: {receipt.reason}
            </p>
          ) : null}
        </div>

        <div className="mx-auto mt-6 max-w-lg space-y-3">
          <button
            type="button"
            className="w-full rounded-md border border-slate-300 bg-white px-3 py-2 text-sm font-medium"
            onClick={() => setShowReceipt((v) => !v)}
          >
            {showReceipt ? copy.hideReceipt : copy.showReceipt}
          </button>

          {showReceipt ? (
            <section className="space-y-2 rounded-xl border border-slate-200 bg-white p-4 text-left text-sm shadow-sm">
              <h2 className="font-semibold">{copy.receiptTitle}</h2>
              <dl className="space-y-1.5 text-slate-700">
                <div className="flex justify-between gap-3">
                  <dt className="text-slate-500">{copy.issuer}</dt>
                  <dd>{payload.tenant.name ?? '—'}</dd>
                </div>
                <div className="flex justify-between gap-3">
                  <dt className="text-slate-500">{copy.document}</dt>
                  <dd>
                    {label} {snap.doc_number ?? ''}
                  </dd>
                </div>
                <div className="flex justify-between gap-3">
                  <dt className="text-slate-500">{copy.outcome}</dt>
                  <dd>{ok ? copy.accepted : copy.declined}</dd>
                </div>
                <div className="flex justify-between gap-3">
                  <dt className="text-slate-500">{copy.dateUtc}</dt>
                  <dd>{formatWhen(receipt?.decided_at ?? payload.decided_at, locale)}</dd>
                </div>
                <div className="flex justify-between gap-3">
                  <dt className="text-slate-500">{copy.via}</dt>
                  <dd>{receipt?.decided_via ?? payload.decided_via ?? 'link'}</dd>
                </div>
                <div className="flex justify-between gap-3">
                  <dt className="text-slate-500">{copy.provider}</dt>
                  <dd>{receipt?.provider ?? payload.active_provider ?? 'native'}</dd>
                </div>
                {receipt?.signer_name ? (
                  <div className="flex justify-between gap-3">
                    <dt className="text-slate-500">{copy.signer}</dt>
                    <dd>{receipt.signer_name}</dd>
                  </div>
                ) : null}
                <div className="flex justify-between gap-3">
                  <dt className="text-slate-500">{copy.hash}</dt>
                  <dd className="break-all font-mono text-xs">
                    {(receipt?.content_hash ?? payload.content_hash)?.slice(0, 24)}…
                  </dd>
                </div>
                {receipt?.trace_id ? (
                  <div className="flex justify-between gap-3">
                    <dt className="text-slate-500">{copy.trace}</dt>
                    <dd className="font-mono text-xs">{receipt.trace_id}</dd>
                  </div>
                ) : null}
              </dl>
            </section>
          ) : null}

          {pdfUrl ? (
            <a
              href={pdfUrl}
              target="_blank"
              rel="noreferrer"
              className="block w-full rounded-md bg-slate-900 px-3 py-2 text-center text-sm font-medium text-white"
            >
              {copy.downloadPdf}
            </a>
          ) : null}
        </div>
      </div>
    )
  }

  if (pageState === 'expired') {
    return (
      <Terminal
        icon={<AlertTriangle className="h-10 w-10 text-amber-600" />}
        title={copy.expiredTitle}
        body={copy.expiredBody}
      />
    )
  }
  if (pageState === 'revoked' || pageState === 'superseded') {
    return (
      <Terminal
        icon={<AlertTriangle className="h-10 w-10 text-amber-600" />}
        title={pageState === 'revoked' ? copy.revokedTitle : copy.supersededTitle}
        body={copy.contactIssuer}
      />
    )
  }

  return (
    <div className="min-h-dvh bg-slate-50 text-slate-900">
      <header className="border-b border-slate-200 bg-white px-4 py-4">
        <div className="mx-auto flex max-w-lg items-center gap-3">
          {payload.tenant.logo_url ? (
            <img
              src={payload.tenant.logo_url}
              alt=""
              className="h-10 w-10 rounded object-contain"
            />
          ) : (
            <div className="flex h-10 w-10 items-center justify-center rounded bg-slate-100">
              <FileText className="h-5 w-5 text-slate-500" />
            </div>
          )}
          <div className="min-w-0">
            <p className="truncate text-sm font-semibold">
              {payload.tenant.name ?? copy.documentFallback}
            </p>
            <p className="truncate text-xs text-slate-500">
              {label} {snap.doc_number ?? ''}
            </p>
          </div>
        </div>
      </header>

      <main className="mx-auto max-w-lg space-y-4 px-4 py-5">
        <section className="rounded-xl border border-slate-200 bg-white p-4 shadow-sm">
          <h1 className="text-lg font-semibold">
            {label} {snap.doc_number ?? ''}
          </h1>
          <p className="mt-1 text-sm text-slate-600">{consequenceCopy(snap, copy)}</p>
          {showPrices && snap.total != null ? (
            <p className="mt-3 text-base font-semibold tabular-nums">
              {Number(snap.total).toLocaleString(locale, {
                style: 'currency',
                currency: snap.currency || 'EUR',
              })}
            </p>
          ) : null}
          {snap.valid_until ? (
            <p className="mt-1 text-xs text-slate-500">
              {fillCopy(copy.validUntil, {
                date: new Date(snap.valid_until).toLocaleDateString(locale),
              })}
            </p>
          ) : null}
          <p className="mt-2 text-xs text-slate-500">
            {fillCopy(copy.expires, {
              date: new Date(payload.expires_at).toLocaleString(locale),
            })}
          </p>
        </section>

        {pdfUrl ? (
          <section className="overflow-hidden rounded-xl border border-slate-200 bg-white shadow-sm">
            <object
              data={pdfUrl}
              type="application/pdf"
              className="h-[min(50dvh,28rem)] w-full"
              aria-label={copy.document}
            >
              <div className="p-4 text-sm text-slate-600">
                <a href={pdfUrl} className="text-sky-700 underline" target="_blank" rel="noreferrer">
                  {copy.downloadPdf}
                </a>
              </div>
            </object>
          </section>
        ) : (
          <p className="text-sm text-slate-500">{copy.pdfPreparing}</p>
        )}

        {errorMsg ? (
          <p
            className="rounded-lg border border-rose-200 bg-rose-50 px-3 py-2 text-sm text-rose-800"
            role="alert"
          >
            {errorMsg}
          </p>
        ) : null}

        {payload.can_decide && pageState === 'ready' && !showDecline ? (
          <section className="space-y-3 rounded-xl border border-slate-200 bg-white p-4 shadow-sm">
            {isDocuseal ? (
              <>
                <p className="text-sm text-slate-600">{copy.continueDocusealHint}</p>
                <button
                  type="button"
                  className="w-full rounded-md bg-slate-900 px-3 py-2.5 text-sm font-medium text-white"
                  onClick={() => void handleContinueDocuseal()}
                >
                  {copy.continueDocuseal}
                </button>
              </>
            ) : (
              <>
                <label className="block space-y-1 text-sm">
                  <span className="font-medium">{copy.fullName}</span>
                  <input
                    className="w-full rounded-md border border-slate-300 px-3 py-2"
                    value={signerName}
                    onChange={(e) => setSignerName(e.target.value)}
                    autoComplete="name"
                  />
                </label>
                <label className="flex items-start gap-2 text-sm">
                  <input
                    type="checkbox"
                    className="mt-1"
                    checked={authorityChecked}
                    onChange={(e) => setAuthorityChecked(e.target.checked)}
                  />
                  <span>{copy.authority}</span>
                </label>
                <SignaturePad
                  onConfirm={(dataUrl) => {
                    void handleAccept(dataUrl)
                  }}
                  disabled={!authorityChecked || !signerName.trim()}
                  title={copy.acceptSign}
                />
              </>
            )}
            <button
              type="button"
              className="w-full rounded-md border border-slate-300 px-3 py-2 text-sm font-medium"
              onClick={() => setShowDecline(true)}
            >
              {copy.refuse}
            </button>
          </section>
        ) : null}

        {payload.can_decide && showDecline ? (
          <section className="space-y-3 rounded-xl border border-slate-200 bg-white p-4 shadow-sm">
            <h2 className="text-base font-semibold">{copy.refuseTitle}</h2>
            <label className="block space-y-1 text-sm">
              <span className="font-medium">{copy.reasonOptional}</span>
              <textarea
                className="w-full rounded-md border border-slate-300 px-3 py-2"
                rows={3}
                value={declineReason}
                onChange={(e) => setDeclineReason(e.target.value)}
              />
            </label>
            <div className="flex gap-2">
              <button
                type="button"
                className="flex-1 rounded-md border border-slate-300 px-3 py-2 text-sm"
                onClick={() => setShowDecline(false)}
                disabled={pageState === 'declining'}
              >
                {copy.back}
              </button>
              <button
                type="button"
                className="flex-1 rounded-md bg-rose-600 px-3 py-2 text-sm font-medium text-white"
                onClick={() => void handleDecline()}
                disabled={pageState === 'declining'}
              >
                {pageState === 'declining' ? copy.saving : copy.confirmRefuse}
              </button>
            </div>
          </section>
        ) : null}

        {(pageState === 'signing' ||
          pageState === 'declining' ||
          pageState === 'waiting_provider') && (
          <div
            className="flex items-center justify-center gap-2 py-6 text-sm text-slate-600"
            aria-live="polite"
          >
            <Loader2 className="h-4 w-4 animate-spin" />
            {pageState === 'waiting_provider' ? copy.waitingProvider : copy.processing}
          </div>
        )}

        <details className="rounded-lg border border-slate-200 bg-white px-3 py-2 text-xs text-slate-600">
          <summary className="cursor-pointer font-medium text-slate-800">
            {copy.privacySummary}
          </summary>
          <p className="mt-2 leading-relaxed">{copy.privacyBody}</p>
        </details>
      </main>
    </div>
  )
}

function Terminal({
  icon,
  title,
  body,
}: {
  icon: ReactNode
  title: string
  body: string
}) {
  return (
    <div className="flex min-h-dvh flex-col items-center justify-center gap-3 bg-slate-50 px-6 text-center">
      {icon}
      <h1 className="text-xl font-semibold text-slate-900">{title}</h1>
      <p className="max-w-sm text-sm text-slate-600">{body}</p>
    </div>
  )
}
