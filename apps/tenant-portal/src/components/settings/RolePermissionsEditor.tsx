import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import { LockIcon, InfoIcon, AlertTriangleIcon, CheckIcon, XIcon } from 'lucide-react'
import { useRolePermissions, useUpdateRolePermissions, type EditableRole } from '../../hooks/useRolePermissions'
import {
  ALL_PERMISSION_KEYS,
  BASE_ROLE_PERMISSIONS,
  type PermissionKey,
} from '../../lib/permissions'
import { useToast } from '@/hooks/use-toast'

// ---------------------------------------------------------------------------
// Agrupació de permisos per categoria (per display)
// ---------------------------------------------------------------------------
const PERMISSION_GROUPS: { key: string; permissions: PermissionKey[] }[] = [
  {
    key: 'storage',
    permissions: ['storage.view', 'storage.upload', 'storage.delete', 'storage.manage'],
  },
  {
    key: 'calendar',
    permissions: ['calendar.view', 'calendar.edit', 'calendar.manage'],
  },
  {
    key: 'email',
    permissions: ['email.view', 'email.send', 'email.manage'],
  },
  {
    key: 'invoices',
    permissions: ['invoices.view', 'invoices.edit', 'invoices.manage'],
  },
  {
    key: 'members',
    permissions: ['members.view', 'members.invite', 'members.manage'],
  },
  {
    key: 'sites',
    permissions: ['sites.view', 'sites.create', 'sites.manage'],
  },
  {
    key: 'settings',
    permissions: ['settings.view', 'settings.manage', 'permissions.manage'],
  },
]

const EDITABLE_ROLES: EditableRole[] = ['viewer', 'member', 'manager']

interface RolePermissionsEditorProps {
  isOwner: boolean
}

export function RolePermissionsEditor({ isOwner }: RolePermissionsEditorProps) {
  const { t } = useTranslation('settings')
  const { toast } = useToast()

  const { data, isLoading, error } = useRolePermissions()
  const updateMutation = useUpdateRolePermissions()

  // Estado local per a l'edició (BASE permissions per rol, no acumulades)
  const [pendingBase, setPendingBase] = useState<
    Partial<Record<EditableRole, PermissionKey[]>> | null
  >(null)

  // Inicialitza pendingBase quan es carreguen les dades (si no hi ha cap edició activa)
  const currentBase: Partial<Record<EditableRole, PermissionKey[]>> = pendingBase ??
    data?.current_customization ?? {}

  const [showEditor, setShowEditor] = useState(false)
  const [savedJustNow, setSavedJustNow] = useState(false)

  // Comprova si hi ha canvis pendents respecte al que està desat
  const hasPendingChanges = pendingBase !== null &&
    JSON.stringify(pendingBase) !== JSON.stringify(data?.current_customization ?? {})

  // ---------------------------------------------------------------------------
  // Helpers per a l'editor
  // ---------------------------------------------------------------------------
  function getBaseForRole(role: EditableRole): PermissionKey[] {
    return currentBase[role] ?? BASE_ROLE_PERMISSIONS[role]
  }

  function togglePermissionInBase(role: EditableRole, perm: PermissionKey, checked: boolean) {
    const current = getBaseForRole(role)
    const updated = checked
      ? [...new Set([...current, perm])]
      : current.filter((p) => p !== perm)

    setPendingBase((prev) => ({
      ...(prev ?? data?.current_customization ?? {}),
      [role]: updated,
    }))
  }

  function resetToDefaults() {
    setPendingBase({})
  }

  function cancelEditing() {
    setPendingBase(null)
    setShowEditor(false)
  }

  async function handleSave() {
    if (pendingBase === null) return
    try {
      await updateMutation.mutateAsync(pendingBase)
      setPendingBase(null)
      setSavedJustNow(true)
      setTimeout(() => setSavedJustNow(false), 4000)
      toast({
        title: t('permissions.editor.saved', 'Canvis desats'),
        description: t(
          'permissions.propagation_warning.description',
          "Els canvis s'apliquen al teu compte immediatament. La resta de membres veuran els canvis al proper inici de sessió.",
        ),
      })
    } catch (err) {
      toast({
        variant: 'destructive',
        title: t('permissions.editor.error', 'Error en desar els permisos'),
        description: err instanceof Error ? err.message : String(err),
      })
    }
  }

  // ---------------------------------------------------------------------------
  // Loading / Error states
  // ---------------------------------------------------------------------------
  if (isLoading) {
    return (
      <div className="space-y-3 animate-pulse">
        {[1, 2, 3].map((i) => (
          <div key={i} className="h-12 bg-muted rounded-xl" />
        ))}
      </div>
    )
  }

  if (error || !data) {
    return (
      <div className="rounded-xl border border-destructive/30 bg-destructive/5 px-5 py-4 text-sm text-destructive">
        {t('permissions.editor.error', 'Error en carregar els permisos')}
      </div>
    )
  }

  // ---------------------------------------------------------------------------
  // Read-only notice per a no owners
  // ---------------------------------------------------------------------------
  if (!isOwner) {
    return (
      <div className="space-y-6">
        <div className="flex items-start gap-3 rounded-xl border border-border bg-muted/50 px-5 py-4">
          <LockIcon className="mt-0.5 h-5 w-5 shrink-0 text-muted-foreground" />
          <div>
            <p className="text-sm font-medium text-foreground">
              {t('permissions.read_only_notice.title', 'Accés de lectura')}
            </p>
            <p className="mt-0.5 text-sm text-muted-foreground">
              {t(
                'permissions.read_only_notice.description',
                'Pots veure els permisos actuals del teu rol. Només el propietari pot modificar-los.',
              )}
            </p>
          </div>
        </div>

        <PermissionsMatrix data={data} />
      </div>
    )
  }

  // ---------------------------------------------------------------------------
  // Vista owner: matriu + editor
  // ---------------------------------------------------------------------------
  return (
    <div className="space-y-6">

      {/* Banner de propagació quan s'acaba de desar */}
      {savedJustNow && (
        <div className="flex items-start gap-3 rounded-xl border border-amber-200 bg-amber-50 px-5 py-4">
          <AlertTriangleIcon className="mt-0.5 h-5 w-5 shrink-0 text-amber-600" />
          <div>
            <p className="text-sm font-medium text-amber-900">
              {t('permissions.propagation_warning.title', 'Propagació de canvis')}
            </p>
            <p className="mt-0.5 text-sm text-amber-800">
              {t(
                'permissions.propagation_warning.description',
                "Els canvis s'apliquen al teu compte immediatament. La resta de membres veuran els canvis al proper inici de sessió (~60 minuts).",
              )}
            </p>
          </div>
        </div>
      )}

      {/* Metadades de l'última modificació */}
      {data.updated_at ? (
        <p className="text-xs text-muted-foreground">
          {t('permissions.last_updated', 'Última modificació')}:{' '}
          {new Date(data.updated_at).toLocaleString('ca-ES')}
        </p>
      ) : (
        <p className="text-xs text-muted-foreground">
          {t('permissions.never_customized', "S'usen els permisos per defecte del sistema.")}
        </p>
      )}

      {/* Matriu de permisos efectius (read-only, sempre visible) */}
      <div className="rounded-2xl border bg-card overflow-hidden">
        <div className="px-6 py-4 border-b bg-muted/30">
          <h3 className="text-sm font-semibold">
            {t('permissions.matrix.title', 'Vista general de permisos')}
          </h3>
          <p className="text-xs text-muted-foreground mt-0.5">
            {t(
              'permissions.matrix.description',
              'Permisos efectius per cada rol, incloent herència dels rols inferiors.',
            )}
          </p>
        </div>
        <PermissionsMatrix data={data} />
      </div>

      {/* Editor de permisos base (owner) */}
      <div className="rounded-2xl border bg-card overflow-hidden">
        <div className="px-6 py-4 border-b flex items-center justify-between">
          <div>
            <h3 className="text-sm font-semibold">
              {t('permissions.editor.title', 'Personalitzar permisos base')}
            </h3>
            <p className="text-xs text-muted-foreground mt-0.5">
              {t(
                'permissions.editor.description',
                'Defineix quins permisos aporta cada rol (sense comptar l\'herència).',
              )}
            </p>
          </div>
          {!showEditor && (
            <button
              type="button"
              onClick={() => {
                setShowEditor(true)
                // Pre-carrega l'estat actual per editar
                setPendingBase(data.current_customization ?? {})
              }}
              className="text-xs font-medium text-primary hover:underline"
            >
              {t('permissions.editor.title', 'Editar')}
            </button>
          )}
        </div>

        {showEditor && (
          <div className="p-6 space-y-6">
            {/* Info sobre la lògica d'herència */}
            <div className="flex items-start gap-2 text-xs text-muted-foreground bg-muted/40 rounded-lg px-4 py-3">
              <InfoIcon className="mt-0.5 h-3.5 w-3.5 shrink-0" />
              <span>
                Els permisos s'acumulen: manager hereta tots els de member, i member tots els de viewer.
                Aquí edites el que cada rol aporta per sobre del rol inferior.
              </span>
            </div>

            {/* Editor per rol */}
            {EDITABLE_ROLES.map((role) => (
              <RoleBaseEditor
                key={role}
                role={role}
                basePermissions={getBaseForRole(role)}
                onToggle={(perm, checked) => togglePermissionInBase(role, perm, checked)}
              />
            ))}

            {/* Botons d'acció */}
            <div className="flex items-center gap-3 pt-2 border-t">
              <button
                type="button"
                onClick={handleSave}
                disabled={!hasPendingChanges || updateMutation.isPending}
                className="inline-flex items-center gap-1.5 rounded-lg bg-primary px-4 py-2 text-sm font-medium text-primary-foreground hover:bg-primary/90 disabled:opacity-50 disabled:cursor-not-allowed"
              >
                {updateMutation.isPending
                  ? t('permissions.editor.saving', 'Desant...')
                  : t('permissions.editor.save', 'Desar canvis')}
              </button>
              <button
                type="button"
                onClick={resetToDefaults}
                className="text-sm text-muted-foreground hover:text-foreground"
              >
                {t('permissions.editor.reset_to_defaults', 'Restablir als valors per defecte')}
              </button>
              <button
                type="button"
                onClick={cancelEditing}
                className="ml-auto text-sm text-muted-foreground hover:text-foreground"
              >
                {t('settings.reset', 'Cancel·lar')}
              </button>
            </div>
          </div>
        )}
      </div>
    </div>
  )
}

// ---------------------------------------------------------------------------
// PermissionsMatrix — matriu read-only de permisos efectius
// ---------------------------------------------------------------------------
function PermissionsMatrix({ data }: { data: { effective: Record<string, string[] | ['*']> } }) {
  const { t } = useTranslation('settings')

  return (
    <div className="overflow-x-auto">
      <table className="w-full text-sm">
        <thead>
          <tr className="border-b bg-muted/20">
            <th className="px-4 py-3 text-left font-medium text-muted-foreground w-48">
              Permís
            </th>
            {(['viewer', 'member', 'manager', 'owner'] as const).map((role) => (
              <th
                key={role}
                className="px-4 py-3 text-center font-medium text-muted-foreground"
              >
                {t(`permissions.roles.${role}`, role)}
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {PERMISSION_GROUPS.map((group) => (
            <>
              {/* Fila de capçalera del grup */}
              <tr key={`group-${group.key}`} className="bg-muted/10 border-t">
                <td
                  colSpan={5}
                  className="px-4 py-2 text-xs font-semibold uppercase tracking-wider text-muted-foreground"
                >
                  {t(`permissions.groups.${group.key}`, group.key)}
                </td>
              </tr>
              {/* Files de permisos del grup */}
              {group.permissions.map((perm) => (
                <PermissionRow
                  key={perm}
                  permKey={perm}
                  effective={data.effective as Record<string, string[]>}
                />
              ))}
            </>
          ))}
        </tbody>
      </table>
    </div>
  )
}

function PermissionRow({
  permKey,
  effective,
}: {
  permKey: PermissionKey
  effective: Record<string, string[]>
}) {
  const { t } = useTranslation('settings')

  function hasEffective(role: string): boolean {
    const perms = effective[role] ?? []
    return perms.includes('*') || perms.includes(permKey)
  }

  return (
    <tr className="border-t border-border/50 hover:bg-muted/10 transition-colors">
      <td className="px-4 py-2.5 text-muted-foreground">
        {t(`permissions.permission_labels.${permKey}`, permKey)}
      </td>
      {(['viewer', 'member', 'manager', 'owner'] as const).map((role) => (
        <td key={role} className="px-4 py-2.5 text-center">
          {role === 'owner' ? (
            <span
              title={t('permissions.matrix.owner_wildcard', 'Accés total')}
              className="inline-flex justify-center text-green-600"
            >
              <CheckIcon className="h-4 w-4" />
            </span>
          ) : hasEffective(role) ? (
            <span
              title={t('permissions.matrix.has_permission', 'Té el permís')}
              className="inline-flex justify-center text-green-600"
            >
              <CheckIcon className="h-4 w-4" />
            </span>
          ) : (
            <span
              title={t('permissions.matrix.no_permission', 'No té el permís')}
              className="inline-flex justify-center text-muted-foreground/40"
            >
              <XIcon className="h-4 w-4" />
            </span>
          )}
        </td>
      ))}
    </tr>
  )
}

// ---------------------------------------------------------------------------
// RoleBaseEditor — editor de permisos base per un sol rol
// ---------------------------------------------------------------------------
function RoleBaseEditor({
  role,
  basePermissions,
  onToggle,
}: {
  role: EditableRole
  basePermissions: PermissionKey[]
  onToggle: (perm: PermissionKey, checked: boolean) => void
}) {
  const { t } = useTranslation('settings')
  const baseSet = new Set(basePermissions)

  return (
    <div className="space-y-3">
      <h4 className="text-sm font-medium">
        {t(`permissions.roles.${role}`, role)}
        <span className="ml-2 text-xs text-muted-foreground font-normal">
          {t('permissions.editor.role_base_title', 'Permisos base').replace('{{role}}', '')}
        </span>
      </h4>
      <div className="grid grid-cols-2 md:grid-cols-3 gap-2">
        {ALL_PERMISSION_KEYS.map((perm) => (
          <label
            key={perm}
            className="flex items-center gap-2 rounded-lg border px-3 py-2 text-xs cursor-pointer hover:bg-muted/50 transition-colors"
          >
            <input
              type="checkbox"
              checked={baseSet.has(perm)}
              onChange={(e) => onToggle(perm, e.target.checked)}
              className="h-3.5 w-3.5 rounded"
            />
            <span className="text-foreground">
              {t(`permissions.permission_labels.${perm}`, perm)}
            </span>
          </label>
        ))}
      </div>
    </div>
  )
}
