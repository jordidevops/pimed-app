/**
 * Pàgina pública de signatura: /sign/:token
 *
 * Accessible sense autenticació.
 * Usa el client Supabase amb la clau publishable per als RPC públics
 * i Edge Functions per al PDF i la signatura final.
 *
 * Flux:
 *   1. Carrega → api.get_signing_session_public(token) → mostra PDF
 *   2. Usuari dibuixa signatura → POST stamp-pdf-signatures
 *   3. Registre d'evidències en cada pas (link_opened, document_viewed, signed)
 */

import { useEffect, useState, useRef } from 'react'
import { useParams } from 'react-router-dom'
import { Loader2, CheckCircle, XCircle, AlertTriangle, FileText } from 'lucide-react'
import { SignaturePad } from '../features/signing/components/SignaturePad'
import { nativeSignerRoleLabel } from '../features/signing/utils/signerRoleLabel'
import { supabase } from '../lib/supabase'

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

interface SessionPublic {
  session_id: string
  tenant_id:  string
  document_version_id: string
  signing_type: 'presential' | 'remote'
  status: string
  signer_name: string | null
  signer_role: string | null
  signer_order?: number | null
  total_signers?: number | null
  expires_at: string
}

type PageState =
  | 'loading'
  | 'ready'
  | 'signing'
  | 'declining'
  | 'signed'
  | 'declined'
  | 'already_signed'
  | 'expired'
  | 'error'

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

const SUPABASE_URL = import.meta.env.VITE_SUPABASE_URL as string
const SUPABASE_KEY = import.meta.env.VITE_SUPABASE_PUBLISHABLE_DEFAULT_KEY as string

function anonymizeIp(ip: string): string {
  // IPv4: ocultar últim octet
  return ip.replace(/(\d+\.\d+\.\d+\.)\d+/, '$1x')
}

async function logSigningEvidence(args: {
  p_session_id: string
  p_event_type: string
  p_ip_address?: string
  p_user_agent?: string
  p_geolocation?: { lat: number; lon: number } | null
}): Promise<void> {
  try {
    const { error } = await supabase.rpc('log_signing_evidence', {
      p_session_id: args.p_session_id,
      p_event_type: args.p_event_type,
      p_ip_address: args.p_ip_address || undefined,
      p_user_agent: args.p_user_agent,
      p_geolocation: args.p_geolocation ?? undefined,
    })
    if (error) throw error
  } catch {
    // ignore evidence logging failures
  }
}

// ---------------------------------------------------------------------------
// Component principal
// ---------------------------------------------------------------------------

export function PublicSignPage() {
  const { token } = useParams<{ token: string }>()
  const [pageState, setPageState] = useState<PageState>('loading')
  const [session,   setSession]   = useState<SessionPublic | null>(null)
  const [pdfUrl,    setPdfUrl]    = useState<string | null>(null)
  const [errorMsg,  setErrorMsg]  = useState<string | null>(null)
  const [signedAt,  setSignedAt]  = useState<string | null>(null)
  const [allSignersComplete, setAllSignersComplete] = useState(true)
  const [showDeclineForm, setShowDeclineForm] = useState(false)
  const [declineReason, setDeclineReason] = useState('')
  const [geoEnabled,setGeoEnabled]= useState(false)
  const [geo,       setGeo]       = useState<{ lat: number; lon: number } | null>(null)
  const docViewedRef = useRef(false)
  const clientIp     = useRef<string>('')

  // ── 1. Validar token al carregar ──────────────────────────────────────────
  useEffect(() => {
    if (!token) { setPageState('error'); setErrorMsg('Token invàlid'); return }

    // Intercanvi de token: netejar URL per evitar exposició en logs/historial
    window.history.replaceState({}, '', window.location.pathname)

    void (async () => {
      try {
        let ip = ''
        try {
          const d = await fetch('https://api.ipify.org?format=json').then((r) => r.json()) as { ip: string }
          ip = d.ip
          clientIp.current = ip
        } catch {
          // ignore IP lookup failures
        }

        const { data, error } = await supabase.rpc('get_signing_session_public', { p_token: token })
        if (error) throw new Error(error.message)
        const payload = data as Record<string, unknown> | null
        if (!payload) throw new Error('Resposta buida')

        if (payload.error === 'already_signed') {
          setSignedAt(payload.timestamp_signed as string ?? null)
          setPageState('already_signed')
          return
        }
        if (payload.error === 'session_declined') { setPageState('declined'); return }
        if (payload.error === 'token_expired') { setPageState('expired'); return }
        if (payload.error) { setPageState('error'); setErrorMsg(payload.error as string); return }

        const sess = payload as unknown as SessionPublic
        setSession(sess)

        await logSigningEvidence({
          p_session_id: sess.session_id,
          p_event_type: 'link_opened',
          p_ip_address: ip || undefined,
          p_user_agent: navigator.userAgent,
        })

        const pdfRes = await fetch(`${SUPABASE_URL}/functions/v1/get-document-url`, {
          method:  'POST',
          headers: { 'Content-Type': 'application/json', 'apikey': SUPABASE_KEY, 'Authorization': `Bearer ${SUPABASE_KEY}` },
          body:    JSON.stringify({
            version_id:    sess.document_version_id,
            signing_token: token,
            source:        'preview',
          }),
        }).catch(() => null)

        if (pdfRes?.ok) {
          const pdfData = await pdfRes.json() as { url?: string }
          setPdfUrl(pdfData.url ?? null)
        } else {
          const errBody = pdfRes ? await pdfRes.json().catch(() => null) as { error?: { message?: string } } | null : null
          console.warn('[PublicSignPage] PDF preview failed:', errBody?.error?.message ?? pdfRes?.status)
        }

        setPageState('ready')
      } catch (err) {
        setPageState('error')
        setErrorMsg((err as Error).message)
      }
    })()
  }, [token])

  // ── 2. Registrar document_viewed quan el PDF es mostra ────────────────────
  useEffect(() => {
    if (pageState !== 'ready' || docViewedRef.current || !session) return
    docViewedRef.current = true
    void logSigningEvidence({
      p_session_id: session.session_id,
      p_event_type: 'document_viewed',
      p_ip_address: clientIp.current || undefined,
      p_user_agent: navigator.userAgent,
    })
  }, [pageState, session])

  // ── 3. Geolocalització (opcional) ─────────────────────────────────────────
  function requestGeo() {
    if (!navigator.geolocation) return
    navigator.geolocation.getCurrentPosition(
      (pos) => {
        setGeo({ lat: pos.coords.latitude, lon: pos.coords.longitude })
        setGeoEnabled(true)
      },
      () => {},
      { timeout: 5000 },
    )
  }

  // ── 4. Enviar signatura ───────────────────────────────────────────────────
  async function handleSign(signatureBase64: string) {
    if (!session) return
    setPageState('signing')

    try {
      // Evidència: signature_drawn
      await logSigningEvidence({
        p_session_id: session.session_id,
        p_event_type: 'signature_drawn',
        p_ip_address: clientIp.current || undefined,
        p_user_agent: navigator.userAgent,
        p_geolocation: geo ? { lat: geo.lat, lon: geo.lon } : null,
      })

      // Cridar Edge Function process-signing-token
      const res = await fetch(`${SUPABASE_URL}/functions/v1/process-signing-token`, {
        method:  'POST',
        headers: {
          'Content-Type': 'application/json',
          'apikey':        SUPABASE_KEY,
          'Authorization': `Bearer ${SUPABASE_KEY}`,
        },
        body: JSON.stringify({
          token:              token,
          signature_base64:   signatureBase64,
          ip_address:         clientIp.current || null,
          user_agent:         navigator.userAgent,
          geolocation:        geo,
        }),
      })

      const data = await res.json() as { success?: boolean; error?: string; all_signed?: boolean }
      if (!res.ok || !data.success) {
        if (data.error === 'already_signed') {
          setPageState('already_signed')
          return
        }
        throw new Error(data.error ?? 'Error en la signatura')
      }

      setSignedAt(new Date().toISOString())
      setPageState('signed')
      setAllSignersComplete(data.all_signed !== false)
    } catch (err) {
      setErrorMsg((err as Error).message)
      setPageState('error')
    }
  }

  async function handleDecline() {
    if (!session || !token) return
    setPageState('declining')

    try {
      const res = await fetch(`${SUPABASE_URL}/functions/v1/process-signing-token`, {
        method:  'POST',
        headers: {
          'Content-Type': 'application/json',
          'apikey':        SUPABASE_KEY,
          'Authorization': `Bearer ${SUPABASE_KEY}`,
        },
        body: JSON.stringify({
          token,
          action:     'decline',
          reason:     declineReason.trim() || null,
          ip_address: clientIp.current || null,
          user_agent: navigator.userAgent,
        }),
      })

      const data = await res.json() as { success?: boolean; error?: string }
      if (!res.ok || !data.success) {
        throw new Error(data.error ?? 'No s\'ha pogut rebutjar la signatura')
      }

      setPageState('declined')
    } catch (err) {
      setErrorMsg((err as Error).message)
      setPageState('error')
    }
  }

  // ── Render ────────────────────────────────────────────────────────────────

  if (pageState === 'loading') {
    return (
      <PublicLayout>
        <div className="flex flex-col items-center gap-4 py-12">
          <Loader2 className="w-10 h-10 animate-spin text-indigo-500" />
          <p className="text-gray-600">Carregant document...</p>
        </div>
      </PublicLayout>
    )
  }

  if (pageState === 'already_signed') {
    return (
      <PublicLayout>
        <div className="flex flex-col items-center gap-4 py-12 text-center">
          <CheckCircle className="w-16 h-16 text-green-500" />
          <h2 className="text-xl font-semibold">Document ja signat</h2>
          <p className="text-gray-600 max-w-sm">
            Aquest document ja va ser signat el{' '}
            {signedAt ? new Date(signedAt).toLocaleDateString('ca-ES', { dateStyle: 'long' }) : 'anteriorment'}.
          </p>
          <p className="text-sm text-gray-500">
            Podeu sol·licitar una còpia a l&apos;empresa que us va enviar el document.
          </p>
        </div>
      </PublicLayout>
    )
  }

  if (pageState === 'expired') {
    return (
      <PublicLayout>
        <div className="flex flex-col items-center gap-4 py-12 text-center">
          <AlertTriangle className="w-16 h-16 text-amber-500" />
          <h2 className="text-xl font-semibold">Enllaç caducat</h2>
          <p className="text-gray-600 max-w-sm">
            L&apos;enllaç de signatura ha caducat. Contacteu l&apos;empresa per a un nou enviament.
          </p>
        </div>
      </PublicLayout>
    )
  }

  if (pageState === 'declined') {
    return (
      <PublicLayout>
        <div className="flex flex-col items-center gap-4 py-12 text-center">
          <XCircle className="w-16 h-16 text-amber-600" />
          <h2 className="text-xl font-semibold">Signatura rebutjada</h2>
          <p className="text-gray-600 max-w-sm">
            Heu indicat que no voleu signar aquest document. L&apos;empresa emissora ha estat notificada.
          </p>
          <p className="text-sm text-gray-400">Podeu tancar aquesta finestra.</p>
        </div>
      </PublicLayout>
    )
  }

  if (pageState === 'signed') {
    return (
      <PublicLayout>
        <div className="flex flex-col items-center gap-4 py-12 text-center">
          <CheckCircle className="w-16 h-16 text-green-500" />
          <h2 className="text-xl font-semibold text-green-700">Document signat correctament</h2>
          <p className="text-gray-600 max-w-sm">
            La vostra signatura ha estat registrada el{' '}
            {signedAt ? new Date(signedAt).toLocaleString('ca-ES') : 'ara'}.
            {allSignersComplete
              ? ' Rebreu una còpia del document signat per correu electrònic.'
              : ' El document passarà al següent signant. Rebreu el document signat per correu quan tothom hagi signat.'}
          </p>
          <p className="text-sm text-gray-400">Podeu tancar aquesta finestra.</p>
        </div>
      </PublicLayout>
    )
  }

  if (pageState === 'error') {
    return (
      <PublicLayout>
        <div className="flex flex-col items-center gap-4 py-12 text-center">
          <XCircle className="w-16 h-16 text-red-500" />
          <h2 className="text-xl font-semibold">Error</h2>
          <p className="text-gray-600 max-w-sm">{errorMsg ?? 'Error desconegut. Torneu-ho a intentar.'}</p>
        </div>
      </PublicLayout>
    )
  }

  // pageState === 'ready' o 'signing'
  const roleLabel = nativeSignerRoleLabel(session?.signer_role, session?.signer_name)
  const signerIndex = (session?.signer_order ?? 0) + 1
  const totalSigners = session?.total_signers ?? 1
  const isSequential = totalSigners > 1

  return (
    <PublicLayout>
      <div className="max-w-2xl mx-auto space-y-6">
        {/* Encapçalament */}
        <div className="text-center">
          <FileText className="w-8 h-8 text-indigo-500 mx-auto mb-2" />
          <h2 className="text-xl font-semibold">Signatura de document</h2>
          {session?.signer_name && (
            <p className="text-gray-600 mt-1">
              Hola, <strong>{session.signer_name}</strong>.
              {isSequential && (
                <> Signant <strong>{signerIndex}</strong> de <strong>{totalSigners}</strong>.</>
              )}
            </p>
          )}
          <p className="text-sm text-indigo-700 mt-2 font-medium">
            Esteu signant com a: <span className="underline decoration-dotted">{roleLabel}</span>
          </p>
          <p className="text-xs text-gray-500 mt-1 max-w-md mx-auto">
            Al PDF, la vostra signatura s&apos;incrustarà a la caixa de signatura etiquetada
            «{roleLabel}» (línia discontínua).
          </p>
        </div>

        {/* Visor PDF */}
        {pdfUrl ? (
          <div className="rounded-lg border shadow overflow-hidden" style={{ height: 500 }}>
            <iframe
              src={pdfUrl}
              title="Document a signar"
              className="w-full h-full"
            />
          </div>
        ) : (
          <div className="rounded-lg border bg-gray-50 flex flex-col items-center justify-center gap-2" style={{ height: 200 }}>
            <p className="text-gray-500 text-sm">No s&apos;ha pogut carregar la vista prèvia del document.</p>
            <p className="text-gray-400 text-xs">Podeu continuar signant; la signatura s&apos;aplicarà al document correcte.</p>
          </div>
        )}

        {/* Geolocalització (optional) */}
        {!geoEnabled && (
          <div className="flex items-center gap-3 rounded-md bg-blue-50 border border-blue-200 px-4 py-3 text-sm">
            <span className="text-blue-700 flex-1">
              Podeu compartir la vostra ubicació per reforçar la validesa de la signatura (opcional).
            </span>
            <button
              type="button"
              onClick={requestGeo}
              className="shrink-0 text-blue-700 font-medium underline hover:no-underline"
            >
              Compartir ubicació
            </button>
          </div>
        )}

        {/* SignaturePad */}
        <div className="rounded-lg border bg-white p-4 shadow-sm space-y-4">
          <SignaturePad
            title={`Signatura — ${roleLabel}`}
            subtitle={`Dibuixeu la signatura que apareixerà a l'etiqueta «${roleLabel}» del document`}
            width={580}
            height={180}
            onConfirm={handleSign}
            disabled={pageState === 'signing' || pageState === 'declining'}
          />

          {!showDeclineForm ? (
            <div className="pt-2 border-t text-center">
              <button
                type="button"
                onClick={() => setShowDeclineForm(true)}
                disabled={pageState === 'signing' || pageState === 'declining'}
                className="text-sm text-gray-500 hover:text-red-600 underline disabled:opacity-50"
              >
                No vull signar aquest document
              </button>
            </div>
          ) : (
            <div className="pt-2 border-t space-y-3">
              <p className="text-sm font-medium text-gray-700">Rebutjar signatura</p>
              <textarea
                className="w-full rounded-md border px-3 py-2 text-sm min-h-[72px]"
                placeholder="Motiu del rebuig (opcional)"
                value={declineReason}
                onChange={(e) => setDeclineReason(e.target.value)}
                disabled={pageState === 'declining'}
              />
              <div className="flex gap-2 justify-end">
                <button
                  type="button"
                  onClick={() => { setShowDeclineForm(false); setDeclineReason('') }}
                  disabled={pageState === 'declining'}
                  className="px-3 py-1.5 text-sm rounded-md border hover:bg-gray-50 disabled:opacity-50"
                >
                  Cancel·lar
                </button>
                <button
                  type="button"
                  onClick={() => void handleDecline()}
                  disabled={pageState === 'declining'}
                  className="px-3 py-1.5 text-sm rounded-md bg-red-600 text-white hover:bg-red-700 disabled:opacity-50 flex items-center gap-1.5"
                >
                  {pageState === 'declining' && <Loader2 className="w-3.5 h-3.5 animate-spin" />}
                  Confirmar rebuig
                </button>
              </div>
            </div>
          )}
        </div>

        {/* Peu legal */}
        <div className="text-xs text-gray-400 text-center space-y-1">
          <p>
            En signar aquest document, accepteu que la vostra signatura electrònica té validesa
            en el context de la relació comercial amb l&apos;empresa emissora.
          </p>
          {clientIp.current && (
            <p>Data: {new Date().toLocaleString('ca-ES')} · IP: {anonymizeIp(clientIp.current)}</p>
          )}
        </div>
      </div>
    </PublicLayout>
  )
}

// ---------------------------------------------------------------------------
// Layout mínim per a pàgina pública
// ---------------------------------------------------------------------------

function PublicLayout({ children }: { children: React.ReactNode }) {
  return (
    <div className="min-h-screen bg-gray-50">
      {/* Header mínim */}
      <header className="bg-white border-b px-6 py-4 flex items-center gap-3">
        <div className="w-6 h-6 bg-indigo-600 rounded-md" />
        <span className="font-semibold text-gray-800">Portal de Signatura</span>
      </header>

      {/* Contingut */}
      <main className="max-w-3xl mx-auto px-4 py-8">
        {children}
      </main>

      {/* Footer */}
      <footer className="text-center text-xs text-gray-400 py-6">
        Signatura electrònica simple · Reglament eIDAS (UE) 910/2014
      </footer>
    </div>
  )
}
