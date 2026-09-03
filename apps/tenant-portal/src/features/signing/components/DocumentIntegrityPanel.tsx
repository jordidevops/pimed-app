import { useCallback, useEffect, useRef, useState } from 'react'
import { useTranslation } from 'react-i18next'
import {
  CheckCircle2, XCircle, Loader2, Copy, Check, Upload, FileSearch, Info,
} from 'lucide-react'
import { Button } from '@/components/ui/button'
import { useToast } from '@/hooks/use-toast'
import { supabase } from '@/lib/supabase'
import {
  fetchSignatureAuditForSubmission,
  type SignatureAuditRecord,
} from '../api/signingService'
import { hashesMatch, sha256HexFromBuffer } from '../utils/sha256Hex'
import { nativeSignerRoleLabel } from '../utils/signerRoleLabel'

type VerifyState = 'idle' | 'computing' | 'match' | 'mismatch' | 'error'

interface Props {
  submissionId: string
  submissionStatus: string
  resultFilePath?: string | null
  resultStorageType?: string | null
  /** Sense capçalera pròpia (dins d'un tab) */
  embedded?: boolean
}

function HashRow({
  label,
  value,
  mono = true,
}: {
  label: string
  value: string | null | undefined
  mono?: boolean
}) {
  const [copied, setCopied] = useState(false)

  if (!value) return null

  return (
    <div className="space-y-1">
      <p className="text-xs font-medium text-muted-foreground">{label}</p>
      <div className="flex items-start gap-2">
        <code
          className={`flex-1 text-[11px] break-all bg-muted/50 rounded px-2 py-1.5 ${mono ? 'font-mono' : ''}`}
        >
          {value}
        </code>
        <Button
          type="button"
          variant="ghost"
          size="icon"
          className="h-8 w-8 shrink-0"
          title="Copiar"
          onClick={() => {
            void navigator.clipboard.writeText(value).then(() => {
              setCopied(true)
              setTimeout(() => setCopied(false), 2000)
            })
          }}
        >
          {copied ? <Check className="h-3.5 w-3.5 text-green-600" /> : <Copy className="h-3.5 w-3.5" />}
        </Button>
      </div>
    </div>
  )
}

export function DocumentIntegrityPanel({
  submissionId,
  submissionStatus,
  resultFilePath,
  resultStorageType,
  embedded = false,
}: Props) {
  const { t } = useTranslation('signing')
  const { toast } = useToast()
  const fileInputRef = useRef<HTMLInputElement>(null)

  const [records, setRecords]       = useState<SignatureAuditRecord[]>([])
  const [loading, setLoading]       = useState(true)
  const [loadError, setLoadError]   = useState<string | null>(null)
  const [verifyState, setVerifyState] = useState<VerifyState>('idle')
  const [computedHash, setComputedHash] = useState<string | null>(null)

  const loadAudit = useCallback(async () => {
    setLoading(true)
    setLoadError(null)
    try {
      const rows = await fetchSignatureAuditForSubmission(submissionId)
      setRecords(rows.sort((a, b) => (a.signer_order ?? 0) - (b.signer_order ?? 0)))
    } catch (err) {
      setLoadError((err as Error).message)
      setRecords([])
    } finally {
      setLoading(false)
    }
  }, [submissionId])

  useEffect(() => {
    void loadAudit()
  }, [loadAudit])

  if (submissionStatus !== 'completed') {
    return null
  }

  const sorted = records
  const firstRecord = sorted[0]
  const lastRecord  = sorted[sorted.length - 1]
  const referenceHash = lastRecord?.document_hash_after ?? null
  const canVerify = Boolean(referenceHash)
  const isComplete = submissionStatus === 'completed'
  const isMulti = sorted.length > 1

  async function verifyAgainstReference(getBuffer: () => Promise<ArrayBuffer>) {
    if (!referenceHash) return
    setVerifyState('computing')
    setComputedHash(null)
    try {
      const buffer = await getBuffer()
      const hash = await sha256HexFromBuffer(buffer)
      setComputedHash(hash)
      setVerifyState(hashesMatch(hash, referenceHash) ? 'match' : 'mismatch')
    } catch (err) {
      setVerifyState('error')
      toast({
        variant: 'destructive',
        title: t('integrity.verifyError', 'Error comprovant el fitxer'),
        description: (err as Error).message,
      })
    }
  }

  async function handleVerifyStoredPdf() {
    if (!resultFilePath || resultStorageType === 'external_link') return
    await verifyAgainstReference(async () => {
      const { data, error } = await supabase.storage
        .from('documents')
        .download(resultFilePath)
      if (error || !data) throw new Error(error?.message ?? 'No s\'ha pogut baixar el PDF')
      return data.arrayBuffer()
    })
  }

  async function handleVerifyUploadedFile(file: File) {
    await verifyAgainstReference(() => file.arrayBuffer())
  }

  return (
    <div className="space-y-2">
      {!embedded && (
        <h2 className="text-sm font-semibold uppercase tracking-wide text-muted-foreground flex items-center gap-1.5">
          <FileSearch className="h-4 w-4 text-indigo-600" />
          {t('integrity.title', 'Integritat del document')}
        </h2>
      )}

      <div className="rounded-xl border bg-card p-4 space-y-4">
        {loading && (
          <div className="flex items-center gap-2 text-sm text-muted-foreground py-2">
            <Loader2 className="h-4 w-4 animate-spin" />
            {t('integrity.loading', 'Carregant registres d\'auditoria...')}
          </div>
        )}

        {!loading && loadError && (
          <p className="text-sm text-red-600">{loadError}</p>
        )}

        {!loading && !loadError && sorted.length === 0 && (
          <p className="text-sm text-muted-foreground">
            {t('integrity.noRecords', 'Encara no hi ha registres d\'auditoria. Apareixeran després de la primera signatura.')}
          </p>
        )}

        {!loading && sorted.length > 0 && (
          <>
            <div className="rounded-md bg-blue-50 border border-blue-100 px-3 py-2 text-xs text-blue-900 flex gap-2">
              <Info className="h-4 w-4 shrink-0 mt-0.5" />
              <p>
                {isMulti
                  ? t(
                      'integrity.multiSignerHelp',
                      'En signatura seqüencial, cada signant estampa sobre la versió anterior. El hash de referència és el del darrer signant (document lliurat).',
                    )
                  : t(
                      'integrity.singleSignerHelp',
                      'El hash «després» és la referència d\'integritat del PDF signat lliurat.',
                    )}
              </p>
            </div>

            <div className="grid gap-3 sm:grid-cols-2">
              <HashRow
                label={t('integrity.hashBeforeFirst', 'Hash abans (1r signant)')}
                value={firstRecord?.document_hash_before}
              />
              <HashRow
                label={
                  isComplete
                    ? t('integrity.hashAfterFinal', 'Hash després (referència final)')
                    : t('integrity.hashAfterLatest', 'Hash després (últim signant registrat)')
                }
                value={referenceHash}
              />
            </div>

            {sorted.length > 1 && (
              <div className="space-y-2">
                <p className="text-xs font-semibold text-muted-foreground uppercase tracking-wide">
                  {t('integrity.perSigner', 'Per signant')}
                </p>
                <div className="rounded-lg border divide-y text-sm">
                  {sorted.map((r) => (
                    <div key={r.session_id} className="px-3 py-2.5 space-y-1">
                      <p className="font-medium">
                        {(r.signer_order ?? 0) + 1}. {r.signer_name || r.signer_email || '—'}
                        {r.signer_role && (
                          <span className="text-muted-foreground font-normal ml-1">
                            ({nativeSignerRoleLabel(r.signer_role)})
                          </span>
                        )}
                      </p>
                      {r.document_hash_after && (
                        <p className="text-[11px] font-mono text-muted-foreground break-all">
                          SHA-256: {r.document_hash_after}
                        </p>
                      )}
                    </div>
                  ))}
                </div>
              </div>
            )}

            {canVerify && (
              <div className="space-y-3 pt-2 border-t">
                <p className="text-sm font-medium">{t('integrity.verifyTitle', 'Comprovar fitxer')}</p>
                <p className="text-xs text-muted-foreground">
                  {t(
                    'integrity.verifyDesc',
                    'Compareu un PDF amb el hash de referència (SHA-256). Podeu verificar el document del sistema o pujar una còpia local.',
                  )}
                </p>

                <div className="flex flex-wrap gap-2">
                  {resultFilePath && resultStorageType !== 'external_link' && (
                    <Button
                      type="button"
                      variant="outline"
                      size="sm"
                      disabled={verifyState === 'computing'}
                      onClick={() => void handleVerifyStoredPdf()}
                    >
                      {verifyState === 'computing' ? (
                        <Loader2 className="h-3.5 w-3.5 mr-1.5 animate-spin" />
                      ) : (
                        <FileSearch className="h-3.5 w-3.5 mr-1.5" />
                      )}
                      {t('integrity.verifyStored', 'Verificar PDF del sistema')}
                    </Button>
                  )}

                  <Button
                    type="button"
                    variant="outline"
                    size="sm"
                    disabled={verifyState === 'computing'}
                    onClick={() => fileInputRef.current?.click()}
                  >
                    <Upload className="h-3.5 w-3.5 mr-1.5" />
                    {t('integrity.verifyUpload', 'Pujar fitxer PDF')}
                  </Button>
                  <input
                    ref={fileInputRef}
                    type="file"
                    accept="application/pdf,.pdf"
                    className="hidden"
                    onChange={(e) => {
                      const file = e.target.files?.[0]
                      e.target.value = ''
                      if (file) void handleVerifyUploadedFile(file)
                    }}
                  />
                </div>

                {verifyState === 'match' && (
                  <div className="flex items-center gap-2 text-sm text-green-700 bg-green-50 border border-green-200 rounded-md px-3 py-2">
                    <CheckCircle2 className="h-4 w-4 shrink-0" />
                    {t('integrity.match', 'El fitxer coincideix amb el hash de referència.')}
                  </div>
                )}
                {verifyState === 'mismatch' && (
                  <div className="space-y-2">
                    <div className="flex items-center gap-2 text-sm text-red-700 bg-red-50 border border-red-200 rounded-md px-3 py-2">
                      <XCircle className="h-4 w-4 shrink-0" />
                      {t('integrity.mismatch', 'El fitxer NO coincideix amb el hash de referència.')}
                    </div>
                    {computedHash && (
                      <p className="text-[11px] font-mono text-muted-foreground break-all">
                        {t('integrity.computedHash', 'Hash calculat')}: {computedHash}
                      </p>
                    )}
                  </div>
                )}

              </div>
            )}

            {!canVerify && sorted.length > 0 && (
              <p className="text-xs text-muted-foreground">
                {t('integrity.waitingHash', 'El hash de referència estarà disponible quan es registri la primera signatura completa.')}
              </p>
            )}
          </>
        )}

        <Button type="button" variant="ghost" size="sm" onClick={() => void loadAudit()}>
          {t('integrity.refresh', 'Actualitzar')}
        </Button>
      </div>
    </div>
  )
}

/** Missatge per submissions DocuSeal (hash només native). */
export function DocuSealIntegrityNote() {
  const { t } = useTranslation('signing')
  return (
    <div className="rounded-lg border bg-muted/30 px-3 py-2 text-sm text-muted-foreground flex gap-2">
      <Info className="h-4 w-4 shrink-0 mt-0.5" />
      <p>
        {t(
          'integrity.docusealOnly',
          'La verificació d\'integritat per hash SHA-256 està disponible per a submissions de firma pròpia.',
        )}
      </p>
    </div>
  )
}
