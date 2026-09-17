'use client'

import { useTransition } from 'react'
import { useForm } from 'react-hook-form'
import { zodResolver } from '@hookform/resolvers/zod'
import { z } from 'zod'
import { toast } from 'sonner'
import Link from 'next/link'
import { Loader2, Info } from 'lucide-react'
import { useTranslation } from 'react-i18next'

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

import { updatePdfConverterSettings } from '@/app/admin/actions/pdf-settings'

const schema = z.object({
  native_signing_enabled:    z.boolean(),
  native_evidence_mode:      z.enum(['detached', 'embedded', 'both']),
  remote_signing_token_days: z.coerce.number().int().min(1).max(30),
  legal_footer_text:         z.string().max(500),
})

type FormValues = z.infer<typeof schema>

interface Props {
  pdfEnabled: boolean
  nativeSigningEnabled: boolean
  nativeEvidenceMode: FormValues['native_evidence_mode']
  remoteSigningTokenDays: number
  legalFooterText: string
}

export function AdminNativeSigningSettings({
  pdfEnabled,
  nativeSigningEnabled,
  nativeEvidenceMode,
  remoteSigningTokenDays,
  legalFooterText,
}: Props) {
  const { t } = useTranslation('settings')
  const [isPending, startTransition] = useTransition()

  const {
    register,
    handleSubmit,
    watch,
    setValue,
    formState: { errors },
  } = useForm<FormValues>({
    resolver: zodResolver(schema),
    defaultValues: {
      native_signing_enabled:    nativeSigningEnabled,
      native_evidence_mode:      nativeEvidenceMode,
      remote_signing_token_days: remoteSigningTokenDays,
      legal_footer_text:         legalFooterText,
    },
  })

  const enabled = watch('native_signing_enabled')
  const evidenceMode = watch('native_evidence_mode')

  function onSubmit(values: FormValues) {
    if (!pdfEnabled && values.native_signing_enabled) {
      toast.error(
        t(
          'settings.signing.native.pdf_required',
          'No es pot activar la firma pròpia si la generació PDF no està activa.',
        ),
      )
      return
    }

    startTransition(async () => {
      try {
        await updatePdfConverterSettings({
          native_signing_enabled:    values.native_signing_enabled,
          native_evidence_mode:      values.native_evidence_mode,
          remote_signing_token_days: values.remote_signing_token_days,
          legal_footer_text:         values.legal_footer_text,
        })
        toast.success(
          t('settings.signing.native.toast_success', 'Configuració de Firma Pròpia guardada'),
        )
      } catch (err) {
        toast.error((err as Error).message ?? t('settings.signing.native.toast_error', 'Error guardant configuració'))
      }
    })
  }

  return (
    <form onSubmit={handleSubmit(onSubmit)}>
      <Card>
        <CardHeader>
          <CardTitle>{t('settings.signing.native.title', 'Firma Pròpia')}</CardTitle>
          <CardDescription>
            {t(
              'settings.signing.native.description',
              'Configuració del mòdul de signatura nativa (presencial i remota).',
            )}
          </CardDescription>
        </CardHeader>
        <CardContent className="space-y-4">
          {!pdfEnabled && (
            <div className="rounded-md border bg-amber-50 border-amber-200 p-3 flex gap-2 text-sm text-amber-800">
              <Info className="w-4 h-4 shrink-0 mt-0.5" />
              <div>
                <p className="font-medium">
                  {t(
                    'settings.signing.native.pdf_required',
                    'No es pot activar la firma pròpia si la generació PDF no està activa.',
                  )}
                </p>
                <p className="mt-1">
                  {t(
                    'settings.signing.native.pdf_required_hint',
                    'Activeu primer «Activar generació PDF» a la configuració PDF.',
                  )}{' '}
                  <Link
                    href="/dashboard/settings/pdf"
                    className="font-medium underline underline-offset-2"
                  >
                    {t('settings.signing.native.pdf_settings_link', 'Anar a PDF')}
                  </Link>
                </p>
              </div>
            </div>
          )}

          <div className="flex items-center justify-between">
            <div>
              <p className="text-sm font-medium">
                {t('settings.signing.native.enable_label', 'Activar firma nativa')}
              </p>
              <p className="text-xs text-gray-500">
                {t(
                  'settings.signing.native.enable_hint',
                  'Permet als tenants usar signatures pròpies (presencials i remotes).',
                )}
              </p>
            </div>
            <Switch
              checked={enabled}
              onCheckedChange={(v) => setValue('native_signing_enabled', v)}
              disabled={!pdfEnabled}
            />
          </div>

          <Separator />

          <div className="space-y-2">
            <Label>{t('settings.signing.native.evidence_mode_label', "Mode d'evidències (PDF signat)")}</Label>
            <Select
              value={evidenceMode}
              onValueChange={(v) =>
                setValue('native_evidence_mode', v as FormValues['native_evidence_mode'])
              }
              disabled={!enabled}
            >
              <SelectTrigger>
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value="detached">
                  {t(
                    'settings.signing.native.evidence_detached',
                    "Separat (recomanat) — signatura a l'etiqueta; auditoria en PDF apart",
                  )}
                </SelectItem>
                <SelectItem value="embedded">
                  {t(
                    'settings.signing.native.evidence_embedded',
                    "Incrustat — pàgina d'evidències al final del document",
                  )}
                </SelectItem>
                <SelectItem value="both">
                  {t(
                    'settings.signing.native.evidence_both',
                    "Ambdós — overlay a l'etiqueta i pàgina d'evidències",
                  )}
                </SelectItem>
              </SelectContent>
            </Select>
            <p className="text-xs text-gray-500">
              {t(
                'settings.signing.native.evidence_hint',
                'Amb separat, el PDF firmat queda net (com DocuSeal) i el certificat d\'auditoria es genera per separat.',
              )}
            </p>
          </div>

          <Separator />

          <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
            <div className="space-y-2">
              <Label>
                {t('settings.signing.native.token_days_label', 'Validesa del token de firma (dies)')}
              </Label>
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
            <Label>
              {t(
                'settings.signing.native.legal_footer_label',
                'Text legal al peu de la pàgina de signatura pública',
              )}
            </Label>
            <textarea
              {...register('legal_footer_text')}
              rows={3}
              className="w-full rounded-md border border-input bg-background px-3 py-2 text-sm"
              placeholder={t(
                'settings.signing.native.legal_footer_placeholder',
                'En signar aquest document...',
              )}
            />
            {errors.legal_footer_text && (
              <p className="text-sm text-red-600">{errors.legal_footer_text.message}</p>
            )}
          </div>
        </CardContent>
        <CardFooter className="justify-end">
          <Button type="submit" disabled={isPending}>
            {isPending && <Loader2 className="w-4 h-4 animate-spin mr-2" />}
            {t('settings.signing.native.save', 'Guardar configuració')}
          </Button>
        </CardFooter>
      </Card>
    </form>
  )
}
