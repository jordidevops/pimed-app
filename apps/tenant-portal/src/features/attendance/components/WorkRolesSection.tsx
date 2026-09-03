import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Info, Plus, Pencil, Check, X, Trash2 } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { useToast } from '@/hooks/use-toast'
import {
  useDeactivateRoleQualRequirement,
  useDeactivateWorkRole,
  useRoleQualRequirements,
  useUpsertRoleQualRequirement,
  useUpsertWorkRole,
  useWorkRoles,
  type WorkRole,
} from '../api/useWorkRoles'

export function WorkRolesSection() {
  const { t } = useTranslation('attendance')
  const { toast } = useToast()
  const { data: roles = [], isLoading, isError, error, refetch } = useWorkRoles()
  const upsert = useUpsertWorkRole()
  const deactivate = useDeactivateWorkRole()

  const [editing, setEditing] = useState<WorkRole | null>(null)
  const [creating, setCreating] = useState(false)
  const [name, setName] = useState('')
  const [key, setKey] = useState('')
  const [selectedRoleId, setSelectedRoleId] = useState<string | null>(null)

  function startCreate() {
    setCreating(true)
    setEditing(null)
    setName('')
    setKey('')
  }

  function startEdit(role: WorkRole) {
    setEditing(role)
    setCreating(false)
    setName(role.name)
    setKey(role.key)
  }

  function cancelForm() {
    setCreating(false)
    setEditing(null)
    setName('')
    setKey('')
  }

  async function save() {
    try {
      await upsert.mutateAsync({
        id: editing?.id,
        name,
        key: key || undefined,
      })
      toast({ title: t('planificacio.roles_saved', 'Rol desat') })
      cancelForm()
    } catch (err) {
      toast({
        variant: 'destructive',
        title: t('planificacio.roles_save_error', 'No s\'ha pogut desar el rol'),
        description: err instanceof Error ? err.message : String(err),
      })
    }
  }

  async function remove(role: WorkRole) {
    try {
      await deactivate.mutateAsync(role.id)
      if (selectedRoleId === role.id) setSelectedRoleId(null)
      toast({ title: t('planificacio.roles_deactivated', 'Rol desactivat') })
    } catch (err) {
      toast({
        variant: 'destructive',
        title: t('planificacio.roles_deactivate_error', 'No s\'ha pogut desactivar'),
        description: err instanceof Error ? err.message : String(err),
      })
    }
  }

  return (
    <div className="space-y-4">
      <div className="flex items-start gap-2 rounded-lg border border-sky-200 bg-sky-50 px-4 py-3 text-sm text-sky-950 dark:border-sky-800 dark:bg-sky-950/30 dark:text-sky-100">
        <Info className="mt-0.5 h-4 w-4 shrink-0" />
        <p>
          {t(
            'planificacio.roles_help',
            'Rols operatius per cobertura i planificació. El «càrrec» de l\'empleat és només descriptiu; aquí es defineix què pot cobrir.',
          )}
        </p>
      </div>

      <div className="flex items-center justify-between">
        <h3 className="text-sm font-semibold">
          {t('planificacio.roles_title', 'Rols operatius')}
        </h3>
        {!creating && !editing ? (
          <Button type="button" size="sm" variant="outline" onClick={startCreate}>
            <Plus className="mr-1 h-3.5 w-3.5" />
            {t('planificacio.roles_add', 'Afegir rol')}
          </Button>
        ) : null}
      </div>

      {(creating || editing) && (
        <div className="rounded-lg border p-3 space-y-2">
          <div className="grid grid-cols-2 gap-2">
            <div>
              <label className="text-xs font-medium mb-0.5 block">
                {t('planificacio.roles_name', 'Nom')}
              </label>
              <input
                value={name}
                onChange={(e) => {
                  setName(e.target.value)
                  if (!editing) {
                    setKey(e.target.value.toLowerCase().replace(/[^a-z0-9]+/g, '_').replace(/^_|_$/g, ''))
                  }
                }}
                className="w-full border rounded px-2 py-1 text-xs bg-background"
              />
            </div>
            <div>
              <label className="text-xs font-medium mb-0.5 block">
                {t('planificacio.roles_key', 'Clau')}
              </label>
              <input
                value={key}
                onChange={(e) => setKey(e.target.value.toLowerCase().replace(/[^a-z0-9_]/g, ''))}
                disabled={!!editing}
                className="w-full border rounded px-2 py-1 text-xs bg-background disabled:opacity-60"
              />
            </div>
          </div>
          <div className="flex gap-2">
            <Button type="button" size="sm" onClick={() => void save()} disabled={!name.trim() || upsert.isPending}>
              <Check className="mr-1 h-3.5 w-3.5" />
              {t('common.save', 'Desar')}
            </Button>
            <Button type="button" size="sm" variant="ghost" onClick={cancelForm}>
              <X className="mr-1 h-3.5 w-3.5" />
              {t('common.cancel', 'Cancel·lar')}
            </Button>
          </div>
        </div>
      )}

      {isLoading ? (
        <p className="text-sm text-muted-foreground">{t('common.loading', 'Carregant…')}</p>
      ) : isError ? (
        <div className="rounded-lg border border-destructive/40 bg-destructive/5 px-3 py-2 text-sm">
          <p className="text-destructive">
            {t('planificacio.roles_load_error', 'No s\'han pogut carregar els rols')}
          </p>
          <p className="mt-1 text-xs text-muted-foreground">
            {error instanceof Error ? error.message : String(error)}
          </p>
          <Button type="button" size="sm" variant="outline" className="mt-2" onClick={() => void refetch()}>
            {t('common.retry', 'Tornar a provar')}
          </Button>
        </div>
      ) : roles.length === 0 ? (
        <p className="text-sm text-muted-foreground">
          {t('planificacio.roles_empty', 'Encara no hi ha rols. Crea\'n un per començar.')}
        </p>
      ) : (
        <ul className="divide-y rounded-lg border">
          {roles.map((role) => (
            <li key={role.id} className="flex items-center justify-between gap-2 px-3 py-2 text-sm">
              <button
                type="button"
                className={`text-left flex-1 ${selectedRoleId === role.id ? 'font-semibold text-primary' : ''}`}
                onClick={() => setSelectedRoleId(role.id === selectedRoleId ? null : role.id)}
              >
                {role.name}
                <span className="ml-2 text-xs text-muted-foreground">{role.key}</span>
              </button>
              <div className="flex gap-1">
                <Button type="button" size="icon" variant="ghost" className="h-7 w-7" onClick={() => startEdit(role)}>
                  <Pencil className="h-3.5 w-3.5" />
                </Button>
                <Button type="button" size="icon" variant="ghost" className="h-7 w-7" onClick={() => void remove(role)}>
                  <Trash2 className="h-3.5 w-3.5 text-destructive" />
                </Button>
              </div>
            </li>
          ))}
        </ul>
      )}

      {selectedRoleId ? <RoleRequirementsPanel roleId={selectedRoleId} /> : null}
    </div>
  )
}

function RoleRequirementsPanel({ roleId }: { roleId: string }) {
  const { t } = useTranslation('attendance')
  const { toast } = useToast()
  const { data: reqs = [] } = useRoleQualRequirements(roleId)
  const upsert = useUpsertRoleQualRequirement()
  const deactivate = useDeactivateRoleQualRequirement()
  const [qualKey, setQualKey] = useState('')

  async function addReq() {
    const key = qualKey.toLowerCase().replace(/[^a-z0-9_]/g, '')
    if (!key) return
    try {
      await upsert.mutateAsync({ role_id: roleId, qualification_key: key, required: true })
      setQualKey('')
      toast({ title: t('planificacio.roles_req_saved', 'Requisit afegit') })
    } catch (err) {
      toast({
        variant: 'destructive',
        title: t('planificacio.roles_req_error', 'Error afegint requisit'),
        description: err instanceof Error ? err.message : String(err),
      })
    }
  }

  return (
    <div className="rounded-lg border p-3 space-y-2">
      <h4 className="text-xs font-semibold uppercase tracking-wide text-muted-foreground">
        {t('planificacio.roles_reqs_title', 'Qualificacions requerides')}
      </h4>
      <div className="flex gap-2">
        <input
          value={qualKey}
          onChange={(e) => setQualKey(e.target.value)}
          placeholder={t('planificacio.roles_reqs_placeholder', 'ex. carretilla, manipulacio_aliments')}
          className="flex-1 border rounded px-2 py-1 text-xs bg-background"
        />
        <Button type="button" size="sm" onClick={() => void addReq()} disabled={!qualKey.trim()}>
          <Plus className="h-3.5 w-3.5" />
        </Button>
      </div>
      {reqs.length === 0 ? (
        <p className="text-xs text-muted-foreground">
          {t('planificacio.roles_reqs_empty', 'Cap requisit. El rol només exigeix l\'assignació.')}
        </p>
      ) : (
        <ul className="space-y-1">
          {reqs.map((r) => (
            <li key={r.id} className="flex items-center justify-between text-xs">
              <span>
                {r.qualification_key}
                {r.required ? (
                  <span className="ml-1 text-muted-foreground">
                    ({t('planificacio.roles_req_required', 'obligatori')})
                  </span>
                ) : null}
              </span>
              <Button
                type="button"
                size="icon"
                variant="ghost"
                className="h-6 w-6"
                onClick={() => void deactivate.mutateAsync({ id: r.id, role_id: roleId })}
              >
                <Trash2 className="h-3 w-3 text-destructive" />
              </Button>
            </li>
          ))}
        </ul>
      )}
    </div>
  )
}
