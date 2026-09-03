import { useCallback, useEffect, useMemo, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { useNodePermissions } from '../api/useNodePermissions'
import { useUpdateNodePermissions } from '../api/useUpdateNodePermissions'
import { useTenantMembers } from '../api/useTenantMembers'
import type { AccessLevel, NodePermission, TenantMember } from '../types/storage.types'

// ─── Types ────────────────────────────────────────────────────────────────────

interface PendingPermission {
  user_id: string
  access_level: AccessLevel
  // enriched from tenant members for display
  email: string
  full_name: string | null
  avatar_url: string | null
}

export interface PermissionsModalProps {
  nodeId: string
  nodeName: string
  tenantId: string
  /** Current restriction state of the node (from FileNode.is_restricted). */
  nodeIsRestricted: boolean
  onClose: () => void
}

// ─── Access level badge colours ───────────────────────────────────────────────

const LEVEL_BADGE: Record<AccessLevel, string> = {
  viewer: 'bg-sky-100 text-sky-700',
  editor: 'bg-violet-100 text-violet-700',
  owner:  'bg-amber-100 text-amber-700',
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

function userInitials(fullName: string | null, email: string): string {
  if (fullName) {
    return fullName
      .split(' ')
      .slice(0, 2)
      .map((w) => w[0])
      .join('')
      .toUpperCase()
  }
  return email.slice(0, 2).toUpperCase()
}

function UserAvatar({ member }: { member: { full_name: string | null; email: string; avatar_url: string | null } }) {
  if (member.avatar_url) {
    return (
      <img
        src={member.avatar_url}
        alt={member.full_name ?? member.email}
        className="h-8 w-8 rounded-full object-cover shrink-0"
      />
    )
  }
  return (
    <span className="flex h-8 w-8 shrink-0 items-center justify-center rounded-full bg-indigo-100 text-xs font-semibold text-indigo-700">
      {userInitials(member.full_name, member.email)}
    </span>
  )
}

// ─── Component ────────────────────────────────────────────────────────────────

export function PermissionsModal({ nodeId, nodeName, tenantId, nodeIsRestricted, onClose }: PermissionsModalProps) {
  const { t } = useTranslation('storage')

  // ── Server state ──────────────────────────────────────────────────────────
  const { data: serverPermissions = [], isLoading: permsLoading } = useNodePermissions(nodeId)
  const { data: members = [], isLoading: membersLoading } = useTenantMembers(tenantId)
  const { mutateAsync: saveMut, isPending: saving, error: saveError } = useUpdateNodePermissions(tenantId)

  // ── Local form state ──────────────────────────────────────────────────────
  const [isRestricted, setIsRestricted] = useState(nodeIsRestricted)
  const [pending, setPending] = useState<PendingPermission[]>([])
  const [search, setSearch] = useState('')
  const [initialised, setInitialised] = useState(false)

  // Sync pending permissions with server data when first loaded
  useEffect(() => {
    if (initialised || permsLoading || membersLoading) return
    setInitialised(true)
    const enriched = serverPermissions.map((np: NodePermission): PendingPermission => ({
      user_id:      np.user_id,
      access_level: np.access_level,
      email:        np.email,
      full_name:    np.full_name,
      avatar_url:   np.avatar_url,
    }))
    setPending(enriched)
  }, [initialised, permsLoading, membersLoading, serverPermissions])

  // ── Member search ─────────────────────────────────────────────────────────
  const addedIds = useMemo(() => new Set(pending.map((p) => p.user_id)), [pending])

  const filteredMembers = useMemo(() => {
    if (!search.trim()) return []
    const q = search.toLowerCase()
    return members.filter(
      (m: TenantMember) =>
        !addedIds.has(m.user_id) &&
        (m.email.toLowerCase().includes(q) ||
          (m.full_name ?? '').toLowerCase().includes(q)),
    )
  }, [search, members, addedIds])

  // ── Handlers ──────────────────────────────────────────────────────────────
  const handleAddMember = useCallback((member: TenantMember) => {
    setPending((prev) => [
      ...prev,
      {
        user_id:     member.user_id,
        access_level: 'viewer' as AccessLevel,
        email:       member.email,
        full_name:   member.full_name,
        avatar_url:  member.avatar_url,
      },
    ])
    setSearch('')
  }, [])

  const handleRemove = useCallback((userId: string) => {
    setPending((prev) => prev.filter((p) => p.user_id !== userId))
  }, [])

  const handleLevelChange = useCallback((userId: string, level: AccessLevel) => {
    setPending((prev) =>
      prev.map((p) => (p.user_id === userId ? { ...p, access_level: level } : p)),
    )
  }, [])

  const handleSave = useCallback(async () => {
    await saveMut({
      nodeId,
      isRestricted,
      permissions: pending.map(({ user_id, access_level }) => ({ user_id, access_level })),
    })
    onClose()
  }, [saveMut, nodeId, isRestricted, pending, onClose])

  // ── Render ────────────────────────────────────────────────────────────────
  const isLoading = permsLoading || membersLoading

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/50 backdrop-blur-sm">
      <div className="bg-card rounded-2xl shadow-xl w-full max-w-md mx-4 flex flex-col max-h-[90vh]">

        {/* Header */}
        <div className="flex items-start justify-between px-6 pt-5 pb-3 border-b border-border">
          <div className="min-w-0 pr-3">
            <h2 className="text-base font-semibold text-foreground">
              {t('storage.acl.modal_title', 'Gestionar accés')}
            </h2>
            <p className="text-xs text-muted-foreground truncate mt-0.5">{nodeName}</p>
          </div>
          <button
            type="button"
            onClick={onClose}
            className="shrink-0 rounded-lg p-1.5 text-muted-foreground hover:bg-accent hover:text-accent-foreground transition"
            aria-label={t('storage.acl.close', 'Tancar')}
          >
            <svg className="h-4 w-4" viewBox="0 0 20 20" fill="currentColor" aria-hidden>
              <path d="M6.28 5.22a.75.75 0 0 0-1.06 1.06L8.94 10l-3.72 3.72a.75.75 0 1 0 1.06 1.06L10 11.06l3.72 3.72a.75.75 0 1 0 1.06-1.06L11.06 10l3.72-3.72a.75.75 0 0 0-1.06-1.06L10 8.94 6.28 5.22z" />
            </svg>
          </button>
        </div>

        {/* Body (scrollable) */}
        <div className="flex-1 overflow-y-auto px-6 py-4 space-y-5">

          {/* Visibility toggle */}
          <div>
            <p className="text-xs font-medium text-muted-foreground uppercase tracking-wider mb-2">
              {t('storage.acl.visibility_label', 'Visibilitat')}
            </p>
            <button
              type="button"
              onClick={() => setIsRestricted((v) => !v)}
              className={`w-full flex items-center gap-3 rounded-xl border-2 px-4 py-3 text-left transition ${
                isRestricted
                  ? 'border-amber-300 bg-amber-50'
                  : 'border-indigo-200 bg-indigo-50'
              }`}
            >
              <span className="text-xl" aria-hidden>{isRestricted ? '🔒' : '🌍'}</span>
              <div className="min-w-0 flex-1">
                <p className="text-sm font-medium text-foreground">
                  {isRestricted
                    ? t('storage.acl.visibility_private', 'Privat')
                    : t('storage.acl.visibility_shared', 'Compartit amb el Tenant')}
                </p>
                <p className="text-xs text-muted-foreground mt-0.5">
                  {isRestricted
                    ? t('storage.acl.visibility_private_desc', 'Només els usuaris autoritzats poden accedir-hi')
                    : t('storage.acl.visibility_shared_desc', 'Tots els membres del tenant poden veure\'l')}
                </p>
              </div>
              {/* Toggle pill */}
              <span
                className={`shrink-0 w-10 h-5 rounded-full transition-colors ${
                  isRestricted ? 'bg-amber-400' : 'bg-indigo-400'
                } relative`}
                aria-hidden
              >
                <span
                  className={`absolute top-0.5 h-4 w-4 rounded-full bg-card shadow transition-transform ${
                    isRestricted ? 'translate-x-5' : 'translate-x-0.5'
                  }`}
                />
              </span>
            </button>
          </div>

          {/* Permissions list — only visible when restricted */}
          {isRestricted && (
            <div>
              <p className="text-xs font-medium text-muted-foreground uppercase tracking-wider mb-2">
                {t('storage.acl.users_label', 'Usuaris amb accés')}
              </p>

              {isLoading ? (
                <div className="flex justify-center py-6">
                  <div className="animate-spin rounded-full h-6 w-6 border-b-2 border-indigo-500" />
                </div>
              ) : (
                <>
                  {/* Existing permission rows */}
                  {pending.length === 0 && (
                    <p className="text-xs text-muted-foreground py-3 text-center">
                      {t('storage.acl.no_users', 'Cap usuari amb accés explícit')}
                    </p>
                  )}
                  <ul className="space-y-1.5">
                    {pending.map((perm) => (
                      <li
                        key={perm.user_id}
                        className="flex items-center gap-3 rounded-lg border border-border bg-muted/50 px-3 py-2"
                      >
                        <UserAvatar member={perm} />
                        <div className="min-w-0 flex-1">
                          <p className="text-sm font-medium text-foreground truncate">
                            {perm.full_name ?? perm.email}
                          </p>
                          {perm.full_name && (
                            <p className="text-xs text-muted-foreground truncate">{perm.email}</p>
                          )}
                        </div>
                        {/* Access level selector */}
                        <select
                          value={perm.access_level}
                          onChange={(e) =>
                            handleLevelChange(perm.user_id, e.target.value as AccessLevel)
                          }
                          className="shrink-0 rounded-md border border-input bg-background px-2 py-1 text-xs text-foreground focus:border-primary focus:ring-1 focus:ring-primary/20 outline-none"
                          aria-label={t('storage.acl.access_level_label', 'Nivell d\'accés')}
                        >
                          <option value="viewer">
                            {t('storage.acl.level_viewer', 'Visualitzador')}
                          </option>
                          <option value="editor">
                            {t('storage.acl.level_editor', 'Editor')}
                          </option>
                          <option value="owner">
                            {t('storage.acl.level_owner', 'Propietari')}
                          </option>
                        </select>
                        {/* Remove button */}
                        <button
                          type="button"
                          onClick={() => handleRemove(perm.user_id)}
                          className="shrink-0 rounded p-0.5 text-muted-foreground/50 hover:text-red-500 hover:bg-red-50 dark:hover:bg-red-950/50 transition"
                          aria-label={t('storage.acl.remove_user', 'Treure accés')}
                        >
                          <svg className="h-3.5 w-3.5" viewBox="0 0 20 20" fill="currentColor" aria-hidden>
                            <path d="M6.28 5.22a.75.75 0 0 0-1.06 1.06L8.94 10l-3.72 3.72a.75.75 0 1 0 1.06 1.06L10 11.06l3.72 3.72a.75.75 0 1 0 1.06-1.06L11.06 10l3.72-3.72a.75.75 0 0 0-1.06-1.06L10 8.94 6.28 5.22z" />
                          </svg>
                        </button>
                      </li>
                    ))}
                  </ul>

                  {/* Add user search */}
                  <div className="mt-3 relative">
                    <input
                      type="text"
                      value={search}
                      onChange={(e) => setSearch(e.target.value)}
                      placeholder={t('storage.acl.search_placeholder', 'Buscar membre del tenant...')}
                      className="w-full rounded-lg border border-input bg-background text-foreground px-3 py-2 text-sm focus:border-primary focus:ring-1 focus:ring-primary/20 outline-none"
                    />
                    {filteredMembers.length > 0 && (
                      <ul className="absolute z-10 w-full mt-1 rounded-xl border border-border bg-card shadow-lg overflow-hidden">
                        {filteredMembers.map((member: TenantMember) => (
                          <li key={member.user_id}>
                            <button
                              type="button"
                              onClick={() => handleAddMember(member)}
                              className="w-full flex items-center gap-3 px-3 py-2 text-left hover:bg-accent transition"
                            >
                              <UserAvatar member={member} />
                              <div className="min-w-0">
                                <p className="text-sm font-medium text-foreground truncate">
                                  {member.full_name ?? member.email}
                                </p>
                                {member.full_name && (
                                  <p className="text-xs text-muted-foreground truncate">{member.email}</p>
                                )}
                              </div>
                              <span className={`ml-auto shrink-0 rounded-full px-2 py-0.5 text-xs font-medium ${
                                LEVEL_BADGE[member.role as AccessLevel] ?? 'bg-muted text-muted-foreground'
                              } bg-muted text-muted-foreground`}>
                                {member.role}
                              </span>
                            </button>
                          </li>
                        ))}
                      </ul>
                    )}
                  </div>
                </>
              )}
            </div>
          )}

          {/* Save error */}
          {saveError && (
            <p className="text-xs text-red-600 rounded-lg border border-red-100 bg-red-50 px-3 py-2">
              {saveError.code === 'insufficient_permissions'
                ? t('storage.acl.error_insufficient_permissions', 'No tens permisos per gestionar l\'accés d\'aquest node')
                : saveError.code === 'user_not_tenant_member'
                  ? t('storage.acl.error_user_not_member', 'Un dels usuaris seleccionats no és membre del tenant')
                  : t('storage.acl.error_generic', "No s'han pogut desar els permisos. Torna-ho a intentar.")}
            </p>
          )}
        </div>

        {/* Footer */}
        <div className="flex items-center justify-end gap-2 px-6 py-4 border-t border-border">
          <button
            type="button"
            onClick={onClose}
            disabled={saving}
            className="rounded-lg border border-border px-3 py-1.5 text-sm text-foreground hover:bg-accent transition"
          >
            {t('storage.actions.cancel', 'Cancel·lar')}
          </button>
          <button
            type="button"
            onClick={handleSave}
            disabled={saving}
            className="rounded-lg bg-indigo-600 px-4 py-1.5 text-sm font-medium text-white hover:bg-indigo-700 disabled:opacity-50 transition"
          >
            {saving
              ? t('storage.acl.saving', 'Desant...')
              : t('storage.acl.save_btn', 'Desar canvis')}
          </button>
        </div>
      </div>
    </div>
  )
}
