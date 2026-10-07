'use client'

import Link from 'next/link'
import { useRouter } from 'next/navigation'
import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import type { TenantPublicProfile } from '@/lib/constants'
import type { PendingDecisionDetail } from '@/lib/resolver'
import { LocaleSwitcher } from '@/components/LocaleSwitcher'
import { PortalFooter } from '@/components/PortalFooter'
import { CookieNotice } from '@/components/CookieNotice'
import { SignaturePad } from '@/components/SignaturePad'

const DOCUSEAL_WAIT_PREFIX = 'cp_docuseal_wait_'

function waitKey(requestId: string): string {
  return `${DOCUSEAL_WAIT_PREFIX}${requestId}`
}

function formatDate(iso: string | null | undefined, locale: string): string {
  if (!iso) return ''
  const d = new Date(iso)
  if (!Number.isFinite(d.getTime())) return ''
  const tag = locale === 'en' ? 'en-GB' : locale === 'es' ? 'es-ES' : 'ca-ES'
  return d.toLocaleDateString(tag, {
    day: 'numeric',
    month: 'short',
    year: 'numeric',
  })
}

function formatMoney(
  total: number | null | undefined,
  currency: string | null | undefined,
  locale: string,
): string {
  if (total == null) return ''
  const tag = locale === 'en' ? 'en-GB' : locale === 'es' ? 'es-ES' : 'ca-ES'
  try {
    return new Intl.NumberFormat(tag, {
      style: 'currency',
      currency: currency || 'EUR',
    }).format(total)
  } catch {
    return `${total} ${currency || ''}`.trim()
  }
}

type Props = {
  detail: PendingDecisionDetail
  uiLocale: string
  allowClientLocaleChange?: boolean
  supportedLocales?: string[]
  accountContactId?: string
  tenantId?: string
  tenantProfile?: TenantPublicProfile | null
  staffPreview?: boolean
  principalKind?: string | null
}

export function PendingDecisionDetailView({
  detail: initial,
  uiLocale,
  allowClientLocaleChange,
  supportedLocales,
  accountContactId,
  tenantId,
  tenantProfile,
  staffPreview,
  principalKind,
}: Props) {
  const { t } = useTranslation('common')
  const router = useRouter()
  const [detail, setDetail] = useState(initial)
  const [showDecline, setShowDecline] = useState(false)
  const [showAccept, setShowAccept] = useState(false)
  const [reason, setReason] = useState('')
  const [actorName, setActorName] = useState('')
  const [actorRole, setActorRole] = useState('')
  const [authorityChecked, setAuthorityChecked] = useState(false)
  const [busy, setBusy] = useState(false)
  const [waitingProvider, setWaitingProvider] = useState(false)
  const [errorMsg, setErrorMsg] = useState<string | null>(null)

  const showSwitcher =
    allowClientLocaleChange === true &&
    Boolean(accountContactId) &&
    Boolean(tenantId) &&
    Array.isArray(supportedLocales) &&
    supportedLocales.length > 1

  const title =
    detail.label ||
    detail.snapshot?.doc_number ||
    t('pending.untitled', 'Document pendent')

  const sharedMailbox = principalKind === 'shared_mailbox'
  const isTerminal =
    detail.status === 'accepted' || detail.status === 'declined'
  const canDecline =
    !staffPreview &&
    detail.decline_available === true &&
    detail.status === 'open'
  const canAccept =
    !staffPreview &&
    detail.accept_available === true &&
    detail.status === 'open'
  const canContinueDocuseal =
    !staffPreview &&
    detail.provider_continue_available === true &&
    detail.status === 'open'

  const pdfHref = detail.has_pdf
    ? `/api/commercial/pdf?action=get_pending_decision&id=${encodeURIComponent(detail.request_id)}`
    : null

  useEffect(() => {
    if (staffPreview || isTerminal) return
    try {
      if (sessionStorage.getItem(waitKey(detail.request_id)) === '1') {
        setWaitingProvider(true)
      }
    } catch {
      /* ignore */
    }
  }, [detail.request_id, staffPreview, isTerminal])

  useEffect(() => {
    if (!waitingProvider || staffPreview || isTerminal) return
    let cancelled = false
    let ticks = 0
    const maxTicks = 40
    const timer = window.setInterval(() => {
      void (async () => {
        ticks += 1
        try {
          const res = await fetch('/api/commercial/decide', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
              action: 'status',
              request_id: detail.request_id,
            }),
          })
          const data = (await res.json().catch(() => ({}))) as {
            status?: string
            decided_via?: string | null
            decided_at?: string | null
            receipt?: PendingDecisionDetail['receipt']
            provider_continue_available?: boolean
            decline_available?: boolean
            accept_available?: boolean
            can_decide?: boolean
          }
          if (cancelled || !res.ok) return
          if (data.status === 'accepted' || data.status === 'declined') {
            window.clearInterval(timer)
            try {
              sessionStorage.removeItem(waitKey(detail.request_id))
            } catch {
              /* ignore */
            }
            setWaitingProvider(false)
            setDetail((prev) => ({
              ...prev,
              status: data.status!,
              can_decide: false,
              decline_available: false,
              accept_available: false,
              provider_continue_available: false,
              decide_available: false,
              decided_at: data.decided_at ?? prev.decided_at,
              decided_via: data.decided_via ?? prev.decided_via,
              receipt: data.receipt ?? {
                outcome: data.status!,
                decided_at: data.decided_at ?? null,
                decided_via: data.decided_via ?? null,
                signer_name: null,
                reason: null,
                trace_id: prev.receipt?.trace_id ?? null,
              },
            }))
            router.refresh()
            return
          }
          setDetail((prev) => ({
            ...prev,
            provider_continue_available:
              data.provider_continue_available === true,
            decline_available: data.decline_available === true,
            accept_available: data.accept_available === true,
            can_decide: data.can_decide === true,
          }))
          if (ticks >= maxTicks) {
            window.clearInterval(timer)
            setWaitingProvider(false)
            try {
              sessionStorage.removeItem(waitKey(detail.request_id))
            } catch {
              /* ignore */
            }
            setErrorMsg(
              t(
                'pending.waiting_provider_timeout',
                'Encara processem la resposta. Torna a aquesta pàgina d’aquí uns minuts.',
              ),
            )
          }
        } catch {
          /* keep polling */
        }
      })()
    }, 3000)
    return () => {
      cancelled = true
      window.clearInterval(timer)
    }
  }, [waitingProvider, staffPreview, isTerminal, detail.request_id, router, t])

  function requireActorFields(): boolean {
    if (!sharedMailbox) return true
    if (actorName.trim().length < 2 || actorRole.trim().length < 2) {
      setErrorMsg(
        t(
          'pending.actor_required',
          'Indica el nom i el càrrec de qui actua en nom del compte.',
        ),
      )
      return false
    }
    return true
  }

  async function handleContinueDocuseal() {
    setBusy(true)
    setErrorMsg(null)
    try {
      const res = await fetch('/api/commercial/decide', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          action: 'continue_docuseal',
          request_id: detail.request_id,
        }),
      })
      const data = (await res.json().catch(() => ({}))) as {
        error?: string
        redirect_url?: string
        already_decided?: boolean
        status?: string
        decided_via?: string | null
        decided_at?: string | null
      }
      if (!res.ok) {
        throw new Error(
          data.error === 'provider_pending'
            ? t(
                'pending.provider_pending',
                'L’enllaç de firma encara no està llest. Torna-ho a provar en uns segons.',
              )
            : data.error === 'provider_not_docuseal'
              ? t(
                  'pending.continue_failed',
                  'No s’ha pogut obrir DocuSeal',
                )
              : data.error ||
                t('pending.continue_failed', 'No s’ha pogut obrir DocuSeal'),
        )
      }
      if (data.already_decided === true) {
        const outcome =
          data.status === 'accepted' || data.status === 'declined'
            ? data.status
            : detail.status
        setDetail((prev) => ({
          ...prev,
          status: outcome,
          can_decide: false,
          decline_available: false,
          accept_available: false,
          provider_continue_available: false,
          decide_available: false,
          decided_at: data.decided_at ?? prev.decided_at,
          decided_via: data.decided_via ?? prev.decided_via,
        }))
        router.refresh()
        return
      }
      const url =
        typeof data.redirect_url === 'string' ? data.redirect_url.trim() : ''
      if (!url) {
        throw new Error(
          t(
            'pending.provider_pending',
            'L’enllaç de firma encara no està llest. Torna-ho a provar en uns segons.',
          ),
        )
      }
      try {
        sessionStorage.setItem(waitKey(detail.request_id), '1')
      } catch {
        /* ignore */
      }
      setWaitingProvider(true)
      window.location.assign(url)
    } catch (err) {
      setErrorMsg(
        err instanceof Error
          ? err.message
          : t('pending.continue_failed', 'No s’ha pogut obrir DocuSeal'),
      )
    } finally {
      setBusy(false)
    }
  }

  async function handleAccept(signatureDataUrl: string) {
    if (!authorityChecked) {
      setErrorMsg(
        t(
          'pending.authority_required',
          'Cal confirmar que tens autoritat per acceptar.',
        ),
      )
      return
    }
    if (!requireActorFields()) return
    setBusy(true)
    setErrorMsg(null)
    try {
      const res = await fetch('/api/commercial/decide', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          action: 'accept',
          request_id: detail.request_id,
          signature_base64: signatureDataUrl,
          actor_name: sharedMailbox ? actorName.trim() : null,
          actor_role: sharedMailbox
            ? actorRole.trim()
            : actorRole.trim() || null,
        }),
      })
      const data = (await res.json().catch(() => ({}))) as {
        error?: string
        status?: string
        decided_via?: string | null
        decided_at?: string | null
      }
      if (!res.ok) {
        throw new Error(
          data.error === 'native_session_missing'
            ? t(
                'pending.session_missing',
                'Encara no hi ha sessió de firma preparada. Usa l’enllaç del correu o demana un nou enviament.',
              )
            : data.error === 'actor_name_required' ||
                data.error === 'actor_role_required'
              ? t(
                  'pending.actor_required',
                  'Indica el nom i el càrrec de qui actua en nom del compte.',
                )
              : data.error === 'apply_failed'
                ? t(
                    'pending.accept_failed',
                    'No s\'ha pogut acceptar',
                  )
                : data.error ||
                  t('pending.accept_failed', 'No s\'ha pogut acceptar'),
        )
      }
      if (data.status !== 'accepted' && data.status !== 'declined') {
        throw new Error(
          t('pending.accept_failed', 'No s\'ha pogut acceptar'),
        )
      }
      const outcome = data.status
      setDetail((prev) => ({
        ...prev,
        status: outcome,
        can_decide: false,
        decline_available: false,
        accept_available: false,
        provider_continue_available: false,
        decide_available: false,
        decided_at: data.decided_at ?? prev.decided_at,
        decided_via: data.decided_via ?? prev.decided_via,
        receipt: {
          outcome,
          decided_at: data.decided_at ?? null,
          decided_via: data.decided_via ?? null,
          signer_name: sharedMailbox ? actorName.trim() : null,
          reason: null,
          trace_id: prev.receipt?.trace_id ?? null,
        },
      }))
      setShowAccept(false)
      router.refresh()
    } catch (err) {
      setErrorMsg(
        err instanceof Error
          ? err.message
          : t('pending.accept_failed', 'No s\'ha pogut acceptar'),
      )
    } finally {
      setBusy(false)
    }
  }

  async function handleDecline() {
    if (!requireActorFields()) return
    setBusy(true)
    setErrorMsg(null)
    try {
      const res = await fetch('/api/commercial/decide', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          action: 'decline',
          request_id: detail.request_id,
          reason: reason.trim() || null,
          actor_name: sharedMailbox ? actorName.trim() : null,
          actor_role: sharedMailbox ? actorRole.trim() : actorRole.trim() || null,
        }),
      })
      const data = (await res.json().catch(() => ({}))) as {
        error?: string
        status?: string
        already_decided?: boolean
        decided_via?: string | null
        decided_at?: string | null
      }
      if (!res.ok) {
        throw new Error(
          data.error === 'actor_name_required' || data.error === 'actor_role_required'
            ? t(
                'pending.actor_required',
                'Indica el nom i el càrrec de qui actua en nom del compte.',
              )
            : data.error || t('pending.decline_failed', 'No s\'ha pogut refusar'),
        )
      }
      if (data.status !== 'accepted' && data.status !== 'declined') {
        throw new Error(
          t('pending.decline_failed', 'No s\'ha pogut refusar'),
        )
      }
      const outcome = data.status
      setDetail((prev) => ({
        ...prev,
        status: outcome,
        can_decide: false,
        decline_available: false,
        accept_available: false,
        provider_continue_available: false,
        decide_available: false,
        decided_at: data.decided_at ?? prev.decided_at,
        decided_via: data.decided_via ?? prev.decided_via,
        receipt: {
          outcome,
          decided_at: data.decided_at ?? null,
          decided_via: data.decided_via ?? null,
          reason: reason.trim() || null,
          signer_name: sharedMailbox ? actorName.trim() : null,
          trace_id: prev.receipt?.trace_id ?? null,
        },
      }))
      setShowDecline(false)
      router.refresh()
    } catch (err) {
      setErrorMsg(
        err instanceof Error
          ? err.message
          : t('pending.decline_failed', 'No s\'ha pogut refusar'),
      )
    } finally {
      setBusy(false)
    }
  }

  return (
    <main className="mx-auto max-w-2xl px-4 py-8 sm:py-12">
      <header className="border-b border-[var(--line)] pb-6">
        <div className="flex items-baseline justify-between gap-4">
          <div>
            <p className="sans text-xs uppercase tracking-[0.18em] text-[var(--muted)]">
              {staffPreview
                ? t('staff_list.eyebrow', 'Vista de suport')
                : t('pending.eyebrow', 'Resposta pendent')}
            </p>
            <h1 className="mt-2 text-3xl font-semibold tracking-tight sm:text-4xl">
              {title}
            </h1>
            <p className="sans mt-2 text-sm text-[var(--muted)]">
              {[
                detail.tenant?.name || detail.tenant_name,
                formatMoney(detail.total, detail.currency, uiLocale),
                detail.expires_at && !isTerminal
                  ? `${t('pending.expires', 'Caduca')} ${formatDate(detail.expires_at, uiLocale)}`
                  : null,
              ]
                .filter(Boolean)
                .join(' · ')}
            </p>
          </div>
          <div className="flex shrink-0 flex-col items-end gap-3">
            {showSwitcher && accountContactId && tenantId && (
              <LocaleSwitcher
                currentLocale={uiLocale}
                supportedLocales={supportedLocales!}
                accountContactId={accountContactId}
                tenantId={tenantId}
              />
            )}
            <a
              href="/api/logout"
              className="sans text-sm text-[var(--muted)] underline-offset-2 hover:underline"
            >
              {t('nav.logout', 'Tancar sessió')}
            </a>
          </div>
        </div>
        <p className="sans mt-4 text-sm">
          <Link
            href="/dashboard/pending"
            className="text-[var(--muted)] underline-offset-2 hover:underline"
          >
            ← {t('pending.back', 'Tornar a pendents')}
          </Link>
        </p>
      </header>

      {detail.expires_soon && !isTerminal && (
        <p className="sans mt-4 text-sm text-[var(--accent)]">
          {t('pending.expires_soon', 'Caduca aviat')}
        </p>
      )}

      {sharedMailbox && !staffPreview && !isTerminal && (
        <p className="sans mt-4 text-sm text-[var(--muted)]">
          {t(
            'pending.shared_mailbox_acting',
            'Estàs actuant en nom de {{account}}.',
            { account: detail.account_name || t('pending.account', 'aquest compte') },
          )}
        </p>
      )}

      <section className="mt-8 space-y-2 text-sm">
        {detail.snapshot?.valid_until && (
          <p>
            <span className="text-[var(--muted)]">
              {t('commercial.valid_until', 'Vàlid fins')}
            </span>{' '}
            {formatDate(detail.snapshot.valid_until, uiLocale)}
          </p>
        )}
        {detail.purpose && (
          <p>
            <span className="text-[var(--muted)]">
              {t('pending.purpose', 'Tipus')}
            </span>{' '}
            {t(`pending.purpose_${detail.purpose}`, detail.purpose)}
          </p>
        )}
      </section>

      {pdfHref ? (
        <p className="mt-6">
          <a
            href={pdfHref}
            target="_blank"
            rel="noopener noreferrer"
            className="sans inline-flex text-[var(--accent)] underline-offset-2 hover:underline"
          >
            {t('commercial.download_pdf', 'Descarregar PDF')}
          </a>
        </p>
      ) : (
        <p className="sans mt-6 text-sm text-[var(--muted)]">
          {t('commercial.no_pdf', 'Encara no hi ha PDF disponible.')}
        </p>
      )}

      {isTerminal ? (
        <section className="mt-8 rounded-lg border border-[var(--line)] px-4 py-4">
          <p className="text-lg font-semibold">
            {detail.status === 'accepted'
              ? t('pending.outcome_accepted', 'Acceptat')
              : t('pending.outcome_declined', 'Refusat')}
          </p>
          <p className="sans mt-2 text-sm text-[var(--muted)]">
            {[
              detail.receipt?.decided_at || detail.decided_at
                ? formatDate(
                    detail.receipt?.decided_at || detail.decided_at,
                    uiLocale,
                  )
                : null,
              detail.receipt?.decided_via || detail.decided_via
                ? t(
                    `pending.via_${detail.receipt?.decided_via || detail.decided_via}`,
                    detail.receipt?.decided_via || detail.decided_via || '',
                  )
                : null,
            ]
              .filter(Boolean)
              .join(' · ')}
          </p>
          {detail.receipt?.signer_name && (
            <p className="sans mt-2 text-sm">
              {t('pending.signer', 'Qui ha respost')}: {detail.receipt.signer_name}
            </p>
          )}
          {detail.receipt?.reason && (
            <p className="sans mt-2 text-sm">
              {t('pending.reason', 'Motiu')}: {detail.receipt.reason}
            </p>
          )}
        </section>
      ) : (
        <section className="mt-8 space-y-4">
          {staffPreview ? (
            <p className="sans text-sm text-[var(--muted)]">
              {t(
                'pending.staff_cannot_decide',
                'Vista de suport: no pots acceptar ni refusar; el client ho fa des del seu accés o de l’enllaç.',
              )}
            </p>
          ) : waitingProvider ? (
            <p className="sans text-sm text-[var(--muted)]">
              {t(
                'pending.waiting_provider',
                'Processant la resposta del proveïdor…',
              )}
            </p>
          ) : (
            <>
              {canContinueDocuseal && !showDecline && (
                <p className="sans text-sm text-[var(--muted)]">
                  {t(
                    'pending.continue_docuseal_hint',
                    'Revisaràs i signaràs el document en un servei extern. Quan acabis, torna a aquesta pàgina si cal.',
                  )}
                </p>
              )}
              {!canAccept && !canContinueDocuseal && canDecline && (
                <p className="sans text-sm text-[var(--muted)]">
                  {t(
                    'pending.accept_link_only',
                    'Pots refusar aquí. Per acceptar amb firma, usa l’enllaç del correu (o demana un nou enviament si no el tens).',
                  )}
                </p>
              )}
              <div className="flex flex-wrap gap-4">
                {canContinueDocuseal && !showDecline && (
                  <button
                    type="button"
                    disabled={busy}
                    className="sans rounded bg-[var(--accent)] px-4 py-2 text-sm text-white disabled:opacity-50"
                    onClick={() => void handleContinueDocuseal()}
                  >
                    {busy
                      ? t('pending.continuing', 'Obrint…')
                      : t(
                          'pending.continue_docuseal',
                          'Continuar a DocuSeal',
                        )}
                  </button>
                )}
                {canAccept && !showAccept && !showDecline && (
                  <button
                    type="button"
                    className="sans rounded bg-[var(--accent)] px-4 py-2 text-sm text-white"
                    onClick={() => {
                      setShowAccept(true)
                      setShowDecline(false)
                      setErrorMsg(null)
                    }}
                  >
                    {t('pending.accept_cta', 'Acceptar i firmar')}
                  </button>
                )}
                {canDecline && !showDecline && !showAccept && (
                  <button
                    type="button"
                    className="sans text-sm text-[var(--muted)] underline-offset-2 hover:underline"
                    onClick={() => {
                      setShowDecline(true)
                      setShowAccept(false)
                      setErrorMsg(null)
                    }}
                  >
                    {t('pending.decline_cta', 'Refusar')}
                  </button>
                )}
              </div>
              {showAccept && (
                <div className="space-y-4 rounded-lg border border-[var(--line)] px-4 py-4">
                  {sharedMailbox && (
                    <>
                      <label className="sans block text-sm">
                        {t('pending.actor_name', 'Nom i cognoms')}
                        <input
                          className="mt-1 w-full border border-[var(--line)] bg-transparent px-3 py-2"
                          value={actorName}
                          onChange={(e) => setActorName(e.target.value)}
                          autoComplete="name"
                        />
                      </label>
                      <label className="sans block text-sm">
                        {t('pending.actor_role', 'Càrrec / representació')}
                        <input
                          className="mt-1 w-full border border-[var(--line)] bg-transparent px-3 py-2"
                          value={actorRole}
                          onChange={(e) => setActorRole(e.target.value)}
                        />
                      </label>
                    </>
                  )}
                  <label className="sans flex items-start gap-2 text-sm">
                    <input
                      type="checkbox"
                      className="mt-1"
                      checked={authorityChecked}
                      onChange={(e) => setAuthorityChecked(e.target.checked)}
                    />
                    <span>
                      {t(
                        'pending.authority_checkbox',
                        'Confirmo que tinc autoritat per acceptar aquest document en nom del compte.',
                      )}
                    </span>
                  </label>
                  <SignaturePad
                    disabled={busy}
                    onConfirm={(sig) => void handleAccept(sig)}
                    onCancel={() => setShowAccept(false)}
                    title={t('pending.sign_title', 'La teva signatura')}
                    subtitle={t(
                      'pending.sign_subtitle',
                      'Dibuixa amb el dit, el llapis o el ratolí',
                    )}
                    confirmLabel={t(
                      'pending.sign_confirm',
                      'Confirmar i acceptar',
                    )}
                    clearLabel={t('pending.sign_clear', 'Esborrar')}
                    cancelLabel={t('pending.cancel', 'Cancel·lar')}
                    drawHint={t(
                      'pending.sign_hint',
                      'Dibuixa aquí la teva signatura',
                    )}
                  />
                </div>
              )}
              {showDecline && (
                <div className="space-y-3 rounded-lg border border-[var(--line)] px-4 py-4">
                  <p className="font-medium">
                    {t('pending.decline_confirm', 'Confirmes que vols refusar?')}
                  </p>
                  {sharedMailbox && (
                    <>
                      <label className="sans block text-sm">
                        {t('pending.actor_name', 'Nom i cognoms')}
                        <input
                          className="mt-1 w-full border border-[var(--line)] bg-transparent px-3 py-2"
                          value={actorName}
                          onChange={(e) => setActorName(e.target.value)}
                          autoComplete="name"
                        />
                      </label>
                      <label className="sans block text-sm">
                        {t('pending.actor_role', 'Càrrec / representació')}
                        <input
                          className="mt-1 w-full border border-[var(--line)] bg-transparent px-3 py-2"
                          value={actorRole}
                          onChange={(e) => setActorRole(e.target.value)}
                        />
                      </label>
                    </>
                  )}
                  <label className="sans block text-sm">
                    {t('pending.reason_optional', 'Motiu (opcional)')}
                    <textarea
                      className="mt-1 w-full border border-[var(--line)] bg-transparent px-3 py-2"
                      rows={3}
                      value={reason}
                      onChange={(e) => setReason(e.target.value)}
                    />
                  </label>
                  <div className="flex flex-wrap gap-3">
                    <button
                      type="button"
                      disabled={busy}
                      className="sans rounded bg-[var(--accent)] px-4 py-2 text-sm text-white disabled:opacity-50"
                      onClick={() => void handleDecline()}
                    >
                      {busy
                        ? t('pending.declining', 'Refusant…')
                        : t('pending.decline_confirm_action', 'Sí, refusar')}
                    </button>
                    <button
                      type="button"
                      disabled={busy}
                      className="sans text-sm text-[var(--muted)] underline-offset-2 hover:underline"
                      onClick={() => setShowDecline(false)}
                    >
                      {t('pending.cancel', 'Cancel·lar')}
                    </button>
                  </div>
                </div>
              )}
            </>
          )}
          {errorMsg && (
            <p className="sans text-sm text-red-700" role="alert">
              {errorMsg}
            </p>
          )}
        </section>
      )}

      <PortalFooter
        profile={tenantProfile}
        tenantId={tenantId}
        locale={uiLocale}
        showAccessLink
      />
      <CookieNotice tenantId={tenantId} locale={uiLocale} />
    </main>
  )
}

export function PendingDecisionUnavailable({
  variant,
}: {
  variant: 'not_found' | 'need_session' | 'expired'
}) {
  const { t } = useTranslation('common')
  const message =
    variant === 'need_session'
      ? t(
          'dashboard.need_session',
          'Cal una sessió de client per veure els butlletins.',
        )
      : variant === 'expired'
        ? t(
            'dashboard.session_expired',
            'La sessió ha caducat o no és vàlida. Torna a accedir.',
          )
        : t(
            'pending.not_found',
            'Aquesta sol·licitud ja no és disponible o ha caducat.',
          )
  return (
    <main className="mx-auto max-w-2xl px-4 py-16">
      <p className="text-[var(--muted)]">{message}</p>
      <p className="mt-6">
        <Link
          href="/dashboard"
          className="sans text-[var(--accent)] underline-offset-2 hover:underline"
        >
          ← {t('nav.back_to_dashboard', '← Dashboard').replace(/^←\s*/, '')}
        </Link>
      </p>
    </main>
  )
}
