import { useMemo, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { Loader2, Link2, Unlink } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { useToast } from '@/hooks/use-toast'
import { useTenant } from '@/contexts/TenantContext'
import { useAuth } from '@/contexts/AuthContext'
import { useMembers } from '@/hooks/useMembers'
import { getEmployees, updateEmployee, normalizeEmployeeError } from '../api/employeesService'

export function EmployeeUserLinkField({
  employeeId,
  linkedUserId,
  canWrite,
}: {
  employeeId: string
  linkedUserId: string | null | undefined
  canWrite: boolean
}) {
  const { t } = useTranslation('employees')
  const { toast } = useToast()
  const { activeTenant } = useTenant()
  const { user } = useAuth()
  const queryClient = useQueryClient()
  const [selectedUserId, setSelectedUserId] = useState('')
  const [busy, setBusy] = useState(false)

  const { data: members = [], isLoading: membersLoading } = useMembers(
    activeTenant?.id ?? null,
    user?.id,
    'active',
  )

  const { data: linkedEmployeeIds = [] } = useQuery({
    queryKey: ['employees', activeTenant?.id ?? '', 'user-links'],
    enabled: !!activeTenant?.id,
    queryFn: async () => {
      const all = await getEmployees()
      return all
        .filter((e) => e.user_id && e.id !== employeeId)
        .map((e) => e.user_id as string)
    },
  })

  const takenUserIds = useMemo(() => new Set(linkedEmployeeIds), [linkedEmployeeIds])

  const linkedMember = useMemo(
    () => members.find((m) => m.user_id === linkedUserId) ?? null,
    [members, linkedUserId],
  )

  const availableMembers = useMemo(
    () => members.filter((m) => !takenUserIds.has(m.user_id) || m.user_id === linkedUserId),
    [members, takenUserIds, linkedUserId],
  )

  async function invalidate() {
    await queryClient.invalidateQueries({ queryKey: ['employees'] })
  }

  async function linkUser(userId: string) {
    setBusy(true)
    try {
      await updateEmployee(employeeId, { user_id: userId })
      await invalidate()
      setSelectedUserId('')
      toast({ title: t('employees.user_link.linked', 'Usuari vinculat') })
    } catch (err) {
      const kind = normalizeEmployeeError(err)
      const raw = err instanceof Error ? err.message : ''
      toast({
        variant: 'destructive',
        title: t('employees.user_link.link_failed', "No s'ha pogut vincular l'usuari"),
        description:
          kind === 'unauthorized'
            ? t('employees.errors.unauthorized', 'No tens permís per fer aquesta acció')
            : raw || undefined,
      })
    } finally {
      setBusy(false)
    }
  }

  async function unlinkUser() {
    setBusy(true)
    try {
      await updateEmployee(employeeId, { user_id: null })
      await invalidate()
      toast({ title: t('employees.user_link.unlinked', 'Usuari desvinculat') })
    } catch (err) {
      const kind = normalizeEmployeeError(err)
      const raw = err instanceof Error ? err.message : ''
      toast({
        variant: 'destructive',
        title: t('employees.user_link.unlink_failed', "No s'ha pogut desvincular l'usuari"),
        description:
          kind === 'unauthorized'
            ? t('employees.errors.unauthorized', 'No tens permís per fer aquesta acció')
            : raw || undefined,
      })
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className="space-y-2 rounded-lg border border-border p-3">
      <div className="flex items-center gap-2">
        <Link2 className="h-4 w-4 text-muted-foreground" />
        <label className="text-sm font-medium">
          {t('employees.user_link.label', 'Compte d’usuari')}
        </label>
      </div>
      <p className="text-xs text-muted-foreground">
        {t(
          'employees.user_link.hint',
          'Vincula un membre del tenant. Un usuari només pot estar vinculat a un empleat.',
        )}
      </p>

      {linkedUserId ? (
        <div className="flex flex-wrap items-center gap-2">
          <span className="text-sm">
            {linkedMember?.full_name || linkedMember?.email || linkedUserId}
            {linkedMember?.email && linkedMember.full_name ? (
              <span className="text-muted-foreground"> · {linkedMember.email}</span>
            ) : null}
          </span>
          {canWrite ? (
            <Button
              type="button"
              variant="outline"
              size="sm"
              disabled={busy}
              onClick={() => void unlinkUser()}
            >
              {busy ? <Loader2 className="h-4 w-4 animate-spin" /> : <Unlink className="h-4 w-4" />}
              <span className="ml-1.5">
                {t('employees.user_link.unlink', 'Desvincular')}
              </span>
            </Button>
          ) : null}
        </div>
      ) : canWrite ? (
        <div className="flex flex-wrap items-center gap-2">
          <select
            className="flex-1 min-w-[12rem] rounded-md border border-input bg-background px-3 py-2 text-sm shadow-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
            value={selectedUserId}
            disabled={busy || membersLoading}
            onChange={(e) => setSelectedUserId(e.target.value)}
          >
            <option value="">
              {membersLoading
                ? t('employees.user_link.loading', 'Carregant membres…')
                : t('employees.user_link.select', 'Selecciona un membre')}
            </option>
            {availableMembers.map((m) => (
              <option key={m.user_id} value={m.user_id} disabled={takenUserIds.has(m.user_id)}>
                {(m.full_name || m.email) + (m.email && m.full_name ? ` (${m.email})` : '')}
              </option>
            ))}
          </select>
          <Button
            type="button"
            size="sm"
            disabled={busy || !selectedUserId}
            onClick={() => void linkUser(selectedUserId)}
          >
            {busy ? <Loader2 className="h-4 w-4 animate-spin" /> : <Link2 className="h-4 w-4" />}
            <span className="ml-1.5">{t('employees.user_link.link', 'Vincular')}</span>
          </Button>
        </div>
      ) : (
        <p className="text-sm text-muted-foreground">
          {t('employees.user_link.none', 'Sense compte vinculat')}
        </p>
      )}
    </div>
  )
}
