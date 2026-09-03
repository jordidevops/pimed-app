import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import { BadgeCheck, Mail, Phone, Ban } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { useToast } from '@/hooks/use-toast'
import { usePermission } from '@/hooks/usePermission'
import {
  createContactDeliveryChannel,
  disableContactDeliveryChannel,
  listContactDeliveryChannels,
  verifyContactDeliveryChannel,
} from '../api/contactsService'

interface Props {
  contactId: string
}

export function ContactDeliveryChannelsPanel({ contactId }: Props) {
  const { t } = useTranslation('contacts')
  const { toast } = useToast()
  const queryClient = useQueryClient()
  const canManagePortal = usePermission('contacts.portal.manage', null)
  const [channelType, setChannelType] = useState<'email' | 'phone'>('email')
  const [value, setValue] = useState('')
  const [markVerified, setMarkVerified] = useState(false)

  const queryKey = ['contact_delivery_channels', contactId]

  const { data: channels = [], isLoading } = useQuery({
    queryKey,
    queryFn: () => listContactDeliveryChannels(contactId),
  })

  const createMut = useMutation({
    mutationFn: () =>
      createContactDeliveryChannel({
        contactId,
        channelType,
        value: value.trim(),
        markVerified: canManagePortal && markVerified,
      }),
    onSuccess: () => {
      toast({
        title: t('contacts.channels_verified.created', 'Canal afegit'),
      })
      setValue('')
      queryClient.invalidateQueries({ queryKey })
    },
    onError: (err: Error) => {
      toast({
        variant: 'destructive',
        title: t('contacts.channels_verified.create_failed', 'No s\'ha pogut afegir el canal'),
        description: err.message,
      })
    },
  })

  const verifyMut = useMutation({
    mutationFn: (id: string) => verifyContactDeliveryChannel(id),
    onSuccess: () => {
      toast({
        title: t('contacts.channels_verified.verified', 'Canal verificat'),
      })
      queryClient.invalidateQueries({ queryKey })
    },
    onError: () => {
      toast({
        variant: 'destructive',
        title: t('contacts.channels_verified.verify_failed', 'No s\'ha pogut verificar'),
      })
    },
  })

  const disableMut = useMutation({
    mutationFn: (id: string) =>
      disableContactDeliveryChannel(
        id,
        t('contacts.channels_verified.disable_reason_default', 'Desactivat manualment'),
      ),
    onSuccess: () => {
      toast({
        title: t('contacts.channels_verified.disabled', 'Canal desactivat'),
      })
      queryClient.invalidateQueries({ queryKey })
    },
    onError: () => {
      toast({
        variant: 'destructive',
        title: t('contacts.channels_verified.disable_failed', 'No s\'ha pogut desactivar'),
      })
    },
  })

  return (
    <section className="rounded-2xl border border-border bg-card p-5 space-y-4">
      <div>
        <h2 className="text-sm font-semibold text-foreground">
          {t('contacts.channels_verified.title', 'Canals de lliurament')}
        </h2>
        <p className="text-xs text-muted-foreground mt-1">
          {t(
            'contacts.channels_verified.hint',
            'Email/telèfon CRM no compten com a verificats. Cal un canal verificat per invitacions persistents.',
          )}
        </p>
      </div>

      {isLoading ? (
        <p className="text-sm text-muted-foreground">
          {t('contacts.detail.projects_loading', 'Carregant…')}
        </p>
      ) : channels.length === 0 ? (
        <p className="text-sm text-muted-foreground">
          {t('contacts.channels_verified.empty', 'Cap canal actiu')}
        </p>
      ) : (
        <ul className="divide-y divide-border rounded-xl border border-border overflow-hidden">
          {channels.map((ch) => (
            <li
              key={ch.id}
              className="flex flex-wrap items-center justify-between gap-2 px-4 py-3"
            >
              <div className="min-w-0 flex items-start gap-2">
                {ch.channel_type === 'email' ? (
                  <Mail className="h-4 w-4 mt-0.5 text-muted-foreground shrink-0" />
                ) : (
                  <Phone className="h-4 w-4 mt-0.5 text-muted-foreground shrink-0" />
                )}
                <div>
                  <p className="text-sm font-medium break-all">{ch.value_raw}</p>
                  <p className="text-xs text-muted-foreground">
                    {ch.is_verified
                      ? t('contacts.channels_verified.status_verified', 'Verificat')
                      : t('contacts.channels_verified.status_unverified', 'Pendent de verificar')}
                    {ch.verification_method ? ` · ${ch.verification_method}` : ''}
                  </p>
                </div>
              </div>
              <div className="flex gap-2 shrink-0">
                {!ch.is_verified && canManagePortal && (
                  <Button
                    type="button"
                    variant="outline"
                    size="sm"
                    className="gap-1"
                    disabled={verifyMut.isPending}
                    onClick={() => verifyMut.mutate(ch.id)}
                  >
                    <BadgeCheck className="h-3.5 w-3.5" />
                    {t('contacts.channels_verified.verify', 'Verificar')}
                  </Button>
                )}
                <Button
                  type="button"
                  variant="outline"
                  size="sm"
                  className="gap-1"
                  disabled={disableMut.isPending}
                  onClick={() => disableMut.mutate(ch.id)}
                >
                  <Ban className="h-3.5 w-3.5" />
                  {t('contacts.channels_verified.disable', 'Desactivar')}
                </Button>
              </div>
            </li>
          ))}
        </ul>
      )}

      <div className="flex flex-col gap-2 sm:flex-row sm:items-end">
        <label className="sm:w-28 text-xs space-y-1">
          <span className="text-muted-foreground">
            {t('contacts.channels_verified.type', 'Tipus')}
          </span>
          <select
            className="w-full rounded-lg border border-border bg-background px-3 py-2 text-sm"
            value={channelType}
            onChange={(e) => setChannelType(e.target.value as 'email' | 'phone')}
          >
            <option value="email">email</option>
            <option value="phone">phone</option>
          </select>
        </label>
        <label className="flex-1 text-xs space-y-1">
          <span className="text-muted-foreground">
            {t('contacts.channels_verified.value', 'Valor')}
          </span>
          <input
            className="w-full rounded-lg border border-border bg-background px-3 py-2 text-sm"
            value={value}
            onChange={(e) => setValue(e.target.value)}
            placeholder={
              channelType === 'email' ? 'persona@exemple.cat' : '+34600000000'
            }
          />
        </label>
        {canManagePortal && (
          <label className="flex items-center gap-2 text-xs pb-2">
            <input
              type="checkbox"
              checked={markVerified}
              onChange={(e) => setMarkVerified(e.target.checked)}
            />
            {t('contacts.channels_verified.mark_verified', 'Marcar verificat')}
          </label>
        )}
        <Button
          type="button"
          size="sm"
          disabled={createMut.isPending || !value.trim()}
          onClick={() => createMut.mutate()}
        >
          {t('contacts.channels_verified.add', 'Afegir')}
        </Button>
      </div>
    </section>
  )
}
