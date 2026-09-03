import { useMemo, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Plus, Send, X, Users } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Badge } from '@/components/ui/badge'
import { useToast } from '@/hooks/use-toast'
import { useTenant } from '@/contexts/TenantContext'
import { useWorkRoles } from '../api/useWorkRoles'
import {
  useAcceptShiftOpeningClaim,
  useCancelShiftOpening,
  usePublishShiftOpening,
  useRejectShiftOpeningClaim,
  useShiftOpeningClaims,
  useShiftOpenings,
  useUpsertShiftOpening,
  type ShiftOpening,
} from '../api/useShiftOpenings'

function statusBadge(status: string, t: (k: string, d: string) => string) {
  switch (status) {
    case 'open':
      return <Badge className="bg-emerald-100 text-emerald-800 hover:bg-emerald-100">{t('openings.status_open', 'Oberta')}</Badge>
    case 'draft':
      return <Badge variant="secondary">{t('openings.status_draft', 'Esborrany')}</Badge>
    case 'cancelled':
      return <Badge variant="outline">{t('openings.status_cancelled', 'Cancel·lada')}</Badge>
    case 'filled':
      return <Badge>{t('openings.status_filled', 'Coberta')}</Badge>
    case 'expired':
      return <Badge variant="outline">{t('openings.status_expired', 'Expirada')}</Badge>
    default:
      return <Badge variant="outline">{status}</Badge>
  }
}

function OpeningClaims({ opening }: { opening: ShiftOpening }) {
  const { t } = useTranslation('attendance')
  const { toast } = useToast()
  const { data: claims = [] } = useShiftOpeningClaims(opening.id)
  const reject = useRejectShiftOpeningClaim()
  const accept = useAcceptShiftOpeningClaim()

  if (claims.length === 0) {
    return (
      <p className="mt-2 text-xs text-muted-foreground">
        {t('openings.claims_empty', 'Cap candidatura')}
      </p>
    )
  }

  return (
    <ul className="mt-2 space-y-1.5">
      {claims.map((c) => (
        <li key={c.id} className="flex flex-wrap items-center justify-between gap-2 rounded border px-2 py-1.5 text-sm">
          <span>
            {c.employee_name}
            <span className="ml-2 text-xs text-muted-foreground">{c.status}</span>
            {c.notes ? <span className="ml-2 text-xs text-muted-foreground">· {c.notes}</span> : null}
          </span>
          {c.status === 'pending' ? (
            <div className="flex gap-1.5">
              <Button
                type="button"
                size="sm"
                disabled={accept.isPending || reject.isPending}
                onClick={() => {
                  void accept.mutateAsync({ claim_id: c.id, opening_id: opening.id, accept_warnings: true })
                    .then((res) => toast({
                      title: t('openings.claim_accepted', 'Candidatura acceptada'),
                      description: res?.slot_id
                        ? t('openings.slot_created', 'Torn publicat creat')
                        : undefined,
                    }))
                    .catch((err) => toast({
                      variant: 'destructive',
                      title: t('openings.error', 'Error'),
                      description: err instanceof Error ? err.message : String(err),
                    }))
                }}
              >
                {t('openings.accept', 'Acceptar')}
              </Button>
              <Button
                type="button"
                size="sm"
                variant="outline"
                disabled={accept.isPending || reject.isPending}
                onClick={() => {
                  void reject.mutateAsync({ claim_id: c.id, opening_id: opening.id })
                    .then(() => toast({ title: t('openings.claim_rejected', 'Candidatura rebutjada') }))
                    .catch((err) => toast({
                      variant: 'destructive',
                      title: t('openings.error', 'Error'),
                      description: err instanceof Error ? err.message : String(err),
                    }))
                }}
              >
                {t('openings.reject', 'Rebutjar')}
              </Button>
            </div>
          ) : null}
        </li>
      ))}
    </ul>
  )
}

export function ShiftOpeningsPage() {
  const { t } = useTranslation('attendance')
  const { toast } = useToast()
  const { selectedSiteId, sites, setSelectedSiteId } = useTenant()
  const { data: roles = [] } = useWorkRoles()
  const { data: openings = [], isLoading, isError, error, refetch } = useShiftOpenings()
  const upsert = useUpsertShiftOpening()
  const publish = usePublishShiftOpening()
  const cancel = useCancelShiftOpening()

  const [date, setDate] = useState('')
  const [start, setStart] = useState('18:00')
  const [end, setEnd] = useState('22:00')
  const [places, setPlaces] = useState(1)
  const [title, setTitle] = useState('')
  const [roleId, setRoleId] = useState('')
  const [expandedId, setExpandedId] = useState<string | null>(null)

  const siteName = useMemo(
    () => sites.find((s) => s.id === selectedSiteId)?.name,
    [sites, selectedSiteId],
  )

  if (!selectedSiteId) {
    return (
      <div className="space-y-3">
        <h2 className="text-lg font-semibold">{t('openings.title', 'Vacants')}</h2>
        <p className="text-sm text-muted-foreground">
          {t('openings.pick_site', 'Selecciona un centre per gestionar vacants.')}
        </p>
        <div className="grid gap-2 sm:grid-cols-2 lg:grid-cols-3">
          {sites.map((s) => (
            <button
              key={s.id}
              type="button"
              className="rounded-lg border p-3 text-left hover:bg-muted/40"
              onClick={() => setSelectedSiteId(s.id)}
            >
              {s.name}
            </button>
          ))}
        </div>
      </div>
    )
  }

  async function createOpening() {
    if (!selectedSiteId || !date) return
    try {
      const row = await upsert.mutateAsync({
        site_id: selectedSiteId,
        opening_date: date,
        start_time: start,
        end_time: end,
        places_total: places,
        role_id: roleId || null,
        title: title || null,
      })
      setTitle('')
      toast({ title: t('openings.created', 'Vacant creada (esborrany)') })
      setExpandedId(row.id)
    } catch (err) {
      toast({
        variant: 'destructive',
        title: t('openings.error', 'Error'),
        description: err instanceof Error ? err.message : String(err),
      })
    }
  }

  return (
    <div className="space-y-4">
      <div>
        <h2 className="text-lg font-semibold">{t('openings.title', 'Vacants')}</h2>
        <p className="text-sm text-muted-foreground">
          {t(
            'openings.help',
            "Ofertes de torn sense empleat placeholder. Les candidatures es poden publicar i revisar; l'acceptació crearà el torn assignat. Les vacants urgents (p.ex. call-off) notifiquen els empleats amb push.",
          )}
          {siteName ? ` · ${siteName}` : ''}
        </p>
      </div>

      <div className="rounded-lg border p-3 space-y-2">
        <p className="text-xs font-semibold uppercase tracking-wide text-muted-foreground">
          {t('openings.new', 'Nova vacant')}
        </p>
        <div className="grid gap-2 sm:grid-cols-2 lg:grid-cols-6">
          <input
            type="date"
            value={date}
            onChange={(e) => setDate(e.target.value)}
            className="rounded-md border bg-background px-2 py-1.5 text-sm"
          />
          <input
            type="time"
            value={start}
            onChange={(e) => setStart(e.target.value)}
            className="rounded-md border bg-background px-2 py-1.5 text-sm"
          />
          <input
            type="time"
            value={end}
            onChange={(e) => setEnd(e.target.value)}
            className="rounded-md border bg-background px-2 py-1.5 text-sm"
          />
          <input
            type="number"
            min={1}
            value={places}
            onChange={(e) => setPlaces(Math.max(1, Number(e.target.value) || 1))}
            className="rounded-md border bg-background px-2 py-1.5 text-sm"
            title={t('openings.places', 'Places')}
          />
          <select
            value={roleId}
            onChange={(e) => setRoleId(e.target.value)}
            className="rounded-md border bg-background px-2 py-1.5 text-sm"
          >
            <option value="">{t('openings.role_any', 'Sense rol')}</option>
            {roles.map((r) => (
              <option key={r.id} value={r.id}>{r.name}</option>
            ))}
          </select>
          <Button type="button" size="sm" onClick={() => void createOpening()} disabled={!date}>
            <Plus className="mr-1 h-3.5 w-3.5" />
            {t('openings.create', 'Crear')}
          </Button>
        </div>
        <input
          value={title}
          onChange={(e) => setTitle(e.target.value)}
          placeholder={t('openings.title_placeholder', 'Títol opcional')}
          className="w-full rounded-md border bg-background px-2 py-1.5 text-sm"
        />
      </div>

      {isLoading ? (
        <p className="text-sm text-muted-foreground">{t('common.loading', 'Carregant…')}</p>
      ) : isError ? (
        <div className="text-sm text-destructive">
          <p>{t('openings.load_error', 'No s\'han pogut carregar les vacants')}</p>
          <p className="text-xs text-muted-foreground">{error instanceof Error ? error.message : String(error)}</p>
          <Button type="button" size="sm" variant="outline" className="mt-2" onClick={() => void refetch()}>
            {t('common.retry', 'Tornar a provar')}
          </Button>
        </div>
      ) : openings.length === 0 ? (
        <p className="text-sm text-muted-foreground">{t('openings.empty', 'Cap vacant')}</p>
      ) : (
        <ul className="space-y-2">
          {openings.map((o) => (
            <li key={o.id} className="rounded-lg border p-3">
              <div className="flex flex-wrap items-start justify-between gap-2">
                <div>
                  <div className="flex flex-wrap items-center gap-2">
                    <span className="font-medium">
                      {o.title || t('openings.untitled', 'Vacant')}
                    </span>
                    {statusBadge(o.status, t)}
                  </div>
                  <p className="mt-1 text-sm tabular-nums text-muted-foreground">
                    {o.opening_date} · {o.start_time}–{o.end_time}
                    {' · '}
                    {o.places_filled}/{o.places_total} {t('openings.places', 'places')}
                    {o.role_name_snapshot ? ` · ${o.role_name_snapshot}` : ''}
                  </p>
                </div>
                <div className="flex flex-wrap gap-1.5">
                  {o.status === 'draft' ? (
                    <Button
                      type="button"
                      size="sm"
                      onClick={() => {
                        void publish.mutateAsync(o.id)
                          .then(() => toast({ title: t('openings.published', 'Vacant publicada') }))
                          .catch((err) => toast({
                            variant: 'destructive',
                            title: t('openings.error', 'Error'),
                            description: err instanceof Error ? err.message : String(err),
                          }))
                      }}
                    >
                      <Send className="mr-1 h-3.5 w-3.5" />
                      {t('openings.publish', 'Publicar')}
                    </Button>
                  ) : null}
                  {o.status === 'draft' || o.status === 'open' ? (
                    <Button
                      type="button"
                      size="sm"
                      variant="outline"
                      onClick={() => {
                        void cancel.mutateAsync(o.id)
                          .then(() => toast({ title: t('openings.cancelled', 'Vacant cancel·lada') }))
                          .catch((err) => toast({
                            variant: 'destructive',
                            title: t('openings.error', 'Error'),
                            description: err instanceof Error ? err.message : String(err),
                          }))
                      }}
                    >
                      <X className="mr-1 h-3.5 w-3.5" />
                      {t('openings.cancel', 'Cancel·lar')}
                    </Button>
                  ) : null}
                  <Button
                    type="button"
                    size="sm"
                    variant="ghost"
                    onClick={() => setExpandedId(expandedId === o.id ? null : o.id)}
                  >
                    <Users className="mr-1 h-3.5 w-3.5" />
                    {t('openings.claims', 'Candidatures')}
                  </Button>
                </div>
              </div>
              {expandedId === o.id ? <OpeningClaims opening={o} /> : null}
            </li>
          ))}
        </ul>
      )}
    </div>
  )
}
