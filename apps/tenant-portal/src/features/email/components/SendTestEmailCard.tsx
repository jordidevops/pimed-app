import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import { cn } from '@/lib/utils'
import { useSendTestEmail } from '../api/useSendTestEmail'
import { toast } from '@/hooks/use-toast'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import type { SenderProfile } from '../types'

const LOCALES = [
  { value: 'ca', label: 'CA' },
  { value: 'es', label: 'ES' },
  { value: 'en', label: 'EN' },
]

interface SendTestEmailCardProps {
  tenantId: string
  site_id: string | null
  senderProfiles: SenderProfile[]
}

export function SendTestEmailCard({ tenantId, site_id, senderProfiles }: SendTestEmailCardProps) {
  const { t } = useTranslation('email')
  const [to, setTo] = useState('')
  const [toError, setToError] = useState('')
  const [selectedProfileId, setSelectedProfileId] = useState<string>('')
  const [selectedLocale, setSelectedLocale] = useState('ca')

  const sendTest = useSendTestEmail()

  const validate = (email: string) => {
    if (!email) return t('email.test_email.error_required', "L'adreça de destinació és obligatòria.")
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email))
      return t('email.test_email.error_invalid', "Format d'email no vàlid.")
    return ''
  }

  const handleSend = async () => {
    const error = validate(to)
    if (error) {
      setToError(error)
      return
    }
    setToError('')

    try {
      await sendTest.mutateAsync({
        tenantId,
        site_id,
        to,
        senderProfileId: selectedProfileId || undefined,
        locale: selectedLocale,
      })
      toast({
        title: t('email.test_email.success_title', 'Correu de prova enviat'),
        description: t(
          'email.test_email.success_desc',
          "El correu s'ha posat en cua correctament. Comprova la safata d'entrada de {{to}}.",
          { to },
        ),
      })
    } catch (err) {
      toast({
        title: t('email.test_email.error_title', "Error en enviar el correu de prova"),
        description: err instanceof Error ? err.message : String(err),
        variant: 'destructive',
      })
    }
  }

  return (
    <div className="rounded-lg border bg-card p-6 space-y-4">
      <div>
        <h2 className="text-base font-semibold">
          {t('email.test_email.section_title', 'Enviar correu de prova')}
        </h2>
        <p className="mt-1 text-sm text-muted-foreground">
          {t(
            'email.test_email.section_desc',
            "Verifica que la configuració de correu funciona correctament enviant un missatge de prova.",
          )}
        </p>
      </div>

      <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
        {/* Destinatari */}
        <div>
          <label className="block text-sm font-medium mb-1.5">
            {t('email.test_email.to_label', 'Adreça de destinació')}
          </label>
          <Input
            type="email"
            placeholder="test@exemple.cat"
            value={to}
            onChange={(e) => {
              setTo(e.target.value)
              if (toError) setToError(validate(e.target.value))
            }}
          />
          {toError && <p className="mt-1 text-sm text-destructive">{toError}</p>}
        </div>

        {/* Selector de perfil de remitent */}
        <div>
          <label className="block text-sm font-medium mb-1.5">
            {t('email.test_email.sender_label', 'Domini del remitent')}
          </label>
          <select
            value={selectedProfileId}
            onChange={(e) => setSelectedProfileId(e.target.value)}
            className="flex h-9 w-full rounded-md border border-input bg-transparent px-3 py-1 text-sm shadow-sm transition-colors focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring disabled:cursor-not-allowed disabled:opacity-50"
          >
            <option value="">
              {t('email.test_email.sender_default', 'Per defecte (domini de la plataforma)')}
            </option>
            {senderProfiles.map((profile) => (
              <option key={profile.id} value={profile.id}>
                {profile.label} — {profile.from_name}
              </option>
            ))}
          </select>
        </div>
      </div>

      {/* Selector d'idioma */}
      <div>
        <label className="block text-sm font-medium mb-1.5">
          {t('email.test_email.locale_label', "Idioma del correu de prova")}
        </label>
        <div className="flex items-center gap-0.5 rounded-lg border border-input bg-muted/40 p-0.5 w-fit">
          {LOCALES.map(({ value, label }) => (
            <button
              key={value}
              type="button"
              onClick={() => setSelectedLocale(value)}
              className={cn(
                'px-3 py-1.5 text-xs font-medium rounded-md transition-colors',
                selectedLocale === value
                  ? 'bg-background shadow-sm text-foreground'
                  : 'text-muted-foreground hover:text-foreground',
              )}
            >
              {t(`email.templates.locale_${value}`, label)}
            </button>
          ))}
        </div>
      </div>

      <div className="flex justify-end">
        <Button
          type="button"
          variant="outline"
          disabled={sendTest.isPending}
          onClick={handleSend}
        >
          {sendTest.isPending
            ? t('email.test_email.sending', 'Enviant...')
            : t('email.test_email.send_btn', 'Enviar prova')}
        </Button>
      </div>
    </div>
  )
}
