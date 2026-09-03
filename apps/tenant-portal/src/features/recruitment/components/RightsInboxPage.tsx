import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Eye } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Textarea } from '@/components/ui/textarea'
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from '@/components/ui/select'
import { useToast } from '@/hooks/use-toast'
import { usePermission } from '@/hooks/usePermission'
import { useTenantFeatures } from '@/features/entity-timeline/api/useTenantFeatures'
import {
  revealApplicantDataRequestEmail,
  type ApplicantDataRequestRow,
  type RightsRequestStatus,
} from '../api/recruitmentService'
import {
  useApplicantDataRequests,
  useResolveApplicantDataRequest,
} from '../api/useRecruitment'

const PUBLIC_PORTAL_BASE =
  (import.meta.env.VITE_PUBLIC_PORTAL_BASE_URL as string | undefined)?.replace(/\/$/, '') ||
  'http://localhost:3002'

function SlaBadge({ badge, t }: { badge: string; t: (k: string) => string }) {
  const label =
    badge === 'overdue'
      ? t('rights.sla_overdue')
      : badge === 'due_soon'
        ? t('rights.sla_due_soon')
        : t('rights.sla_ok')
  const cls =
    badge === 'overdue'
      ? 'bg-red-100 text-red-800'
      : badge === 'due_soon'
        ? 'bg-amber-100 text-amber-900'
        : 'bg-neutral-100 text-neutral-700'
  return (
    <span className={`inline-flex rounded px-2 py-0.5 text-xs font-medium ${cls}`}>{label}</span>
  )
}

export function RightsInboxPage() {
  const { t } = useTranslation('recruitment')
  const { toast } = useToast()
  const canRights = usePermission('recruitment.rights')
  const { data: features, isLoading: featuresLoading } = useTenantFeatures()
  const [statusFilter, setStatusFilter] = useState<RightsRequestStatus | 'all'>('pending_review')
  const { data: items = [], isLoading } = useApplicantDataRequests(
    statusFilter === 'all' ? null : statusFilter,
  )
  const resolveMutation = useResolveApplicantDataRequest()

  const [selected, setSelected] = useState<ApplicantDataRequestRow | null>(null)
  const [action, setAction] = useState<'approve' | 'reject' | null>(null)
  const [rejectionReason, setRejectionReason] = useState('')
  const [resolutionNotes, setResolutionNotes] = useState('')
  const [rectifyName, setRectifyName] = useState('')
  const [rectifyPhone, setRectifyPhone] = useState('')
  const [working, setWorking] = useState(false)
  const [revealedEmails, setRevealedEmails] = useState<Record<string, string>>({})
  const [revealingId, setRevealingId] = useState<string | null>(null)

  const needsResolutionNotes =
    action === 'approve' &&
    (selected?.request_type === 'rectification' || selected?.request_type === 'objection')

  const isRectificationApprove =
    action === 'approve' && selected?.request_type === 'rectification'

  function approveBodyKey(type: string | undefined): string {
    switch (type) {
      case 'erasure':
        return 'rights.approve_erasure_body'
      case 'rectification':
        return 'rights.approve_rectification_body'
      case 'restriction':
        return 'rights.approve_restriction_body'
      case 'portability':
        return 'rights.approve_portability_body'
      case 'objection':
        return 'rights.approve_objection_body'
      default:
        return 'rights.approve_access_body'
    }
  }

  if (featuresLoading) {
    return <div className="flex h-64 items-center justify-center text-muted-foreground">…</div>
  }

  if (!features?.recruitment_enabled) {
    return (
      <div className="p-6">
        <p className="text-muted-foreground">{t('postings.disabled')}</p>
      </div>
    )
  }

  if (!canRights) {
    return (
      <div className="p-6">
        <p className="text-muted-foreground">{t('rights.forbidden')}</p>
      </div>
    )
  }

  async function handleReveal(row: ApplicantDataRequestRow) {
    if (revealedEmails[row.id]) return
    setRevealingId(row.id)
    try {
      const res = await revealApplicantDataRequestEmail(row.id)
      setRevealedEmails((prev) => ({ ...prev, [row.id]: res.requester_email }))
    } catch (err) {
      toast({
        variant: 'destructive',
        description: err instanceof Error ? err.message : t('rights.reveal_error'),
      })
    } finally {
      setRevealingId(null)
    }
  }

  async function handleConfirm() {
    if (!selected || !action) return
    if (action === 'reject' && !rejectionReason.trim()) {
      toast({ variant: 'destructive', description: t('rights.reject_reason_required') })
      return
    }
    if (isRectificationApprove) {
      const nameChanged =
        rectifyName.trim() !== (selected.applicant_full_name ?? '').trim()
      const phoneChanged =
        rectifyPhone.trim() !== (selected.applicant_phone ?? '').trim()
      if (!resolutionNotes.trim() && !nameChanged && !phoneChanged) {
        toast({ variant: 'destructive', description: t('rights.notes_required') })
        return
      }
    } else if (needsResolutionNotes && !resolutionNotes.trim()) {
      toast({ variant: 'destructive', description: t('rights.notes_required') })
      return
    }
    setWorking(true)
    try {
      await resolveMutation.mutateAsync({
        id: selected.id,
        action,
        rejectionReason: action === 'reject' ? rejectionReason.trim() : null,
        exportBaseUrl: PUBLIC_PORTAL_BASE,
        resolutionNotes:
          action === 'approve' && resolutionNotes.trim()
            ? resolutionNotes.trim()
            : null,
        rectifyFullName:
          isRectificationApprove && rectifyName.trim() ? rectifyName.trim() : null,
        rectifyPhone: isRectificationApprove ? rectifyPhone : null,
      })
      toast({
        description:
          action === 'approve' ? t('rights.approve_success') : t('rights.reject_success'),
      })
      setSelected(null)
      setAction(null)
      setRejectionReason('')
      setResolutionNotes('')
      setRectifyName('')
      setRectifyPhone('')
    } catch (err) {
      toast({
        variant: 'destructive',
        description: err instanceof Error ? err.message : t('rights.resolve_error'),
      })
    } finally {
      setWorking(false)
    }
  }

  return (
    <div className="space-y-6">
      <p className="max-w-2xl text-sm text-muted-foreground">{t('rights.intro')}</p>

      <div className="flex items-center gap-3">
        <Label>{t('rights.filter_status')}</Label>
        <Select
          value={statusFilter}
          onValueChange={(v) => setStatusFilter(v as RightsRequestStatus | 'all')}
        >
          <SelectTrigger className="w-48">
            <SelectValue />
          </SelectTrigger>
          <SelectContent>
            <SelectItem value="pending_review">{t('rights.status.pending_review')}</SelectItem>
            <SelectItem value="fulfilled">{t('rights.status.fulfilled')}</SelectItem>
            <SelectItem value="rejected">{t('rights.status.rejected')}</SelectItem>
            <SelectItem value="all">{t('rights.status.all')}</SelectItem>
          </SelectContent>
        </Select>
      </div>

      {isLoading ? (
        <p className="text-muted-foreground">…</p>
      ) : items.length === 0 ? (
        <p className="text-muted-foreground">{t('rights.empty')}</p>
      ) : (
        <div className="overflow-x-auto rounded-lg border">
          <table className="w-full text-sm">
            <thead className="border-b bg-muted/40 text-left">
              <tr>
                <th className="px-3 py-2">{t('rights.col_type')}</th>
                <th className="px-3 py-2">{t('rights.col_email')}</th>
                <th className="px-3 py-2">{t('rights.col_status')}</th>
                <th className="px-3 py-2">{t('rights.col_due')}</th>
                <th className="px-3 py-2">{t('rights.col_sla')}</th>
                <th className="px-3 py-2">{t('rights.col_created')}</th>
                <th className="px-3 py-2" />
              </tr>
            </thead>
            <tbody>
              {items.map((row) => (
                <tr key={row.id} className="border-b last:border-0">
                  <td className="px-3 py-2">{t(`rights.type.${row.request_type}`)}</td>
                  <td className="px-3 py-2 font-mono text-xs">
                    <span className="inline-flex items-center gap-1">
                      {revealedEmails[row.id] ?? row.requester_email_masked}
                      {!revealedEmails[row.id] ? (
                        <Button
                          type="button"
                          size="sm"
                          variant="ghost"
                          className="h-6 px-1"
                          disabled={revealingId === row.id}
                          title={t('rights.reveal_email')}
                          onClick={() => void handleReveal(row)}
                        >
                          <Eye className="h-3.5 w-3.5" />
                        </Button>
                      ) : null}
                    </span>
                    {row.processing_restricted_at ? (
                      <span className="ml-1 text-[10px] text-amber-700">
                        [{t('rights.flag_restricted')}]
                      </span>
                    ) : null}
                    {row.objection_at ? (
                      <span className="ml-1 text-[10px] text-amber-700">
                        [{t('rights.flag_objection')}]
                      </span>
                    ) : null}
                  </td>
                  <td className="px-3 py-2">{t(`rights.status.${row.status}`)}</td>
                  <td className="px-3 py-2">{new Date(row.due_at).toLocaleDateString()}</td>
                  <td className="px-3 py-2">
                    {row.status === 'pending_review' ? (
                      <SlaBadge badge={row.sla_badge} t={t} />
                    ) : (
                      '—'
                    )}
                  </td>
                  <td className="px-3 py-2">{new Date(row.created_at).toLocaleDateString()}</td>
                  <td className="px-3 py-2 text-right">
                    {row.status === 'pending_review' && (
                      <div className="flex justify-end gap-2">
                        <Button
                          size="sm"
                          onClick={() => {
                            setSelected(row)
                            setAction('approve')
                            setResolutionNotes('')
                            setRectifyName(row.applicant_full_name ?? '')
                            setRectifyPhone(row.applicant_phone ?? '')
                          }}
                        >
                          {t('rights.approve')}
                        </Button>
                        <Button
                          size="sm"
                          variant="outline"
                          onClick={() => {
                            setSelected(row)
                            setAction('reject')
                            setRejectionReason('')
                            setResolutionNotes('')
                          }}
                        >
                          {t('rights.reject')}
                        </Button>
                      </div>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      <Dialog
        open={Boolean(selected && action)}
        onOpenChange={(open) => {
          if (!open) {
            setSelected(null)
            setAction(null)
          }
        }}
      >
        <DialogContent>
          <DialogHeader>
            <DialogTitle>
              {action === 'approve' ? t('rights.approve_title') : t('rights.reject_title')}
            </DialogTitle>
            <DialogDescription>
              {action === 'approve'
                ? t(approveBodyKey(selected?.request_type))
                : t('rights.reject_body')}
            </DialogDescription>
          </DialogHeader>
          {selected?.message && (
            <p className="rounded border bg-muted/30 p-2 text-sm text-muted-foreground">
              {selected.message}
            </p>
          )}
          {action === 'reject' && (
            <div className="space-y-2">
              <Label>{t('rights.reject_reason')}</Label>
              <Textarea
                value={rejectionReason}
                onChange={(e) => setRejectionReason(e.target.value)}
                rows={3}
              />
            </div>
          )}
          {isRectificationApprove && (
            <div className="grid gap-3 sm:grid-cols-2">
              <div className="space-y-2">
                <Label>{t('rights.rectify_full_name')}</Label>
                <Input value={rectifyName} onChange={(e) => setRectifyName(e.target.value)} />
              </div>
              <div className="space-y-2">
                <Label>{t('rights.rectify_phone')}</Label>
                <Input value={rectifyPhone} onChange={(e) => setRectifyPhone(e.target.value)} />
              </div>
            </div>
          )}
          {action === 'approve' && (
            <div className="space-y-2">
              <Label>
                {t('rights.resolution_notes')}
                {needsResolutionNotes && !isRectificationApprove ? ' *' : ''}
              </Label>
              <Textarea
                value={resolutionNotes}
                onChange={(e) => setResolutionNotes(e.target.value)}
                rows={3}
                placeholder={t('rights.resolution_notes_placeholder')}
              />
            </div>
          )}
          <DialogFooter className="gap-2">
            <Button
              type="button"
              variant="outline"
              disabled={working}
              onClick={() => {
                setSelected(null)
                setAction(null)
              }}
            >
              {t('rights.cancel')}
            </Button>
            <Button type="button" disabled={working} onClick={() => void handleConfirm()}>
              {working ? t('rights.working') : t('rights.confirm')}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  )
}
