import { useTranslation } from 'react-i18next'
import { Link } from 'react-router-dom'
import { commercialSigningCentreHref } from '../utils/commercialSigningHub'

export type CommercialDeliveryTraceRow = {
  id: string
  channel: string | null
  at: string
  recipient: string | null
  status: string | null
  error: string | null
}

function channelLabel(
  channel: string | null | undefined,
  t: (key: string, fallback: string) => string,
): string {
  switch (channel) {
    case 'email':
      return t('projects.commercial.share_channel_email', 'Correu')
    case 'whatsapp':
    case 'whatsapp_portal_nudge':
      return t('projects.commercial.share_channel_whatsapp', 'WhatsApp')
    case 'copy_link':
      return t('projects.commercial.share_channel_link', 'Enllaç')
    case 'portal':
      return t('projects.commercial.share_channel_portal', 'Portal')
    case 'presential':
      return t('projects.commercial.share_channel_presential', 'Presencial')
    default:
      return channel?.trim() || t('projects.commercial.share_channel_other', 'Canal')
  }
}

function formatAt(iso: string): string {
  try {
    return new Date(iso).toLocaleString('ca-ES', {
      day: 'numeric',
      month: 'short',
      hour: '2-digit',
      minute: '2-digit',
    })
  } catch {
    return iso
  }
}

type CommercialDeliveryTraceProps = {
  rows: CommercialDeliveryTraceRow[]
  /** pending signature / open decision */
  pending?: boolean
  /** When pending is about contract sign, not quote accept. */
  variant?: 'quote' | 'agreement'
  submissionId?: string | null
}

export function CommercialDeliveryTrace({
  rows,
  pending = false,
  variant = 'quote',
  submissionId = null,
}: CommercialDeliveryTraceProps) {
  const { t } = useTranslation('projects')
  const delivered = rows.length > 0

  return (
    <section className="space-y-2 rounded-xl border border-border px-3 py-3">
      <p className="text-sm font-semibold text-foreground">
        {delivered
          ? t('projects.orphan.delivered', 'Entregat')
          : t('projects.orphan.not_delivered', 'Encara no entregat')}
      </p>
      {delivered ? (
        <ul className="space-y-1.5 text-xs text-muted-foreground">
          {rows.map((row) => (
            <li key={row.id} className="flex flex-wrap gap-x-2 gap-y-0.5">
              <span className="font-medium text-foreground">
                {channelLabel(row.channel, t)}
              </span>
              <span>{formatAt(row.at)}</span>
              {row.recipient ? <span>· {row.recipient}</span> : null}
              {row.status ? <span>· {row.status}</span> : null}
              {row.error ? (
                <span className="text-destructive">· {row.error}</span>
              ) : null}
            </li>
          ))}
        </ul>
      ) : null}
      {pending ? (
        <p className="text-xs text-muted-foreground">
          {variant === 'agreement'
            ? t(
                'projects.agreements.reply_pending_signing',
                'Contracte enviat. La resposta del client es completa amb la firma.',
              )
            : t(
                'projects.orphan.reply_pending',
                'Resposta pendent: el client pot acceptar o refusar dins la firma.',
              )}
        </p>
      ) : null}
      {submissionId ? (
        <Link
          to={commercialSigningCentreHref(submissionId)}
          className="inline-flex text-xs font-medium text-primary underline-offset-2 hover:underline"
        >
          {t(
            'projects.commercial.view_signing_centre',
            'Veure al Centre de signatures',
          )}
        </Link>
      ) : null}
    </section>
  )
}
