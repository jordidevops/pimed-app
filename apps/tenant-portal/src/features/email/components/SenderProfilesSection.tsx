import { useState } from 'react'
import { useForm } from 'react-hook-form'
import { zodResolver } from '@hookform/resolvers/zod'
import { useTranslation } from 'react-i18next'
import { senderProfileSchema, type SenderProfileFormValues } from '../schemas/email.schema'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import type { SenderProfile } from '../types'

interface SenderProfilesSectionProps {
  profiles: SenderProfile[]
  onChange: (profiles: SenderProfile[]) => void
  disabled?: boolean
}

export function SenderProfilesSection({
  profiles,
  onChange,
  disabled,
}: SenderProfilesSectionProps) {
  const { t } = useTranslation('email')
  const [showForm, setShowForm] = useState(false)

  const {
    register,
    handleSubmit,
    reset,
    formState: { errors },
  } = useForm<SenderProfileFormValues>({
    resolver: zodResolver(senderProfileSchema),
  })

  const handleAdd = (values: SenderProfileFormValues) => {
    const newProfile: SenderProfile = {
      id: crypto.randomUUID(),
      ...values,
    }
    onChange([...profiles, newProfile])
    reset()
    setShowForm(false)
  }

  const handleRemove = (id: string) => {
    onChange(profiles.filter((p) => p.id !== id))
  }

  return (
    <div className="space-y-3">
      <div className="flex items-center justify-between">
        <h3 className="text-sm font-semibold">
          {t('email.config.sender_profiles_title', 'Perfils de remitent per departament')}
        </h3>
        {!showForm && (
          <Button
            type="button"
            variant="ghost"
            size="sm"
            disabled={disabled}
            onClick={() => setShowForm(true)}
          >
            + {t('email.config.add_sender_profile', 'Afegir perfil')}
          </Button>
        )}
      </div>

      {/* Llista de perfils existents */}
      {profiles.length > 0 && (
        <ul className="divide-y rounded-lg border overflow-hidden">
          {profiles.map((p) => (
            <li
              key={p.id}
              className="flex items-center justify-between px-4 py-3 bg-card"
            >
              <div>
                <span className="text-sm font-medium">{p.label}</span>
                <span className="ml-3 text-xs text-muted-foreground">
                  {p.from_name} · {p.reply_to}
                </span>
              </div>
              <Button
                type="button"
                variant="ghost"
                size="sm"
                disabled={disabled}
                onClick={() => handleRemove(p.id)}
                className="text-destructive hover:text-destructive"
                aria-label={t('email.config.remove_profile', 'Eliminar perfil')}
              >
                {t('email.config.remove', 'Eliminar')}
              </Button>
            </li>
          ))}
        </ul>
      )}

      {profiles.length === 0 && !showForm && (
        <p className="text-sm text-muted-foreground italic">
          {t('email.config.no_sender_profiles', 'Encara no hi ha perfils addicionals.')}
        </p>
      )}

      {/* Formulari d'addició — usem div per evitar <form> niuat dins EmailGeneralTab */}
      {showForm && (
        <div className="rounded-lg border bg-muted/30 p-4 space-y-3">
          <div className="grid grid-cols-1 gap-3 sm:grid-cols-3">
            <div>
              <label className="block text-xs font-medium mb-1">
                {t('email.config.profile_label', 'Etiqueta (ex: Facturació)')}
              </label>
              <Input
                {...register('label')}
                type="text"
                placeholder="Facturació"
              />
              {errors.label && (
                <p className="mt-1 text-sm text-destructive">{errors.label.message}</p>
              )}
            </div>
            <div>
              <label className="block text-xs font-medium mb-1">
                {t('email.config.profile_from_name', 'Nom del remitent')}
              </label>
              <Input
                {...register('from_name')}
                type="text"
                placeholder="Empresa SA - Facturació"
              />
              {errors.from_name && (
                <p className="mt-1 text-sm text-destructive">{errors.from_name.message}</p>
              )}
            </div>
            <div>
              <label className="block text-xs font-medium mb-1">
                {t('email.config.profile_reply_to', 'Reply-To')}
              </label>
              <Input
                {...register('reply_to')}
                type="email"
                placeholder="facturacio@empresa.cat"
              />
              {errors.reply_to && (
                <p className="mt-1 text-sm text-destructive">{errors.reply_to.message}</p>
              )}
            </div>
          </div>
          <div className="flex gap-2 justify-end">
            <Button
              type="button"
              variant="outline"
              size="sm"
              onClick={() => {
                reset()
                setShowForm(false)
              }}
            >
              {t('email.config.cancel', 'Cancel·lar')}
            </Button>
            <Button
              type="button"
              size="sm"
              onClick={() => handleSubmit(handleAdd)()}
            >
              {t('email.config.confirm_add_profile', 'Afegir')}
            </Button>
          </div>
        </div>
      )}
    </div>
  )
}
