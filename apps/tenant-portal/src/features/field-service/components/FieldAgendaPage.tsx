import { Link } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { CalendarDays, ChevronRight } from 'lucide-react'
import { Badge } from '@/components/ui/badge'
import { useAgendaOrders } from '../api/useTodayOrders'
import { getProjectStatusLabel, getProjectStatusVariant } from '@/features/projects/projectStatus'
import { localDateString } from '@/lib/dateLocal'

function dayKey(iso: string | null | undefined): string {
  if (!iso) return '—'
  return localDateString(new Date(iso))
}

function formatDayLabel(key: string): string {
  if (key === '—') return key
  const [y, m, d] = key.split('-').map(Number)
  return new Date(y, m - 1, d).toLocaleDateString(undefined, {
    weekday: 'short',
    day: 'numeric',
    month: 'short',
  })
}

function formatTime(iso: string | null | undefined): string {
  if (!iso) return ''
  return new Date(iso).toLocaleTimeString(undefined, { hour: '2-digit', minute: '2-digit' })
}

export function FieldAgendaPage() {
  const { t } = useTranslation(['field-service', 'projects'])
  const { data, isLoading } = useAgendaOrders()
  const orders = data?.items ?? []

  const grouped = orders.reduce<Record<string, typeof orders>>((acc, order) => {
    const key = dayKey(order.planned_start)
    if (!acc[key]) acc[key] = []
    acc[key].push(order)
    return acc
  }, {})

  const days = Object.keys(grouped).sort()

  if (isLoading) {
    return (
      <div className="flex h-64 items-center justify-center">
        <div className="h-6 w-6 animate-spin rounded-full border-2 border-primary border-t-transparent" />
      </div>
    )
  }

  return (
    <div className="mx-auto max-w-lg space-y-4 px-4 py-6 pb-24">
      <div>
        <h1 className="text-2xl font-bold">{t('field-service:agenda.title', 'Agenda')}</h1>
        <p className="text-sm text-muted-foreground">
          {t('field-service:agenda.subtitle', 'Visites planificades (14 dies)')}
        </p>
      </div>

      {days.length === 0 ? (
        <div className="rounded-2xl border border-dashed border-border py-12 text-center">
          <CalendarDays className="mx-auto mb-2 h-8 w-8 text-muted-foreground/50" />
          <p className="text-sm text-muted-foreground">
            {t('field-service:today.empty', 'No tens visites planificades per avui')}
          </p>
          <Link to="/attendance/calendar" className="text-sm text-primary mt-3 inline-block">
            {t('field-service:agenda.open_calendar', 'Obrir calendari')}
          </Link>
        </div>
      ) : (
        <div className="space-y-5">
          {days.map((day) => (
            <section key={day} className="space-y-2">
              <h2 className="text-xs font-semibold uppercase tracking-wide text-muted-foreground">
                {formatDayLabel(day)}
              </h2>
              <ul className="space-y-2">
                {grouped[day].map((order) => (
                  <li key={order.id}>
                    <Link
                      to={`/field/orders/${order.id}`}
                      className="flex items-center justify-between rounded-xl border border-border bg-card px-4 py-3 min-h-12 hover:bg-accent/30"
                    >
                      <div className="min-w-0 space-y-0.5">
                        <p className="font-medium truncate">{order.name}</p>
                        <p className="text-xs text-muted-foreground">
                          {formatTime(order.planned_start)}
                          {order.client_display_name ? ` · ${order.client_display_name}` : ''}
                        </p>
                      </div>
                      <div className="flex items-center gap-2 shrink-0">
                        <Badge variant={getProjectStatusVariant(order.status)}>
                          {getProjectStatusLabel(t, order.status, { fieldService: true })}
                        </Badge>
                        <ChevronRight className="h-4 w-4 text-muted-foreground" />
                      </div>
                    </Link>
                  </li>
                ))}
              </ul>
            </section>
          ))}
        </div>
      )}
    </div>
  )
}
