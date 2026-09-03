'use client'

import { useState, useTransition } from 'react'
import { useForm } from 'react-hook-form'
import { zodResolver } from '@hookform/resolvers/zod'
import { z } from 'zod'
import { toast } from 'sonner'
import { Loader2, CheckCircle, XCircle, Wifi, RefreshCw, Info } from 'lucide-react'

import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Switch } from '@/components/ui/switch'
import { Separator } from '@/components/ui/separator'
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from '@/components/ui/select'
import {
  Card,
  CardContent,
  CardDescription,
  CardFooter,
  CardHeader,
  CardTitle,
} from '@/components/ui/card'

import type { PdfConverterSettings, GotenbergHealthResult } from '@/app/admin/actions/pdf-settings'
import {
  updatePdfConverterSettings,
  testGotenbergConnection,
  retryPdfDeadLetters,
} from '@/app/admin/actions/pdf-settings'

// =============================================================================
// Zod Schema
// =============================================================================

const schema = z.object({
  pdf_enabled:               z.boolean(),
  native_signing_enabled:    z.boolean(),
  native_evidence_mode:      z.enum(['detached', 'embedded', 'both']),
  gotenberg_url:             z.string().url('URL invàlida (ha de ser http:// o https://)'),
  gotenberg_auth_type:       z.enum(['none', 'bearer', 'cf_service_token']),
  gotenberg_auth_secret_ref: z.string().nullable().optional(),
  paper_size:                z.enum(['A4', 'A3', 'Letter']),
  sync_html_max_kb:          z.coerce.number().int().min(100).max(5000),
  timeout_ms:                z.coerce.number().int().min(5000).max(300000),
  remote_signing_token_days: z.coerce.number().int().min(1).max(30),
  legal_footer_text:         z.string().max(500),
})

type FormValues = z.infer<typeof schema>

// =============================================================================
// Props
// =============================================================================

interface Props {
  initialSettings: PdfConverterSettings
}

// =============================================================================
// Badge de connexió
// =============================================================================

function ConnectionBadge({ result }: { result: GotenbergHealthResult | null }) {
  if (!result) return null

  if (result.accessible) {
    return (
      <div className="flex items-center gap-2 text-sm text-green-700 bg-green-50 border border-green-200 rounded-md px-3 py-2">
        <CheckCircle className="w-4 h-4 shrink-0" />
        <span>
          Accessible{result.version ? ` (v${result.version})` : ''}{' '}
          {result.latencyMs != null ? `· ${result.latencyMs}ms` : ''}
        </span>
      </div>
    )
  }

  return (
    <div className="flex items-center gap-2 text-sm text-red-700 bg-red-50 border border-red-200 rounded-md px-3 py-2">
      <XCircle className="w-4 h-4 shrink-0" />
      <span>No accessible: {result.error ?? 'Error desconegut'}</span>
    </div>
  )
}

// =============================================================================
// Component principal
// =============================================================================

export function AdminPdfSettings({ initialSettings }: Props) {
  const [isPending, startTransition] = useTransition()
  const [isTesting, setIsTesting] = useState(false)
  const [isRetrying, setIsRetrying] = useState(false)
  const [healthResult, setHealthResult] = useState<GotenbergHealthResult | null>(null)

  const {
    register,
    handleSubmit,
    watch,
    setValue,
    formState: { errors },
  } = useForm<FormValues>({
    resolver: zodResolver(schema),
    defaultValues: {
      pdf_enabled:               initialSettings.pdf_enabled,
      native_signing_enabled:    initialSettings.native_signing_enabled,
      native_evidence_mode:      initialSettings.native_evidence_mode,
      gotenberg_url:             initialSettings.gotenberg_url,
      gotenberg_auth_type:       initialSettings.gotenberg_auth_type,
      gotenberg_auth_secret_ref: initialSettings.gotenberg_auth_secret_ref ?? '',
      paper_size:                initialSettings.paper_size,
      sync_html_max_kb:          initialSettings.sync_html_max_kb,
      timeout_ms:                initialSettings.timeout_ms,
      remote_signing_token_days: initialSettings.remote_signing_token_days,
      legal_footer_text:         initialSettings.legal_footer_text,
    },
  })

  const pdfEnabled            = watch('pdf_enabled')
  const nativeSigningEnabled  = watch('native_signing_enabled')
  const evidenceMode          = watch('native_evidence_mode')
  const authType              = watch('gotenberg_auth_type')
  const gotenbergUrl          = watch('gotenberg_url')

  function onSubmit(values: FormValues) {
    startTransition(async () => {
      try {
        await updatePdfConverterSettings({
          pdf_enabled:               values.pdf_enabled,
          native_signing_enabled:    values.native_signing_enabled,
          native_evidence_mode:      values.native_evidence_mode,
          gotenberg_url:             values.gotenberg_url,
          gotenberg_auth_type:       values.gotenberg_auth_type,
          gotenberg_auth_secret_ref: values.gotenberg_auth_secret_ref || null,
          paper_size:                values.paper_size,
          sync_html_max_kb:          values.sync_html_max_kb,
          timeout_ms:                values.timeout_ms,
          remote_signing_token_days: values.remote_signing_token_days,
          legal_footer_text:         values.legal_footer_text,
        })
        toast.success('Configuració PDF guardada correctament')
      } catch (err) {
        toast.error((err as Error).message ?? 'Error guardant configuració')
      }
    })
  }

  async function handleTestConnection() {
    setIsTesting(true)
    setHealthResult(null)
    try {
      const result = await testGotenbergConnection(gotenbergUrl, authType)
      setHealthResult(result)
    } catch (err) {
      setHealthResult({ accessible: false, error: (err as Error).message })
    } finally {
      setIsTesting(false)
    }
  }

  async function handleRetryDeadLetters() {
    setIsRetrying(true)
    try {
      const count = await retryPdfDeadLetters()
      toast.success(`${count} jobs dead-letter reiniciats`)
    } catch (err) {
      toast.error((err as Error).message ?? 'Error reintentant jobs')
    } finally {
      setIsRetrying(false)
    }
  }

  return (
    <form onSubmit={handleSubmit(onSubmit)} className="space-y-8">

      {/* ── Secció 1: Estat del servei ────────────────────────────────────────── */}
      <Card>
        <CardHeader>
          <CardTitle>Estat del servei</CardTitle>
          <CardDescription>
            Comprova la connectivitat des de l&apos;admin (host). En local usa{' '}
            <code className="text-xs bg-gray-100 px-1 rounded">http://localhost:3007</code>.
            Les Edge Functions en dev ignoren aquest camp i usen{' '}
            <code className="text-xs bg-gray-100 px-1 rounded">GOTENBERG_URL</code> a{' '}
            <code className="text-xs bg-gray-100 px-1 rounded">supabase/functions/.env.local</code>.
          </CardDescription>
        </CardHeader>
        <CardContent className="space-y-4">
          <div className="space-y-2">
            <Label>URL de Gotenberg</Label>
            <div className="flex gap-2">
              <Input
                {...register('gotenberg_url')}
                placeholder="http://localhost:3007"
                className="font-mono text-sm"
              />
              <Button
                type="button"
                variant="outline"
                onClick={handleTestConnection}
                disabled={isTesting}
                className="shrink-0"
              >
                {isTesting ? (
                  <Loader2 className="w-4 h-4 animate-spin" />
                ) : (
                  <Wifi className="w-4 h-4" />
                )}
                <span className="ml-2">Provar connexió</span>
              </Button>
            </div>
            {errors.gotenberg_url && (
              <p className="text-sm text-red-600">{errors.gotenberg_url.message}</p>
            )}
          </div>

          <ConnectionBadge result={healthResult} />
        </CardContent>
      </Card>

      {/* ── Secció 2: Autenticació ───────────────────────────────────────────── */}
      <Card>
        <CardHeader>
          <CardTitle>Autenticació</CardTitle>
          <CardDescription>
            El secret mai es guarda en clar. Usa una referència{' '}
            <code className="text-xs bg-gray-100 px-1 rounded">env://VAR_NAME</code> o{' '}
            <code className="text-xs bg-gray-100 px-1 rounded">vault://path/to/secret</code>.
          </CardDescription>
        </CardHeader>
        <CardContent className="space-y-4">
          <div className="space-y-2">
            <Label>Tipus d&apos;autenticació</Label>
            <Select
              value={authType}
              onValueChange={(v) =>
                setValue('gotenberg_auth_type', v as 'none' | 'bearer' | 'cf_service_token')
              }
            >
              <SelectTrigger>
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value="none">Cap autenticació</SelectItem>
                <SelectItem value="bearer">Bearer Token (Caddy)</SelectItem>
                <SelectItem value="cf_service_token">Cloudflare Service Token</SelectItem>
              </SelectContent>
            </Select>
          </div>

          {authType !== 'none' && (
            <div className="space-y-2">
              <Label>
                Referència al secret{' '}
                {authType === 'cf_service_token' && (
                  <span className="text-xs text-gray-500">
                    (ID|Secret, ex: env://CF_CLIENT_ID|env://CF_CLIENT_SECRET)
                  </span>
                )}
              </Label>
              <Input
                {...register('gotenberg_auth_secret_ref')}
                placeholder={
                  authType === 'bearer'
                    ? 'env://GOTENBERG_BEARER_TOKEN'
                    : 'env://CF_CLIENT_ID|env://CF_CLIENT_SECRET'
                }
                className="font-mono text-sm"
              />
            </div>
          )}
        </CardContent>
      </Card>

      {/* ── Secció 3: Configuració PDF ───────────────────────────────────────── */}
      <Card>
        <CardHeader>
          <CardTitle>Configuració PDF</CardTitle>
          <CardDescription>
            Perfils de sortida, mida de pàgina i llindars de conversió síncrona.
          </CardDescription>
        </CardHeader>
        <CardContent className="space-y-4">
          <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
            <div className="space-y-2">
              <Label>Mida de pàgina</Label>
              <Select
                defaultValue={initialSettings.paper_size}
                onValueChange={(v) => setValue('paper_size', v as 'A4' | 'A3' | 'Letter')}
              >
                <SelectTrigger>
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  <SelectItem value="A4">A4 (210×297mm)</SelectItem>
                  <SelectItem value="A3">A3 (297×420mm)</SelectItem>
                  <SelectItem value="Letter">Letter (215.9×279.4mm)</SelectItem>
                </SelectContent>
              </Select>
            </div>

            <div className="space-y-2">
              <Label>Llindar síncron HTML (KB)</Label>
              <Input
                {...register('sync_html_max_kb')}
                type="number"
                min={100}
                max={5000}
                step={100}
              />
              <p className="text-xs text-gray-500">
                HTML per sota d&apos;aquest llindar es converteix síncronament. Defecte: 500 KB.
              </p>
              {errors.sync_html_max_kb && (
                <p className="text-sm text-red-600">{errors.sync_html_max_kb.message}</p>
              )}
            </div>

            <div className="space-y-2">
              <Label>Timeout de conversió (ms)</Label>
              <Input
                {...register('timeout_ms')}
                type="number"
                min={5000}
                max={300000}
                step={1000}
              />
              {errors.timeout_ms && (
                <p className="text-sm text-red-600">{errors.timeout_ms.message}</p>
              )}
            </div>
          </div>

          <div className="rounded-md border bg-amber-50 border-amber-200 p-3 flex gap-2 text-sm text-amber-800">
            <Info className="w-4 h-4 shrink-0 mt-0.5" />
            <div>
              <strong>Perfils de sortida (no editables):</strong>{' '}
              Documents no signats → <code>pdf</code> · Documents signats → <code>pdfa2b</code> · Auditoria → <code>pdfa3b</code>.
              Aquests valors estan fixats per optimitzar l&apos;espai de Storage.
            </div>
          </div>
        </CardContent>
      </Card>

      {/* ── Secció 4: Firma Pròpia ───────────────────────────────────────────── */}
      <Card>
        <CardHeader>
          <CardTitle>Firma Pròpia</CardTitle>
          <CardDescription>
            Configuració del mòdul de signatura nativa (presencial i remota).
          </CardDescription>
        </CardHeader>
        <CardContent className="space-y-4">
          <div className="flex items-center justify-between">
            <div>
              <p className="text-sm font-medium">Activar firma nativa</p>
              <p className="text-xs text-gray-500">
                Permet als tenants usar signatures pròpies (presencials i remotes).
              </p>
            </div>
            <Switch
              checked={nativeSigningEnabled}
              onCheckedChange={(v) => setValue('native_signing_enabled', v)}
              disabled={!pdfEnabled}
            />
          </div>

          <Separator />

          <div className="space-y-2">
            <Label>Mode d&apos;evidències (PDF signat)</Label>
            <Select
              value={evidenceMode}
              onValueChange={(v) => setValue('native_evidence_mode', v as FormValues['native_evidence_mode'])}
              disabled={!nativeSigningEnabled}
            >
              <SelectTrigger>
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value="detached">
                  Separat (recomanat) — signatura a l&apos;etiqueta; auditoria en PDF apart
                </SelectItem>
                <SelectItem value="embedded">
                  Incrustat — pàgina d&apos;evidències al final del document
                </SelectItem>
                <SelectItem value="both">
                  Ambdós — overlay a l&apos;etiqueta i pàgina d&apos;evidències
                </SelectItem>
              </SelectContent>
            </Select>
            <p className="text-xs text-gray-500">
              Amb <strong>separat</strong>, el PDF firmat queda net (com DocuSeal) i el certificat
              d&apos;auditoria es genera per separat.
            </p>
          </div>

          <Separator />

          <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
            <div className="space-y-2">
              <Label>Validesa del token de firma (dies)</Label>
              <Input
                {...register('remote_signing_token_days')}
                type="number"
                min={1}
                max={30}
              />
              {errors.remote_signing_token_days && (
                <p className="text-sm text-red-600">{errors.remote_signing_token_days.message}</p>
              )}
            </div>
          </div>

          <div className="space-y-2">
            <Label>Text legal al peu de la pàgina de signatura pública</Label>
            <textarea
              {...register('legal_footer_text')}
              rows={3}
              className="w-full rounded-md border border-input bg-background px-3 py-2 text-sm"
              placeholder="En signar aquest document..."
            />
            {errors.legal_footer_text && (
              <p className="text-sm text-red-600">{errors.legal_footer_text.message}</p>
            )}
          </div>
        </CardContent>
      </Card>

      {/* ── Secció 5: Controls de sistema ───────────────────────────────────── */}
      <Card>
        <CardHeader>
          <CardTitle>Controls de sistema</CardTitle>
        </CardHeader>
        <CardContent className="space-y-4">
          <div className="flex items-center justify-between">
            <div>
              <p className="text-sm font-medium">Activar generació PDF</p>
              <p className="text-xs text-gray-500">
                Si desactivat, tot funciona en format natiu (HTML/DOCX). Jobs pendents
                passen a <code>skipped</code>.
              </p>
            </div>
            <Switch
              checked={pdfEnabled}
              onCheckedChange={(v) => {
                setValue('pdf_enabled', v)
                if (!v) setValue('native_signing_enabled', false)
              }}
            />
          </div>

          <Separator />

          <div className="flex items-center justify-between">
            <div>
              <p className="text-sm font-medium">Reintentar jobs dead-letter</p>
              <p className="text-xs text-gray-500">
                Torna a la cua tots els jobs fallits per errors de Gotenberg.
              </p>
            </div>
            <Button
              type="button"
              variant="outline"
              size="sm"
              onClick={handleRetryDeadLetters}
              disabled={isRetrying}
            >
              {isRetrying ? (
                <Loader2 className="w-4 h-4 animate-spin mr-2" />
              ) : (
                <RefreshCw className="w-4 h-4 mr-2" />
              )}
              Reintentar
            </Button>
          </div>
        </CardContent>
        <CardFooter className="justify-end">
          <Button type="submit" disabled={isPending}>
            {isPending && <Loader2 className="w-4 h-4 animate-spin mr-2" />}
            Guardar configuració
          </Button>
        </CardFooter>
      </Card>
    </form>
  )
}
