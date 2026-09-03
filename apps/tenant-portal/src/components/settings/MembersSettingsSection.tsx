import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import { Sparkles } from 'lucide-react'
import { supabase } from '../../lib/supabase'
import { useMembers, type MemberInfo } from '../../hooks/useMembers'
import type { SiteInfo } from '../../hooks/useSites'
import type { TenantInfo } from '../../hooks/useTenants'
import { fetchAiConfigForTenant } from '@/features/ai/api/aiRpc'
import { MemberAiConfigModal } from '@/features/ai/components/MemberAiConfigModal'

type MemberRole = 'owner' | 'manager' | 'member' | 'viewer'

const ROLE_OPTIONS: MemberRole[] = ['owner', 'manager', 'member', 'viewer']

interface InviteMemberResult {
  success: true
  user_id: string
  membership_id: string
  invited: boolean
}

interface Props {
  activeTenant: TenantInfo
  userId: string
  sites: SiteInfo[]
}

function getRoleLabel(role: string, t: (k: string, f: string) => string): string {
  switch (role) {
    case 'owner':
      return t('settings.members.roles.owner', 'Propietari')
    case 'manager':
      return t('settings.members.roles.manager', 'Manager')
    case 'member':
      return t('settings.members.roles.member', 'Membre')
    case 'viewer':
      return t('settings.members.roles.viewer', 'Visualitzador')
    default:
      return role
  }
}

function getErrorMessage(error: unknown): string {
  if (error instanceof Error) return error.message
  if (typeof error === 'object' && error !== null && 'message' in error) {
    const maybeMessage = (error as { message?: unknown }).message
    if (typeof maybeMessage === 'string') return maybeMessage
  }
  return ''
}

async function getFunctionErrorMessage(error: unknown): Promise<string | null> {
  if (typeof error !== 'object' || error === null || !('context' in error)) {
    return null
  }

  const context = (error as { context?: unknown }).context
  if (!(context instanceof Response)) {
    return null
  }

  try {
    const payload = (await context.clone().json()) as { message?: unknown; error?: unknown }
    if (typeof payload.message === 'string' && payload.message.trim()) {
      return payload.message
    }
    if (typeof payload.error === 'string' && payload.error.trim()) {
      return payload.error
    }
  } catch {
    try {
      const text = await context.clone().text()
      if (text.trim()) return text
    } catch {
      return null
    }
  }

  return null
}

function mapFriendlyError(error: unknown, t: (k: string, f: string) => string): string {
  const msg = getErrorMessage(error).toLowerCase()

  if (msg.includes('quota_exceeded')) {
    return t(
      'settings.members.errors.quota_reactivate',
      "No pots reactivar l'element perquè superes el límit del pla",
    )
  }

  if (msg.includes('last_owner') || msg.includes('last owner')) {
    return t(
      'settings.members.errors.last_owner',
      "No pots desactivar o modificar l'últim propietari actiu.",
    )
  }

  return getErrorMessage(error) || t('settings.members.errors.generic', 'S\'ha produït un error inesperat.')
}

export function MembersSettingsSection({ activeTenant, userId, sites }: Props) {
  const { t } = useTranslation('common')
  const { t: ts } = useTranslation('settings')
  const queryClient = useQueryClient()

  const [showInvite, setShowInvite] = useState(false)
  const [isArchiveOpen, setIsArchiveOpen] = useState(false)
  const [aiMember, setAiMember] = useState<MemberInfo | null>(null)
  const [inviteEmail, setInviteEmail] = useState('')
  const [inviteRole, setInviteRole] = useState<MemberRole>('member')
  const [inviteSiteId, setInviteSiteId] = useState('')

  const {
    data: activeMembers = [],
    isLoading: activeMembersLoading,
    isError: activeMembersError,
    error: activeMembersErrorObject,
  } = useMembers(activeTenant.id, userId, 'active')

  const {
    data: inactiveMembers = [],
    isLoading: inactiveMembersLoading,
    isError: inactiveMembersError,
    error: inactiveMembersErrorObject,
  } = useMembers(activeTenant.id, userId, 'inactive', { enabled: isArchiveOpen })

  const maxMembers = activeTenant.max_members ?? 1
  const usedMembers = activeMembers.length
  const atQuota = maxMembers > 0 && usedMembers >= maxMembers
  const quotaPct = maxMembers > 0 ? Math.min((usedMembers / maxMembers) * 100, 100) : 0
  const isOwner = activeTenant.role === 'owner'

  const { data: aiConfig } = useQuery({
    queryKey: ['ai_config', activeTenant.id],
    enabled: isOwner,
    queryFn: () => fetchAiConfigForTenant(activeTenant.id),
  })
  const showAiConfigButton = isOwner && !!aiConfig?.configured

  async function refreshSessionIfCurrentUser(targetUserId: string) {
    if (targetUserId !== userId) return

    await supabase.auth.refreshSession()
    await queryClient.invalidateQueries({ queryKey: ['tenants', userId] })
    await queryClient.invalidateQueries({ queryKey: ['sites', activeTenant.id] })
  }

  const inviteMutation = useMutation({
    mutationFn: async () => {
      const payload = {
        email: inviteEmail.trim(),
        role: inviteRole,
        site_id: inviteSiteId || null,
      }

      const { data, error } = await supabase.functions.invoke('invite-member', {
        headers: { 'x-tenant-id': activeTenant.id },
        body: payload,
      })

      if (error) {
        const detailedMessage = await getFunctionErrorMessage(error)
        if (detailedMessage) {
          throw new Error(detailedMessage)
        }
        throw error
      }

      const asRecord = (data ?? {}) as Record<string, unknown>
      if (typeof asRecord.error === 'string') {
        throw new Error(typeof asRecord.message === 'string' ? asRecord.message : asRecord.error)
      }

      return data as InviteMemberResult
    },
    onSuccess: async (result) => {
      await refreshSessionIfCurrentUser(result.user_id)
      await queryClient.invalidateQueries({ queryKey: ['members', activeTenant.id, 'active'] })
      await queryClient.invalidateQueries({ queryKey: ['members', activeTenant.id, 'inactive'] })

      setInviteEmail('')
      setInviteRole('member')
      setInviteSiteId('')
      setShowInvite(false)
    },
  })

  const updateRoleMutation = useMutation({
    mutationFn: async ({ memberId, role }: { memberId: string; role: MemberRole; targetUserId: string }) => {
      const { error } = await (supabase as any)
        .schema('data')
        .from('tenant_members')
        .update({ role })
        .eq('id', memberId)

      if (error) throw error
    },
    onSuccess: async (_, variables) => {
      await refreshSessionIfCurrentUser(variables.targetUserId)
      await queryClient.invalidateQueries({ queryKey: ['members', activeTenant.id, 'active'] })
      await queryClient.invalidateQueries({ queryKey: ['members', activeTenant.id, 'inactive'] })
    },
  })

  const deactivateMutation = useMutation({
    mutationFn: async ({ memberId }: { memberId: string; targetUserId: string }) => {
      const { error } = await (supabase as any)
        .schema('data')
        .from('tenant_members')
        .update({ is_active: false })
        .eq('id', memberId)

      if (error) throw error
    },
    onSuccess: async (_, variables) => {
      await refreshSessionIfCurrentUser(variables.targetUserId)
      await queryClient.invalidateQueries({ queryKey: ['members', activeTenant.id, 'active'] })
      await queryClient.invalidateQueries({ queryKey: ['members', activeTenant.id, 'inactive'] })
    },
  })

  const reactivateMutation = useMutation({
    mutationFn: async ({ memberId }: { memberId: string; targetUserId: string }) => {
      const { error } = await (supabase as any)
        .schema('data')
        .from('tenant_members')
        .update({ is_active: true })
        .eq('id', memberId)

      if (error) throw error
    },
    onSuccess: async (_, variables) => {
      await refreshSessionIfCurrentUser(variables.targetUserId)
      await queryClient.invalidateQueries({ queryKey: ['members', activeTenant.id, 'active'] })
      await queryClient.invalidateQueries({ queryKey: ['members', activeTenant.id, 'inactive'] })
    },
  })

  return (
    <section
      id="membres"
      aria-labelledby="heading-membres"
      className="rounded-2xl border bg-card p-6 scroll-mt-6 space-y-5"
    >
      <div className="flex items-start justify-between gap-4">
        <div>
          <h2 id="heading-membres" className="text-lg font-semibold text-foreground">
            {t('settings.sections.members', 'Membres')}
          </h2>
          <p className="text-sm text-muted-foreground mt-0.5">
            {t('settings.members.description', 'Gestiona els membres de l\'organització i els seus rols.')}
          </p>
        </div>
        <button
          onClick={() => setShowInvite(true)}
          disabled={inviteMutation.isPending || atQuota}
          title={atQuota ? t('settings.members.quota_reached', 'Has assolit el límit del teu pla') : undefined}
          className="shrink-0 text-sm px-4 py-2 rounded-lg bg-primary text-primary-foreground font-medium hover:opacity-90 transition disabled:opacity-40 disabled:cursor-not-allowed"
        >
          {t('settings.members.invite', 'Convidar membre')}
        </button>
      </div>

      <div className="space-y-1.5">
        <div className="flex items-center justify-between text-xs text-muted-foreground">
          <span>
            {t('settings.members.usage', '{{used}} de {{max}} membres actius', {
              used: usedMembers,
              max: maxMembers,
            })}
          </span>
          <span>{activeTenant.plan_display_name ?? activeTenant.plan_name ?? '—'}</span>
        </div>
        <div className="w-full h-1.5 bg-muted rounded-full overflow-hidden">
          <div
            className={`h-full rounded-full transition-all ${atQuota ? 'bg-destructive' : 'bg-primary'}`}
            style={{ width: `${quotaPct}%` }}
          />
        </div>
        {atQuota && (
          <p className="text-xs text-destructive font-medium">
            {t(
              'settings.members.quota_message',
              'Has assolit el límit de membres del teu pla. Millora el pla per afegir-ne més.',
            )}
          </p>
        )}
      </div>

      {activeMembersError && (
        <div className="rounded-lg bg-destructive/10 border border-destructive/30 px-4 py-3 text-sm text-destructive">
          {mapFriendlyError(activeMembersErrorObject, t)}
        </div>
      )}

      {activeMembersLoading ? (
        <div className="rounded-xl border p-4 text-sm text-muted-foreground">
          {t('settings.members.loading', 'Carregant membres...')}
        </div>
      ) : activeMembers.length === 0 ? (
        <div className="rounded-xl border-2 border-dashed border-border p-8 text-center">
          <p className="text-sm text-muted-foreground">
            {t('settings.members.empty', 'No hi ha membres actius en aquest moment.')}
          </p>
        </div>
      ) : (
        <ul className="divide-y divide-border rounded-xl border overflow-hidden">
          {activeMembers.map((member) => (
            <li key={member.id} className="bg-card px-4 py-3 flex items-start justify-between gap-3">
              <div className="min-w-0">
                <p className="text-sm font-medium text-foreground truncate">
                  {member.full_name || member.email}
                </p>
                <p className="text-xs text-muted-foreground truncate mt-0.5">{member.email}</p>
              </div>

              <div className="flex items-center gap-2 shrink-0">
                {showAiConfigButton && (
                  <button
                    type="button"
                    onClick={() => setAiMember(member)}
                    className="inline-flex items-center gap-1 text-xs px-3 py-1.5 rounded-lg border border-indigo-200 text-indigo-700 hover:bg-indigo-50 transition"
                    title={ts('settings.members.ai_config', 'Configuració IA')}
                  >
                    <Sparkles className="h-3.5 w-3.5" />
                    {ts('ai.memberAiOpen', 'IA')}
                  </button>
                )}
                <label className="sr-only" htmlFor={`member-role-${member.id}`}>
                  {t('settings.members.role_label', 'Rol del membre')}
                </label>
                <select
                  id={`member-role-${member.id}`}
                  value={member.role}
                  onChange={(e) => {
                    updateRoleMutation.mutate({
                      memberId: member.id,
                      role: e.target.value as MemberRole,
                      targetUserId: member.user_id,
                    })
                  }}
                  className="text-xs rounded-lg border border-input bg-background px-2 py-1.5"
                >
                  {ROLE_OPTIONS.map((role) => (
                    <option key={role} value={role}>
                      {getRoleLabel(role, t)}
                    </option>
                  ))}
                </select>

                <button
                  onClick={() =>
                    deactivateMutation.mutate({ memberId: member.id, targetUserId: member.user_id })
                  }
                  className="text-xs px-3 py-1.5 rounded-lg border border-border text-muted-foreground hover:bg-accent transition"
                >
                  {t('settings.members.deactivate', 'Desactivar')}
                </button>
              </div>
            </li>
          ))}
        </ul>
      )}

      {(inviteMutation.isError || updateRoleMutation.isError || deactivateMutation.isError || reactivateMutation.isError) && (
        <div className="rounded-lg bg-destructive/10 border border-destructive/30 px-4 py-3 text-sm text-destructive">
          {mapFriendlyError(
            inviteMutation.error ??
              updateRoleMutation.error ??
              deactivateMutation.error ??
              reactivateMutation.error,
            t,
          )}
        </div>
      )}

      <div className="border-t pt-4">
        <button
          onClick={() => setIsArchiveOpen((v) => !v)}
          className="text-sm font-medium text-foreground hover:underline"
        >
          {isArchiveOpen
            ? t('settings.members.archive.hide', 'Amagar arxiu de membres inactius')
            : t('settings.members.archive.show', 'Mostrar arxiu de membres inactius')}
        </button>

        {isArchiveOpen && (
          <div className="mt-3">
            {inactiveMembersLoading ? (
              <div className="rounded-xl border p-4 text-sm text-muted-foreground">
                {t('settings.members.archive.loading', 'Carregant arxiu...')}
              </div>
            ) : inactiveMembersError ? (
              <div className="rounded-lg bg-destructive/10 border border-destructive/30 px-4 py-3 text-sm text-destructive">
                {mapFriendlyError(inactiveMembersErrorObject, t)}
              </div>
            ) : inactiveMembers.length === 0 ? (
              <div className="rounded-xl border-2 border-dashed border-border p-6 text-center text-sm text-muted-foreground">
                {t('settings.members.archive.empty', 'No hi ha membres inactius a l\'arxiu.')}
              </div>
            ) : (
              <ul className="divide-y divide-border rounded-xl border overflow-hidden">
                {inactiveMembers.map((member) => (
                  <li key={member.id} className="bg-card px-4 py-3 flex items-start justify-between gap-3">
                    <div className="min-w-0">
                      <p className="text-sm font-medium text-foreground truncate">
                        {member.full_name || member.email}
                      </p>
                      <p className="text-xs text-muted-foreground truncate mt-0.5">{member.email}</p>
                    </div>
                    <button
                      onClick={() =>
                        reactivateMutation.mutate({ memberId: member.id, targetUserId: member.user_id })
                      }
                      className="shrink-0 text-xs px-3 py-1.5 rounded-lg bg-primary text-primary-foreground hover:opacity-90 transition"
                    >
                      {t('settings.members.reactivate', 'Reactivar')}
                    </button>
                  </li>
                ))}
              </ul>
            )}
          </div>
        )}
      </div>

      {aiMember && (
        <MemberAiConfigModal
          open={!!aiMember}
          onOpenChange={(open) => {
            if (!open) setAiMember(null)
          }}
          tenantId={activeTenant.id}
          member={{
            user_id: aiMember.user_id,
            email: aiMember.email,
            full_name: aiMember.full_name,
            role: aiMember.role,
          }}
        />
      )}

      {showInvite && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40">
          <div className="bg-card rounded-2xl shadow-xl border border-border w-full max-w-md p-6 space-y-5">
            <h3 className="text-lg font-semibold text-foreground">
              {t('settings.members.invite_title', 'Convidar membre')}
            </h3>

            <form
              onSubmit={(e) => {
                e.preventDefault()
                inviteMutation.mutate()
              }}
              className="space-y-4"
            >
              <div className="space-y-1.5">
                <label className="block text-sm font-medium text-foreground">
                  {t('settings.members.email', 'Correu electrònic')} <span className="text-destructive">*</span>
                </label>
                <input
                  autoFocus
                  type="email"
                  value={inviteEmail}
                  onChange={(e) => setInviteEmail(e.target.value)}
                  placeholder={t('settings.members.email_placeholder', 'nom@empresa.com')}
                  disabled={inviteMutation.isPending}
                  className="w-full text-sm rounded-lg border border-input bg-background px-3 py-2 focus:outline-none focus:ring-2 focus:ring-ring disabled:opacity-50"
                />
              </div>

              <div className="space-y-1.5">
                <label className="block text-sm font-medium text-foreground">
                  {t('settings.members.role', 'Rol')} <span className="text-destructive">*</span>
                </label>
                <select
                  value={inviteRole}
                  onChange={(e) => setInviteRole(e.target.value as MemberRole)}
                  disabled={inviteMutation.isPending}
                  className="w-full text-sm rounded-lg border border-input bg-background px-3 py-2 focus:outline-none focus:ring-2 focus:ring-ring disabled:opacity-50"
                >
                  {ROLE_OPTIONS.map((role) => (
                    <option key={role} value={role}>
                      {getRoleLabel(role, t)}
                    </option>
                  ))}
                </select>
              </div>

              <div className="space-y-1.5">
                <label className="block text-sm font-medium text-foreground">
                  {t('settings.members.scope_site', 'Local específic')}
                  <span className="text-muted-foreground text-xs ml-1">
                    ({t('common.optional', 'opcional')})
                  </span>
                </label>
                <select
                  value={inviteSiteId}
                  onChange={(e) => setInviteSiteId(e.target.value)}
                  disabled={inviteMutation.isPending}
                  className="w-full text-sm rounded-lg border border-input bg-background px-3 py-2 focus:outline-none focus:ring-2 focus:ring-ring disabled:opacity-50"
                >
                  <option value="">
                    {t('settings.members.scope_global', 'Accés global al tenant')}
                  </option>
                  {sites.map((site) => (
                    <option key={site.id} value={site.id}>
                      {site.name}
                    </option>
                  ))}
                </select>
              </div>

              {inviteMutation.isError && (
                <div className="rounded-lg bg-destructive/10 border border-destructive/30 px-4 py-3 text-sm text-destructive">
                  {mapFriendlyError(inviteMutation.error, t)}
                </div>
              )}

              <div className="flex justify-end gap-3 pt-2">
                <button
                  type="button"
                  onClick={() => setShowInvite(false)}
                  disabled={inviteMutation.isPending}
                  className="text-sm px-4 py-2 rounded-lg border border-border text-muted-foreground hover:bg-accent transition"
                >
                  {t('common.cancel', 'Cancel·lar')}
                </button>
                <button
                  type="submit"
                  disabled={inviteMutation.isPending || !inviteEmail.trim()}
                  className="text-sm px-4 py-2 rounded-lg bg-primary text-primary-foreground font-medium hover:opacity-90 disabled:opacity-50 transition"
                >
                  {inviteMutation.isPending
                    ? t('settings.members.inviting', 'Enviant...')
                    : t('settings.members.invite_confirm', 'Enviar invitació')}
                </button>
              </div>
            </form>
          </div>
        </div>
      )}
    </section>
  )
}
