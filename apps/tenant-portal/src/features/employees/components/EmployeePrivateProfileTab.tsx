import { useEffect, useRef, useState } from 'react'
import type { InputHTMLAttributes } from 'react'
import { useForm } from 'react-hook-form'
import { zodResolver } from '@hookform/resolvers/zod'
import { useTranslation } from 'react-i18next'
import { Eye, EyeOff, Loader2, Shield } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { useToast } from '@/hooks/use-toast'
import {
  useEmployeePrivateProfile,
  useRevealEmployeePrivateField,
  useUpsertEmployeePrivateProfile,
} from '../api/useEmployeePrivateProfile'
import type { RevealPrivateField } from '../api/employeePrivateProfileService'
import {
  employeePrivateProfileSchema,
  type EmployeePrivateProfileFormValues,
} from '../schemas/employeePrivateProfileSchema'

const REVEAL_TTL_MS = 60_000

export function EmployeePrivateProfileTab({
  employeeId,
  canView,
  canManageHr,
  canReveal,
  isOwnEmployee,
}: {
  employeeId: string
  canView: boolean
  canManageHr: boolean
  canReveal: boolean
  isOwnEmployee: boolean
}) {
  const { t } = useTranslation('employees')
  const { toast } = useToast()
  const enabled = canView || isOwnEmployee
  const { data, isLoading, error } = useEmployeePrivateProfile(employeeId, enabled)
  const upsert = useUpsertEmployeePrivateProfile(employeeId)
  const revealMut = useRevealEmployeePrivateField(employeeId)
  const canEdit = canManageHr || isOwnEmployee
  const hrFields = canManageHr

  const [revealed, setRevealed] = useState<Partial<Record<RevealPrivateField, string>>>({})
  const revealTimers = useRef<Partial<Record<RevealPrivateField, ReturnType<typeof setTimeout>>>>({})

  const {
    register,
    handleSubmit,
    reset,
    setValue,
    watch,
    formState: { isDirty, isSubmitting, errors },
  } = useForm<EmployeePrivateProfileFormValues>({
    resolver: zodResolver(employeePrivateProfileSchema),
    defaultValues: emptyValues(),
  })

  const clearIban = watch('clear_iban')
  const clearSsn = watch('clear_ssn')

  useEffect(() => {
    if (!data) return
    reset({
      ...emptyValues(),
      document_type: data.document_type ?? '',
      document_number: data.document_number ?? '',
      personal_email: data.personal_email ?? '',
      personal_phone: data.personal_phone ?? '',
      birth_date: data.birth_date ?? '',
      address: data.address ?? '',
      postal_code: data.postal_code ?? '',
      city: data.city ?? '',
      country_code: data.country_code ?? '',
      nationality_code: data.nationality_code ?? '',
      emergency_contact_name: data.emergency_contact_name ?? '',
      emergency_contact_phone: data.emergency_contact_phone ?? '',
      emergency_contact_relationship: data.emergency_contact_relationship ?? '',
      // write-only encrypted fields stay empty
      social_security_number: '',
      iban: '',
      clear_iban: false,
      clear_ssn: false,
    })
    setRevealed({})
  }, [data, reset])

  useEffect(() => {
    return () => {
      for (const t of Object.values(revealTimers.current)) {
        if (t) clearTimeout(t)
      }
    }
  }, [])

  useEffect(() => {
    setRevealed({})
    for (const timer of Object.values(revealTimers.current)) {
      if (timer) clearTimeout(timer)
    }
    revealTimers.current = {}
  }, [employeeId])

  async function handleReveal(field: RevealPrivateField) {
    try {
      const res = await revealMut.mutateAsync(field)
      setRevealed((prev) => ({ ...prev, [field]: res.value ?? '' }))
      if (revealTimers.current[field]) clearTimeout(revealTimers.current[field])
      revealTimers.current[field] = setTimeout(() => {
        setRevealed((prev) => {
          const next = { ...prev }
          delete next[field]
          return next
        })
      }, REVEAL_TTL_MS)
    } catch (e) {
      toast({
        variant: 'destructive',
        title: t('employees.private.reveal_failed', "No s'ha pogut revelar"),
        description: e instanceof Error ? e.message : undefined,
      })
    }
  }

  function hideReveal(field: RevealPrivateField) {
    if (revealTimers.current[field]) clearTimeout(revealTimers.current[field])
    setRevealed((prev) => {
      const next = { ...prev }
      delete next[field]
      return next
    })
  }

  if (!enabled) {
    return (
      <p className="text-sm text-muted-foreground">
        {t('employees.private.no_permission', 'No tens permís per veure la informació personal')}
      </p>
    )
  }

  if (isLoading) {
    return (
      <div className="flex justify-center py-10">
        <Loader2 className="h-6 w-6 animate-spin text-muted-foreground" />
      </div>
    )
  }

  if (error) {
    return (
      <p className="text-sm text-destructive">
        {t('employees.private.load_failed', "No s'ha pogut carregar el perfil privat")}
      </p>
    )
  }

  async function onSubmit(values: EmployeePrivateProfileFormValues) {
    try {
      const ibanTrim = values.iban?.trim() || ''
      const ssnTrim = values.social_security_number?.trim() || ''
      await upsert.mutateAsync({
        clearNulls: true,
        personal_email: values.personal_email || null,
        personal_phone: values.personal_phone || null,
        emergency_contact_name: values.emergency_contact_name || null,
        emergency_contact_phone: values.emergency_contact_phone || null,
        emergency_contact_relationship: values.emergency_contact_relationship || null,
        ...(hrFields
          ? {
              document_type: values.document_type || null,
              document_number: values.document_number || null,
              birth_date: values.birth_date || null,
              address: values.address || null,
              postal_code: values.postal_code || null,
              city: values.city || null,
              country_code: values.country_code || null,
              nationality_code: values.nationality_code || null,
              clearIban: !!values.clear_iban,
              ibanSet: !values.clear_iban && ibanTrim.length > 0,
              iban: !values.clear_iban && ibanTrim ? ibanTrim : null,
              clearSsn: !!values.clear_ssn,
              ssnSet: !values.clear_ssn && ssnTrim.length > 0,
              social_security_number: !values.clear_ssn && ssnTrim ? ssnTrim : null,
            }
          : {}),
      })
      toast({ title: t('employees.private.saved', 'Informació personal desada') })
    } catch (e) {
      toast({
        variant: 'destructive',
        title: t('employees.private.save_failed', "No s'ha pogut desar"),
        description: e instanceof Error ? e.message : undefined,
      })
    }
  }

  function onInvalid() {
    toast({
      variant: 'destructive',
      title: t('employees.private.validation_failed', 'Revisa els camps marcats'),
      description: errors.iban?.message,
    })
  }

  return (
    <form onSubmit={handleSubmit(onSubmit, onInvalid)} className="space-y-6 max-w-2xl">
      <div className="flex items-start gap-2 rounded-lg border border-amber-200 bg-amber-50 px-3 py-2 text-sm text-amber-900">
        <Shield className="h-4 w-4 mt-0.5 shrink-0" />
        <p>
          {t(
            'employees.private.sensitive_badge',
            'Dades sensibles: IBAN i NSS estan xifrats. La consulta en clar queda registrada a Activitat.',
          )}
        </p>
      </div>

      {hrFields ? (
        <section className="space-y-3">
          <h3 className="text-sm font-semibold">
            {t('employees.private.section_identity', 'Identitat')}
          </h3>
          <div className="grid gap-3 sm:grid-cols-2">
            <Field
              label={t('employees.private.document_type', 'Tipus document')}
              disabled={!canEdit}
              {...register('document_type')}
            />
            <Field
              label={t('employees.private.document_number', 'Número document')}
              disabled={!canEdit}
              placeholder="p.ex. 12345678A"
              {...register('document_number')}
            />
            <Field
              label={t('employees.private.birth_date', 'Data de naixement')}
              type="date"
              disabled={!canEdit}
              {...register('birth_date')}
            />
            <Field
              label={t('employees.private.nationality', 'Nacionalitat (codi)')}
              disabled={!canEdit}
              placeholder="ES"
              {...register('nationality_code')}
            />
          </div>

          <EncryptedField
            label={t('employees.private.ssn', 'Núm. Seguretat Social')}
            hasValue={!!data?.has_ssn}
            last4={data?.ssn_last4}
            revealed={revealed.social_security_number}
            canReveal={canReveal}
            canEdit={canEdit}
            clearChecked={!!clearSsn}
            onClearChange={(c) => setValue('clear_ssn', c, { shouldDirty: true })}
            onReveal={() => void handleReveal('social_security_number')}
            onHide={() => hideReveal('social_security_number')}
            revealing={revealMut.isPending}
            inputProps={register('social_security_number')}
            error={errors.social_security_number?.message}
            keepHint={t(
              'employees.private.write_only_hint',
              'Deixar buit per mantenir el valor actual',
            )}
            clearLabel={t('employees.private.clear_field', 'Esborrar valor')}
            revealLabel={t('employees.private.reveal', 'Revelar')}
            hideLabel={t('employees.private.hide', 'Amagar')}
          />
        </section>
      ) : null}

      {hrFields ? (
        <section className="space-y-3">
          <h3 className="text-sm font-semibold">
            {t('employees.private.section_bank', 'Dades bancàries')}
          </h3>
          <EncryptedField
            label={t('employees.private.iban', 'IBAN')}
            hasValue={!!data?.has_iban}
            last4={data?.iban_last4}
            revealed={revealed.iban}
            canReveal={canReveal}
            canEdit={canEdit}
            clearChecked={!!clearIban}
            onClearChange={(c) => setValue('clear_iban', c, { shouldDirty: true })}
            onReveal={() => void handleReveal('iban')}
            onHide={() => hideReveal('iban')}
            revealing={revealMut.isPending}
            inputProps={register('iban')}
            error={errors.iban?.message}
            keepHint={t(
              'employees.private.write_only_hint',
              'Deixar buit per mantenir el valor actual',
            )}
            clearLabel={t('employees.private.clear_field', 'Esborrar valor')}
            revealLabel={t('employees.private.reveal', 'Revelar')}
            hideLabel={t('employees.private.hide', 'Amagar')}
          />
        </section>
      ) : null}

      <section className="space-y-3">
        <h3 className="text-sm font-semibold">
          {t('employees.private.section_contact', 'Contacte privat')}
        </h3>
        <div className="grid gap-3 sm:grid-cols-2">
          <Field
            label={t('employees.private.personal_email', 'Email personal')}
            type="email"
            disabled={!canEdit}
            {...register('personal_email')}
          />
          <Field
            label={t('employees.private.personal_phone', 'Telèfon personal')}
            disabled={!canEdit}
            {...register('personal_phone')}
          />
        </div>
      </section>

      {hrFields ? (
        <section className="space-y-3">
          <h3 className="text-sm font-semibold">
            {t('employees.private.section_address', 'Adreça')}
          </h3>
          <Field
            label={t('employees.private.address', 'Adreça')}
            disabled={!canEdit}
            {...register('address')}
          />
          <div className="grid gap-3 sm:grid-cols-3">
            <Field
              label={t('employees.private.postal_code', 'Codi postal')}
              disabled={!canEdit}
              {...register('postal_code')}
            />
            <Field
              label={t('employees.private.city', 'Ciutat')}
              disabled={!canEdit}
              {...register('city')}
            />
            <Field
              label={t('employees.private.country', 'País (codi)')}
              disabled={!canEdit}
              placeholder="ES"
              {...register('country_code')}
            />
          </div>
        </section>
      ) : null}

      <section className="space-y-3">
        <h3 className="text-sm font-semibold">
          {t('employees.private.section_emergency', 'Emergència')}
        </h3>
        <div className="grid gap-3 sm:grid-cols-3">
          <Field
            label={t('employees.private.emergency_name', 'Nom')}
            disabled={!canEdit}
            {...register('emergency_contact_name')}
          />
          <Field
            label={t('employees.private.emergency_phone', 'Telèfon')}
            disabled={!canEdit}
            {...register('emergency_contact_phone')}
          />
          <Field
            label={t('employees.private.emergency_rel', 'Relació')}
            disabled={!canEdit}
            {...register('emergency_contact_relationship')}
          />
        </div>
      </section>

      {canEdit ? (
        <div className="flex justify-end">
          <Button type="submit" disabled={!isDirty || isSubmitting || upsert.isPending}>
            {(isSubmitting || upsert.isPending) && (
              <Loader2 className="h-4 w-4 mr-2 animate-spin" />
            )}
            {t('employees.private.save', 'Desar informació personal')}
          </Button>
        </div>
      ) : null}
    </form>
  )
}

function emptyValues(): EmployeePrivateProfileFormValues {
  return {
    document_type: '',
    document_number: '',
    personal_email: '',
    personal_phone: '',
    birth_date: '',
    address: '',
    postal_code: '',
    city: '',
    country_code: '',
    nationality_code: '',
    social_security_number: '',
    clear_ssn: false,
    iban: '',
    clear_iban: false,
    emergency_contact_name: '',
    emergency_contact_phone: '',
    emergency_contact_relationship: '',
  }
}

function Field({
  label,
  ...props
}: { label: string } & InputHTMLAttributes<HTMLInputElement>) {
  return (
    <label className="block space-y-1 text-sm">
      <span className="text-muted-foreground">{label}</span>
      <Input {...props} />
    </label>
  )
}

function EncryptedField({
  label,
  hasValue,
  last4,
  revealed,
  canReveal,
  canEdit,
  clearChecked,
  onClearChange,
  onReveal,
  onHide,
  revealing,
  inputProps,
  error,
  keepHint,
  clearLabel,
  revealLabel,
  hideLabel,
}: {
  label: string
  hasValue: boolean
  last4: string | null | undefined
  revealed: string | undefined
  canReveal: boolean
  canEdit: boolean
  clearChecked: boolean
  onClearChange: (v: boolean) => void
  onReveal: () => void
  onHide: () => void
  revealing: boolean
  inputProps: ReturnType<ReturnType<typeof useForm<EmployeePrivateProfileFormValues>>['register']>
  error?: string
  keepHint: string
  clearLabel: string
  revealLabel: string
  hideLabel: string
}) {
  const masked = hasValue ? `••••${last4 ?? '****'}` : '—'
  return (
    <div className="space-y-2 rounded-lg border p-3">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <span className="text-sm text-muted-foreground">{label}</span>
        <div className="flex items-center gap-2">
          <span className="font-mono text-sm">{revealed ?? masked}</span>
          {canReveal && hasValue ? (
            revealed ? (
              <Button type="button" size="sm" variant="ghost" onClick={onHide}>
                <EyeOff className="h-4 w-4 mr-1" />
                {hideLabel}
              </Button>
            ) : (
              <Button
                type="button"
                size="sm"
                variant="outline"
                disabled={revealing}
                onClick={onReveal}
              >
                {revealing ? (
                  <Loader2 className="h-4 w-4 mr-1 animate-spin" />
                ) : (
                  <Eye className="h-4 w-4 mr-1" />
                )}
                {revealLabel}
              </Button>
            )
          ) : null}
        </div>
      </div>
      {canEdit ? (
        <>
          <Input
            disabled={clearChecked}
            placeholder={keepHint}
            autoComplete="off"
            aria-invalid={!!error}
            {...inputProps}
          />
          {error ? <p className="text-xs text-destructive">{error}</p> : null}
          {hasValue ? (
            <label className="flex items-center gap-2 text-xs text-muted-foreground">
              <input
                type="checkbox"
                checked={clearChecked}
                onChange={(e) => onClearChange(e.target.checked)}
              />
              {clearLabel}
            </label>
          ) : null}
        </>
      ) : null}
    </div>
  )
}
