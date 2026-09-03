'use client'

import { useState, useTransition } from 'react'
import { useForm } from 'react-hook-form'
import { zodResolver } from '@hookform/resolvers/zod'
import { z } from 'zod'
import { toast } from 'sonner'
import { Loader2 } from 'lucide-react'
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

import type { RateLimitingSettings, EmailModuleSettings } from '@/app/admin/actions/email-settings'
import {
  updateRateLimitingSettings,
  updateEmailModuleSettings,
} from '@/app/admin/actions/email-settings'

// =============================================================================
// Zod Schemas
// =============================================================================

export const rateLimitingSchema = z.object({
  rate_limiting_enabled: z.boolean(),
  rate_limit_engine: z.enum(['redis', 'postgres']),
  fallback_to_postgres: z.boolean(),
})

export const emailModuleSchema = z
  .object({
    platform_default_domain: z
      .string()
      .min(1, 'El domini és obligatori')
      .regex(
        /^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$/,
        'Format de domini invàlid (ex: example.com)',
      ),
    platform_default_from_email: z
      .string()
      .min(1, "L'email és obligatori")
      .email("Format d'email invàlid"),
    platform_default_from_name: z.string().min(1, 'El nom del remitent és obligatori').max(100),
  })
  .superRefine((data, ctx) => {
    const emailDomain = data.platform_default_from_email.split('@')[1]?.toLowerCase()
    const platformDomain = data.platform_default_domain.toLowerCase()
    if (emailDomain && platformDomain && emailDomain !== platformDomain) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        path: ['platform_default_from_email'],
        message: `L'email ha de pertànyer al domini de la plataforma (@${platformDomain})`,
      })
    }
  })

type RateLimitingForm = z.infer<typeof rateLimitingSchema>
type EmailModuleForm = z.infer<typeof emailModuleSchema>

// =============================================================================
// Props
// =============================================================================

interface AdminEmailSettingsProps {
  initialRateLimiting: RateLimitingSettings
  initialEmail: EmailModuleSettings
}

// =============================================================================
// FieldRow — helper per a files de formulari amb label + descripció
// =============================================================================

function FieldRow({
  label,
  description,
  error,
  children,
}: {
  label: string
  description?: string
  error?: string
  children: React.ReactNode
}) {
  return (
    <div className="grid gap-1.5">
      <Label className="text-sm font-medium text-foreground">{label}</Label>
      {children}
      {description && !error && (
        <p className="text-xs text-muted-foreground">{description}</p>
      )}
      {error && <p className="text-xs text-destructive">{error}</p>}
    </div>
  )
}

// =============================================================================
// SwitchRow — fila amb Switch + label + descripció
// =============================================================================

function SwitchRow({
  label,
  description,
  checked,
  onCheckedChange,
  disabled,
}: {
  label: string
  description: string
  checked: boolean
  onCheckedChange: (v: boolean) => void
  disabled?: boolean
}) {
  return (
    <div className="flex items-start justify-between gap-4 py-3">
      <div className="min-w-0">
        <p className="text-sm font-medium text-foreground">{label}</p>
        <p className="text-xs text-muted-foreground mt-0.5">{description}</p>
      </div>
      <Switch
        checked={checked}
        onCheckedChange={onCheckedChange}
        disabled={disabled}
        className="mt-0.5 shrink-0"
      />
    </div>
  )
}

// =============================================================================
// RateLimitingCard
// =============================================================================

function RateLimitingCard({ initialData }: { initialData: RateLimitingSettings }) {
  const { t } = useTranslation('settings')
  const [isPending, startTransition] = useTransition()
  const {
    watch,
    setValue,
    handleSubmit,
    formState: { errors },
  } = useForm<RateLimitingForm>({
    resolver: zodResolver(rateLimitingSchema),
    defaultValues: initialData,
  })

  const values = watch()

  function onSubmit(data: RateLimitingForm) {
    startTransition(async () => {
      try {
        await updateRateLimitingSettings(data)
        toast.success(t('settings.email.rate_limiting.saved', 'Rate limiting desat correctament'))
      } catch (err) {
        toast.error(err instanceof Error ? err.message : 'Error desant la configuració')
      }
    })
  }

  return (
    <Card>
      <CardHeader className="border-b">
        <CardTitle>{t('settings.email.rate_limiting.title', 'Rate Limiting')}</CardTitle>
        <CardDescription>
          {t('settings.email.rate_limiting.description', "Controla el límit de velocitat d'enviament d'emails per tenant. S'aplica globalment.")}
        </CardDescription>
      </CardHeader>

      <form onSubmit={handleSubmit(onSubmit)}>
        <CardContent className="pt-4 space-y-1 divide-y divide-border">
          <SwitchRow
            label={t('settings.email.rate_limiting.enable_label', 'Habilitar Rate Limiting global')}
            description={t('settings.email.rate_limiting.enable_desc', 'Activa o desactiva el control de velocitat per a tots els tenants.')}
            checked={values.rate_limiting_enabled}
            onCheckedChange={(v) => setValue('rate_limiting_enabled', v)}
            disabled={isPending}
          />

          <div className="py-3">
            <FieldRow
              label={t('settings.email.rate_limiting.engine_label', "Motor d'execució")}
              description={t('settings.email.rate_limiting.engine_desc', 'Redis és més ràpid però requereix Upstash. Postgres és la fallada per defecte.')}
              error={errors.rate_limit_engine?.message}
            >
              <Select
                value={values.rate_limit_engine}
                onValueChange={(v) =>
                  setValue('rate_limit_engine', v as 'redis' | 'postgres')
                }
                disabled={isPending}
              >
                <SelectTrigger className="w-40">
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  <SelectItem value="redis">Redis (Upstash)</SelectItem>
                  <SelectItem value="postgres">Postgres</SelectItem>
                </SelectContent>
              </Select>
            </FieldRow>
          </div>

          <SwitchRow
            label={t('settings.email.rate_limiting.fallback_label', 'Fallback a Postgres si falla Redis')}
            description={t('settings.email.rate_limiting.fallback_desc', 'Si Redis no respon, utilitza Postgres com a motor alternatiu en lloc de bloquejar.')}
            checked={values.fallback_to_postgres}
            onCheckedChange={(v) => setValue('fallback_to_postgres', v)}
            disabled={isPending || values.rate_limit_engine === 'postgres'}
          />
        </CardContent>

        <CardFooter className="justify-end gap-2">
          <Button type="submit" disabled={isPending} size="sm">
            {isPending && <Loader2 className="size-3.5 animate-spin" />}
            Desar (els canvis poden trigar fins a 5 min a aplicar-se)
          </Button>
        </CardFooter>
      </form>
    </Card>
  )
}

// =============================================================================
// EmailModuleCard
// =============================================================================

function EmailModuleCard({ initialData }: { initialData: EmailModuleSettings }) {
  const { t } = useTranslation('settings')
  const [isPending, startTransition] = useTransition()
  const {
    register,
    handleSubmit,
    getValues,
    setValue,
    formState: { errors },
  } = useForm<EmailModuleForm>({
    resolver: zodResolver(emailModuleSchema),
    defaultValues: {
      platform_default_domain: initialData.platform_default_domain ?? '',
      platform_default_from_email: initialData.platform_default_from_email ?? '',
      platform_default_from_name: initialData.platform_default_from_name ?? '',
    },
  })

  /** Quan el domini perd el focus, auto-omple l'email si és buit o si el domini ha canviat */
  function handleDomainBlur(e: React.FocusEvent<HTMLInputElement>) {
    const domain = e.target.value.trim()
    if (!domain) return
    const currentEmail = (getValues('platform_default_from_email') ?? '').trim()
    const currentEmailDomain = currentEmail.split('@')[1]?.toLowerCase()
    if (!currentEmail || currentEmailDomain !== domain.toLowerCase()) {
      setValue('platform_default_from_email', `noreply@${domain}`, { shouldValidate: true })
    }
  }

  function onSubmit(data: EmailModuleForm) {
    startTransition(async () => {
      try {
        await updateEmailModuleSettings(data)
        toast.success(t('settings.email.module.saved', "Configuració d'email desada correctament"))
      } catch (err) {
        toast.error(err instanceof Error ? err.message : t('settings.email.module.error', 'Error desant la configuració'))
      }
    })
  }

  return (
    <Card>
      <CardHeader className="border-b">
        <CardTitle>{t('settings.email.module.title', "Marca Blanca / Fallback d'Email")}</CardTitle>
        <CardDescription>
          {t('settings.email.module.description', "Valors de fallback de la plataforma. S'usen quan el domini del remitent d'un correu no està verificat pel tenant.")}
        </CardDescription>
      </CardHeader>

      <form onSubmit={handleSubmit(onSubmit)}>
        <CardContent className="pt-4 space-y-4">
          <FieldRow
            label={t('settings.email.module.domain_label', 'Domini per defecte de la plataforma')}
            description={t('settings.email.module.domain_desc', 'Ex: example.com — Domini des del qual s\'enviaran els emails de fallback.')}
            error={errors.platform_default_domain?.message}
          >
            <Input
              {...register('platform_default_domain', { onBlur: handleDomainBlur })}
              placeholder="example.com"
              disabled={isPending}
              aria-invalid={!!errors.platform_default_domain}
            />
          </FieldRow>

          <FieldRow
            label={t('settings.email.module.from_email_label', "Email 'From' per defecte")}
            description={t('settings.email.module.from_email_desc', 'Ha de pertànyer al domini de la plataforma verificat a Resend (ex: noreply@example.com).')}
            error={errors.platform_default_from_email?.message}
          >
            <Input
              {...register('platform_default_from_email')}
              type="email"
              placeholder="noreply@example.com"
              disabled={isPending}
              aria-invalid={!!errors.platform_default_from_email}
            />
          </FieldRow>

          <FieldRow
            label={t('settings.email.module.from_name_label', 'Nom del remitent per defecte')}
            description={t('settings.email.module.from_name_desc', "Nom visible a la safata d'entrada del destinatari.")}
            error={errors.platform_default_from_name?.message}
          >
            <Input
              {...register('platform_default_from_name')}
              placeholder="La Meva Plataforma"
              disabled={isPending}
              aria-invalid={!!errors.platform_default_from_name}
            />
          </FieldRow>
        </CardContent>

        <CardFooter className="justify-end gap-2">
          <Button type="submit" disabled={isPending} size="sm">
            {isPending && <Loader2 className="size-3.5 animate-spin" />}
            Desar (els canvis poden trigar fins a 5 min a aplicar-se)
          </Button>
        </CardFooter>
      </form>
    </Card>
  )
}

// =============================================================================
// AdminEmailSettings — component principal exportat
// =============================================================================

export function AdminEmailSettings({
  initialRateLimiting,
  initialEmail,
}: AdminEmailSettingsProps) {
  return (
    <div className="space-y-6">
      <RateLimitingCard initialData={initialRateLimiting} />
      <Separator />
      <EmailModuleCard initialData={initialEmail} />
    </div>
  )
}
