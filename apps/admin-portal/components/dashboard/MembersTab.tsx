'use client'

import React, { useMemo, useState, useTransition } from 'react'
import { useTranslation } from 'react-i18next'
import type {
  InviteAssignmentInput,
  MemberAuthDetail,
  MemberRow,
  TenantHealth,
} from '@/app/admin/actions/members'
import {
  deactivateMember,
  deactivateUserMemberships,
  getMemberDetail,
  provisionAndInviteMemberMultiTenant,
  resendInvitation,
  suspendUser,
  updateMemberRole,
} from '@/app/admin/actions/members'

export type { MemberRow }

interface InviteTenantOption {
  tenantId: string
  name: string
}

interface Props {
  tenantId: string
  health: TenantHealth
  members: MemberRow[]
  inviteTenants: InviteTenantOption[]
}

export function MembersTab({ tenantId, health, members, inviteTenants }: Props) {
  const { t } = useTranslation('tenants')

  const ROLE_OPTIONS = [
    { value: 'owner', label: t('tenants.members.roles.owner', 'Propietari') },
    { value: 'manager', label: t('tenants.members.roles.manager', 'Gestor') },
    { value: 'member', label: t('tenants.members.roles.member', 'Membre') },
    { value: 'viewer', label: t('tenants.members.roles.viewer', 'Viewer') },
  ]

  function roleLabel(role: string): string {
    return ROLE_OPTIONS.find((r) => r.value === role)?.label ?? role
  }

  const [showModal, setShowModal] = useState(false)
  const [inviteEmail, setInviteEmail] = useState('')
  const [inviteAssignments, setInviteAssignments] = useState<InviteAssignmentInput[]>([])
  const [inviteError, setInviteError] = useState<string | null>(null)

  const [successMsg, setSuccessMsg] = useState<string | null>(null)
  const [actionError, setActionError] = useState<string | null>(null)

  const [confirmDeactivate, setConfirmDeactivate] = useState<{
    userId: string
    displayName: string
  } | null>(null)

  const [detailMember, setDetailMember] = useState<MemberRow | null>(null)
  const [detailData, setDetailData] = useState<MemberAuthDetail | null>(null)
  const [detailError, setDetailError] = useState<string | null>(null)
  const [detailPending, startDetail] = useTransition()
  const [showSuspendConfirm, setShowSuspendConfirm] = useState(false)
  const [suspendPending, startSuspend] = useTransition()

  const [expandedUsers, setExpandedUsers] = useState<Record<string, boolean>>({})

  const [resendId, setResendId] = useState<string | null>(null)
  const [removeId, setRemoveId] = useState<string | null>(null)
  const [removeUserId, setRemoveUserId] = useState<string | null>(null)
  const [roleChangeId, setRoleChangeId] = useState<string | null>(null)

  const [invitePending, startInvite] = useTransition()
  const [actionPending, startAction] = useTransition()

  const groupedMembers = useMemo(() => {
    const groups = new Map<
      string,
      {
        userId: string
        email: string
        fullName: string | null
        isPending: boolean
        firstLoginAt: string | null
        lastLoginAt: string | null
        assignments: MemberRow[]
      }
    >()

    for (const m of members) {
      const existing = groups.get(m.userId)
      if (existing) {
        existing.assignments.push(m)
      } else {
        groups.set(m.userId, {
          userId: m.userId,
          email: m.email,
          fullName: m.fullName,
          isPending: m.isPending,
          firstLoginAt: m.firstLoginAt,
          lastLoginAt: m.lastLoginAt,
          assignments: [m],
        })
      }
    }

    const result = Array.from(groups.values()).map((g) => {
      g.assignments.sort((a, b) => {
        if (a.scope === b.scope) return a.joinedAt.localeCompare(b.joinedAt)
        return a.scope === 'global' ? -1 : 1
      })
      return g
    })

    result.sort((a, b) => a.email.localeCompare(b.email))
    return result
  }, [members])

  function flash(msg: string) {
    setSuccessMsg(msg)
    setTimeout(() => setSuccessMsg(null), 5000)
  }

  function openModal() {
    setInviteEmail('')
    setInviteError(null)
    setInviteAssignments([{ tenantId, role: 'member' }])
    setShowModal(true)
  }

  function addAssignment() {
    const fallbackTenant = inviteTenants[0]?.tenantId ?? tenantId
    setInviteAssignments((prev) => [...prev, { tenantId: fallbackTenant, role: 'member' }])
  }

  function removeAssignment(index: number) {
    setInviteAssignments((prev) => prev.filter((_, i) => i !== index))
  }

  function updateAssignment(index: number, patch: Partial<InviteAssignmentInput>) {
    setInviteAssignments((prev) =>
      prev.map((a, i) => (i === index ? { ...a, ...patch } : a)),
    )
  }

  function handleInviteSubmit(e: React.FormEvent) {
    e.preventDefault()
    setInviteError(null)
    if (!inviteEmail.trim()) {
      setInviteError(t('tenants.members.modal.errors.email_required', "L'adreça de correu és obligatòria."))
      return
    }
    if (!inviteAssignments.length) {
      setInviteError(t('tenants.members.modal.errors.assignment_required', 'Cal afegir almenys una assignació de tenant.'))
      return
    }

    startInvite(async () => {
      try {
        await provisionAndInviteMemberMultiTenant(inviteEmail.trim(), inviteAssignments)
        setShowModal(false)
        flash(t('tenants.members.flash.invite_sent', 'Invitaci\u00f3 multi-tenant enviada correctament.'))
      } catch (err) {
        setInviteError(err instanceof Error ? err.message : t('tenants.members.flash.unknown_error', 'Error desconegut.'))
      }
    })
  }

  function handleResend(email: string, userId: string) {
    setResendId(userId)
    setActionError(null)
    startAction(async () => {
      try {
        await resendInvitation(email, tenantId)
        flash('Invitació reenviada correctament.')
      } catch (err) {
        setActionError(err instanceof Error ? err.message : 'Error en reenviar la invitació.')
      } finally {
        setResendId(null)
      }
    })
  }

  function handleRoleChange(memberId: string, newRole: string) {
    setRoleChangeId(memberId)
    setActionError(null)
    startAction(async () => {
      try {
        await updateMemberRole(memberId, newRole, tenantId)
        flash(t('tenants.members.flash.role_ok', 'Rol actualitzat correctament.'))
      } catch (err) {
        setActionError(err instanceof Error ? err.message : t('tenants.members.flash.role_error', 'Error en canviar el rol.'))
      } finally {
        setRoleChangeId(null)
      }
    })
  }

  function handleDeactivateUser(userId: string, displayName: string) {
    setConfirmDeactivate({ userId, displayName })
  }

  function handleDeactivateAssignment(memberId: string) {
    setRemoveId(memberId)
    setActionError(null)
    startAction(async () => {
      try {
        await deactivateMember(memberId, tenantId)
        flash("Assignació desactivada correctament.")
      } catch (err) {
        setActionError(err instanceof Error ? err.message : 'Error en desactivar l\'assignació.')
      } finally {
        setRemoveId(null)
      }
    })
  }

  function closeDetail() {
    setDetailMember(null)
    setShowSuspendConfirm(false)
  }

  function doSuspend() {
    if (!detailMember) return
    startSuspend(async () => {
      try {
        await suspendUser(detailMember.userId, tenantId)
        closeDetail()
        flash(t('tenants.members.flash.suspend_ok', 'Usuari sus\u00e8s del sistema correctament.'))
      } catch (err) {
        setDetailError(err instanceof Error ? err.message : t('tenants.members.flash.suspend_error', "Error en suspendre l'usuari."))
        setShowSuspendConfirm(false)
      }
    })
  }

  function openDetail(member: MemberRow) {
    setDetailMember(member)
    setDetailData(null)
    setDetailError(null)
    setShowSuspendConfirm(false)
    startDetail(async () => {
      try {
        const data = await getMemberDetail(member.userId)
        setDetailData(data)
      } catch (err) {
        setDetailError(err instanceof Error ? err.message : t('tenants.members.detail.load_error', 'Error en carregar les dades.'))
      }
    })
  }

  function doDeactivate() {
    if (!confirmDeactivate) return
    const { userId } = confirmDeactivate
    setConfirmDeactivate(null)
    setRemoveUserId(userId)
    setActionError(null)
    startAction(async () => {
      try {
        await deactivateUserMemberships(tenantId, userId)
        flash(t('tenants.members.flash.deactivate_ok', 'Membre desactivat correctament en aquest tenant.'))
      } catch (err) {
        setActionError(err instanceof Error ? err.message : t('tenants.members.flash.deactivate_error', 'Error en desactivar el membre.'))
      } finally {
        setRemoveUserId(null)
      }
    })
  }

  function toggleExpanded(userId: string) {
    setExpandedUsers((prev) => ({ ...prev, [userId]: !prev[userId] }))
  }

  function formatAssignmentScope(member: MemberRow) {
    return member.scope === 'global' ? t('tenants.members.scope.global', 'Global') : `Site: ${member.siteName ?? t('tenants.members.scope.no_name', 'Sense nom')}`
  }

  return (
    <div className="space-y-6">
      {successMsg && (
        <div className="rounded-lg bg-green-50 border border-green-200 px-4 py-3 text-sm text-green-800 flex items-center gap-2">
          <span>✓</span> {successMsg}
        </div>
      )}
      {actionError && (
        <div className="rounded-lg bg-red-50 border border-red-200 px-4 py-3 text-sm text-red-700">
          {actionError}
        </div>
      )}

      <div className="bg-white rounded-2xl border border-gray-100 p-5 shadow-sm">
        <div className="flex flex-wrap items-center justify-between gap-4">
          <div className="flex flex-wrap gap-3">
            <HealthChip
              label={t('tenants.members.health.places', 'Places ocupades')}
              value={
                health.max_users > 0
                  ? `${health.active_members} / ${health.max_users}`
                  : String(health.active_members)
              }
              variant={health.is_over_quota ? 'danger' : 'neutral'}
            />
            <HealthChip
              label={t('tenants.members.health.owner', 'Owner actiu')}
              value={health.has_active_owner ? t('tenants.members.health.yes', 'S\u00cd') : t('tenants.members.health.no', 'NO')}
              variant={health.has_active_owner ? 'success' : 'danger'}
            />
            {health.is_over_quota && <HealthChip label={t('tenants.members.health.alert', 'Alerta')} value={t('tenants.members.health.quota_exceeded', 'Quota superada')} variant="danger" />}
          </div>
          <button
            onClick={openModal}
            className="flex items-center gap-1.5 px-4 py-2 text-sm font-medium rounded-lg bg-indigo-600 text-white hover:bg-indigo-700 transition"
          >
            <span className="text-base leading-none">+</span>
            {t('tenants.members.actions.invite', 'Convidar membre')}
          </button>
        </div>
      </div>

      <div className="bg-white rounded-2xl border border-gray-100 shadow-sm overflow-hidden">
        {groupedMembers.length === 0 ? (
          <div className="py-16 text-center text-sm text-gray-400">{t('tenants.members.table.empty', 'Cap membre en aquest tenant.')}</div>
        ) : (
          <table className="w-full text-sm">
            <thead>
              <tr className="bg-gray-50 text-left text-xs font-semibold text-gray-500 uppercase tracking-wide">
                <th className="px-5 py-3">{t('tenants.members.table.user', 'Usuari')}</th>
                <th className="px-5 py-3">{t('tenants.members.table.assignments', 'Assignacions')}</th>
                <th className="px-5 py-3">{t('tenants.members.table.status', 'Estat')}</th>
                <th className="px-5 py-3">{t('tenants.members.table.access', 'Accés')}</th>
                <th className="px-5 py-3 text-right">{t('tenants.members.table.actions', 'Accions')}</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-gray-50">
              {groupedMembers.map((group) => {
                const isExpanded = !!expandedUsers[group.userId]
                const primaryMember = group.assignments.find((a) => a.scope === 'global') ?? group.assignments[0]
                const hasActiveAssignments = group.assignments.some((a) => a.isActive)

                return (
                  <React.Fragment key={group.userId}>
                    <tr className={!hasActiveAssignments ? 'opacity-50' : ''}>
                      <td className="px-5 py-4">
                        <div className="flex items-start gap-3">
                          <button
                            onClick={() => toggleExpanded(group.userId)}
                            className="mt-0.5 w-6 h-6 rounded-md border border-gray-200 text-gray-500 hover:bg-gray-50"
                            title={isExpanded ? 'Plegar' : 'Desplegar'}
                          >
                            {isExpanded ? '−' : '+'}
                          </button>
                          <div>
                            <p className="font-medium text-gray-800">
                              {group.fullName ?? <span className="text-gray-400 italic text-xs">{t('tenants.members.table.no_name', 'Sense nom')}</span>}
                            </p>
                            <p className="text-xs text-gray-500 mt-0.5">{group.email}</p>
                          </div>
                        </div>
                      </td>
                      <td className="px-5 py-4 text-xs text-gray-500">
                        <div className="flex flex-wrap gap-1.5">
                          {group.assignments.map((a) => (
                            <span key={a.id} className="px-2 py-0.5 rounded-full bg-gray-100 text-gray-600">
                              {formatAssignmentScope(a)} · {roleLabel(a.role)}
                            </span>
                          ))}
                        </div>
                      </td>
                      <td className="px-5 py-4">
                        {!hasActiveAssignments ? (
                          <span className="inline-flex items-center gap-1 px-2 py-0.5 rounded-full bg-gray-100 text-gray-500 text-xs font-medium">
                            {t('tenants.members.status.inactive', 'Inactiu')}
                          </span>
                        ) : group.isPending ? (
                          <span className="inline-flex items-center gap-1 px-2 py-0.5 rounded-full bg-amber-50 text-amber-700 border border-amber-200 text-xs font-medium">
                            {t('tenants.members.status.pending', "\u23f3 Pendent d'activaci\u00f3")}
                          </span>
                        ) : (
                          <span className="inline-flex items-center gap-1 px-2 py-0.5 rounded-full bg-green-50 text-green-700 text-xs font-medium">
                            {t('tenants.members.status.active', '\u2713 Actiu')}
                          </span>
                        )}
                      </td>
                      <td className="px-5 py-4 text-xs">
                        {group.isPending ? (
                          <span className="text-gray-400 italic">{t('tenants.members.access.never', 'No ha accedit mai')}</span>
                        ) : (
                          <div className="space-y-0.5">
                            <p className="text-gray-400">
                              <span className="font-medium text-gray-500">1r: </span>
                              {group.firstLoginAt ? new Date(group.firstLoginAt).toLocaleDateString('ca-ES') : '—'}
                            </p>
                            <p className="text-gray-400">
                              <span className="font-medium text-gray-500">Últim: </span>
                              {group.lastLoginAt ? new Date(group.lastLoginAt).toLocaleDateString('ca-ES') : '—'}
                            </p>
                          </div>
                        )}
                      </td>
                      <td className="px-5 py-4">
                        <div className="flex items-center justify-end gap-2">
                          {group.isPending && hasActiveAssignments && (
                            <button
                              onClick={() => handleResend(group.email, group.userId)}
                              disabled={resendId === group.userId || actionPending}
                              className="px-3 py-1 text-xs font-medium rounded-md bg-indigo-50 text-indigo-700 hover:bg-indigo-100 transition disabled:opacity-50 disabled:cursor-not-allowed whitespace-nowrap"
                            >
                              {resendId === group.userId ? 'Enviant…' : 'Re-enviar invitació'}
                            </button>
                          )}
                          {hasActiveAssignments && (
                            <button
                              onClick={() => handleDeactivateUser(group.userId, group.fullName ?? group.email)}
                              disabled={removeUserId === group.userId || actionPending}
                              className="px-3 py-1 text-xs font-medium rounded-md text-red-600 hover:bg-red-50 transition disabled:opacity-50 disabled:cursor-not-allowed"
                            >
                              {removeUserId === group.userId ? 'Desactivant…' : 'Desactivar'}
                            </button>
                          )}
                          <button
                            onClick={() => openDetail(primaryMember)}
                            title="Veure detalls"
                            className="p-1 text-gray-400 hover:text-indigo-600 hover:bg-indigo-50 rounded-md transition"
                          >
                            <svg xmlns="http://www.w3.org/2000/svg" className="w-4 h-4" fill="none" viewBox="0 0 24 24" strokeWidth={1.5} stroke="currentColor">
                              <path strokeLinecap="round" strokeLinejoin="round" d="M11.25 11.25l.041-.02a.75.75 0 011.063.852l-.708 2.836a.75.75 0 001.063.853l.041-.021M21 12a9 9 0 11-18 0 9 9 0 0118 0zm-9-3.75h.008v.008H12V8.25z" />
                            </svg>
                          </button>
                        </div>
                      </td>
                    </tr>

                    {isExpanded && (
                      <tr>
                        <td colSpan={5} className="px-5 pb-4">
                          <div className="rounded-xl border border-gray-100 overflow-hidden">
                            <table className="w-full text-xs">
                              <thead className="bg-gray-50 text-gray-500 uppercase tracking-wide">
                                <tr>
                                  <th className="px-3 py-2 text-left">{t('tenants.members.scope.label', 'Scope')}</th>
                                  <th className="px-3 py-2 text-left">{t('tenants.members.roles.label', 'Rol')}</th>
                                  <th className="px-3 py-2 text-left">{t('tenants.members.table.status', 'Estat')}</th>
                                  <th className="px-3 py-2 text-left">{t('tenants.members.table.added', 'Afegit')}</th>
                                  <th className="px-3 py-2 text-right">{t('tenants.members.table.actions', 'Accions')}</th>
                                </tr>
                              </thead>
                              <tbody className="divide-y divide-gray-100">
                                {group.assignments.map((m) => (
                                  <tr key={m.id} className={!m.isActive ? 'opacity-50' : ''}>
                                    <td className="px-3 py-2 text-gray-600">{formatAssignmentScope(m)}</td>
                                    <td className="px-3 py-2">
                                      {m.isLastOwner ? (
                                        <span className="inline-block px-2 py-0.5 rounded-md bg-purple-50 text-purple-700 text-xs font-semibold">
                                          {roleLabel(m.role)}
                                        </span>
                                      ) : (
                                        <select
                                          value={m.role}
                                          disabled={!m.isActive || roleChangeId === m.id || actionPending}
                                          onChange={(e) => handleRoleChange(m.id, e.target.value)}
                                          className="rounded-md border border-gray-200 px-2 py-1 bg-white focus:outline-none focus:ring-2 focus:ring-indigo-400 disabled:opacity-60"
                                        >
                                          {ROLE_OPTIONS.map((r) => (
                                            <option key={r.value} value={r.value}>{r.label}</option>
                                          ))}
                                        </select>
                                      )}
                                    </td>
                                    <td className="px-3 py-2 text-gray-500">{m.isActive ? t('tenants.members.status.active_short', 'Actiu') : t('tenants.members.status.inactive', 'Inactiu')}</td>
                                    <td className="px-3 py-2 text-gray-400">{new Date(m.joinedAt).toLocaleDateString('ca-ES')}</td>
                                    <td className="px-3 py-2 text-right">
                                      {!m.isLastOwner && m.isActive && (
                                        <button
                                          onClick={() => handleDeactivateAssignment(m.id)}
                                          disabled={removeId === m.id || actionPending}
                                          className="px-2 py-1 rounded-md text-red-600 hover:bg-red-50 transition disabled:opacity-50"
                                        >
                                          {removeId === m.id ? t('tenants.members.actions.deactivating', 'Desactivant…') : t('tenants.members.actions.deactivate_assignment', 'Desactivar assignaci\u00f3')}
                                        </button>
                                      )}
                                      {m.isLastOwner && <span className="text-gray-300 italic">{t('tenants.members.actions.last_owner', '\u00daltim owner global')}</span>}
                                    </td>
                                  </tr>
                                ))}
                              </tbody>
                            </table>
                          </div>
                        </td>
                      </tr>
                    )}
                  </React.Fragment>
                )
              })}
            </tbody>
          </table>
        )}
      </div>

      {showModal && (
        <div
          className="fixed inset-0 z-50 flex items-center justify-center bg-black/40"
          onClick={(e) => {
            if (e.target === e.currentTarget) setShowModal(false)
          }}
        >
          <div className="bg-white rounded-2xl shadow-2xl w-full max-w-2xl mx-4 p-6">
            <div className="flex items-center justify-between mb-5">
              <h2 className="text-base font-semibold text-gray-800">{t('tenants.members.modal.title', 'Convidar nou membre (multi-tenant)')}</h2>
              <button
                onClick={() => setShowModal(false)}
                className="text-gray-400 hover:text-gray-600 text-xl leading-none"
                aria-label="Tancar"
              >
                ✕
              </button>
            </div>

            <form onSubmit={handleInviteSubmit} className="space-y-4">
              {inviteError && (
                <div className="rounded-lg bg-red-50 border border-red-200 px-3 py-2 text-sm text-red-700">
                  {inviteError}
                </div>
              )}

              <div className="space-y-1.5">
                  <label className="block text-sm font-medium text-gray-700">
                  {t('tenants.members.modal.email_label', 'Adre\u00e7a de correu')} <span className="text-red-500">*</span>
                </label>
                <input
                  type="email"
                  value={inviteEmail}
                  onChange={(e) => setInviteEmail(e.target.value)}
                  placeholder="nom@empresa.cat"
                  disabled={invitePending}
                  autoFocus
                  className="w-full text-sm rounded-lg border border-gray-200 px-3 py-2 focus:outline-none focus:ring-2 focus:ring-indigo-400 disabled:opacity-50"
                />
              </div>

              <div className="space-y-2">
                <div className="flex items-center justify-between">
                  <label className="block text-sm font-medium text-gray-700">{t('tenants.members.modal.assignments_label', 'Assignacions de tenant')}</label>
                  <button
                    type="button"
                    onClick={addAssignment}
                    className="text-xs px-2.5 py-1 rounded-md border border-gray-200 text-gray-600 hover:bg-gray-50"
                  >
                    + {t('tenants.members.modal.add_tenant_btn', 'Afegir tenant')}
                  </button>
                </div>

                <div className="space-y-2">
                  {inviteAssignments.map((assignment, index) => (
                    <div key={index} className="grid grid-cols-12 gap-2 items-center">
                      <select
                        value={assignment.tenantId}
                        onChange={(e) => updateAssignment(index, { tenantId: e.target.value })}
                        disabled={invitePending}
                        className="col-span-7 text-sm rounded-lg border border-gray-200 px-3 py-2 focus:outline-none focus:ring-2 focus:ring-indigo-400 bg-white"
                      >
                        {inviteTenants.map((tenantOption) => (
                          <option key={tenantOption.tenantId} value={tenantOption.tenantId}>
                            {tenantOption.name}
                          </option>
                        ))}
                      </select>

                      <select
                        value={assignment.role}
                        onChange={(e) => updateAssignment(index, { role: e.target.value })}
                        disabled={invitePending}
                        className="col-span-4 text-sm rounded-lg border border-gray-200 px-3 py-2 focus:outline-none focus:ring-2 focus:ring-indigo-400 bg-white"
                      >
                        {ROLE_OPTIONS.map((r) => (
                          <option key={r.value} value={r.value}>{r.label}</option>
                        ))}
                      </select>

                      <button
                        type="button"
                        onClick={() => removeAssignment(index)}
                        disabled={invitePending || inviteAssignments.length === 1}
                        className="col-span-1 text-red-600 hover:bg-red-50 rounded-md h-9 disabled:opacity-40"
                        title="Eliminar assignació"
                      >
                        ✕
                      </button>
                    </div>
                  ))}
                </div>
              </div>

              <div className="flex gap-3 pt-2">
                <button
                  type="submit"
                  disabled={invitePending || !inviteEmail.trim()}
                  className="flex-1 py-2 text-sm font-medium rounded-lg bg-indigo-600 text-white hover:bg-indigo-700 transition disabled:opacity-50 disabled:cursor-not-allowed"
                >
                  {invitePending ? t('tenants.members.modal.submitting', 'Enviant invitació…') : t('tenants.members.modal.submit', 'Enviar invitació')}
                </button>
                <button
                  type="button"
                  onClick={() => setShowModal(false)}
                  disabled={invitePending}
                  className="px-4 py-2 text-sm font-medium rounded-lg text-gray-600 hover:text-gray-900 transition disabled:opacity-50"
                >
                  {t('tenants.members.modal.cancel', 'Cancel·lar')}
                </button>
              </div>
            </form>
          </div>
        </div>
      )}

      {confirmDeactivate && (
        <div
          className="fixed inset-0 z-50 flex items-center justify-center bg-black/40"
          onClick={(e) => {
            if (e.target === e.currentTarget) setConfirmDeactivate(null)
          }}
        >
          <div className="bg-white rounded-2xl shadow-2xl w-full max-w-sm mx-4 p-6">
            <div className="flex items-start gap-3 mb-4">
              <span className="flex-shrink-0 flex items-center justify-center w-10 h-10 rounded-full bg-red-50 text-red-600 text-lg">
                ⚠
              </span>
              <div>
                <h2 className="text-base font-semibold text-gray-800">{t('tenants.members.deactivate_confirm.title', 'Desactivar membre')}</h2>
                <p className="mt-1 text-sm text-gray-500">
                  {t('tenants.members.deactivate_confirm.message', 'Vols revocar l\'accés de')}{' '}
                  <span className="font-medium text-gray-700">{confirmDeactivate.displayName}</span>{' '}
                  {t('tenants.members.deactivate_confirm.message2', 'a aquest tenant? Es desactivaran totes les seves assignacions (global + sites).')}
                </p>
              </div>
            </div>
            <div className="flex gap-3 justify-end">
              <button
                onClick={() => setConfirmDeactivate(null)}
                className="px-4 py-2 text-sm font-medium rounded-lg text-gray-600 hover:text-gray-900 hover:bg-gray-100 transition"
              >
                {t('tenants.members.deactivate_confirm.cancel', 'Cancel\u00b7lar')}
              </button>
              <button
                onClick={doDeactivate}
                className="px-4 py-2 text-sm font-medium rounded-lg bg-red-600 text-white hover:bg-red-700 transition"
              >
                {t('tenants.members.deactivate_confirm.confirm', 'S\u00ed, desactivar')}
              </button>
            </div>
          </div>
        </div>
      )}

      {detailMember && (
        <div
          className="fixed inset-0 z-50 flex items-center justify-center bg-black/40"
          onClick={(e) => {
            if (e.target === e.currentTarget) closeDetail()
          }}
        >
          <div className="bg-white rounded-2xl shadow-2xl w-full max-w-lg mx-4 overflow-hidden">
            <div className="flex items-center justify-between px-6 py-4 border-b border-gray-100">
              <h2 className="text-base font-semibold text-gray-800">{t('tenants.members.detail.title', 'Detall del membre')}</h2>
              <button
                onClick={closeDetail}
                className="text-gray-400 hover:text-gray-600 text-xl leading-none"
                aria-label="Tancar"
              >
                ✕
              </button>
            </div>

            <div className="px-6 py-5 space-y-5 max-h-[70vh] overflow-y-auto">
              <div className="flex items-center gap-4">
                <div className="flex-shrink-0 w-12 h-12 rounded-full bg-indigo-100 text-indigo-700 flex items-center justify-center text-lg font-bold uppercase select-none">
                  {(detailMember.fullName ?? detailMember.email).charAt(0)}
                </div>
                <div>
                  <p className="font-semibold text-gray-900">
                    {detailMember.fullName ?? <span className="text-gray-400 italic font-normal text-sm">{t('tenants.members.table.no_name', 'Sense nom')}</span>}
                  </p>
                  <p className="text-sm text-gray-500">{detailMember.email}</p>
                </div>
              </div>

              <Section title={t('tenants.members.detail.section_membership', 'Membres')}>
                <Row label={t('tenants.members.detail.scope_label', 'Scope')} value={detailMember.scope === 'global' ? t('tenants.members.scope.global', 'Global') : `Site: ${detailMember.siteName ?? t('tenants.members.scope.no_name', 'Sense nom')}`} />
                <Row label={t('tenants.members.detail.role_label', 'Rol')} value={roleLabel(detailMember.role)} />
                <Row label={t('tenants.members.detail.status_label', 'Estat')} value={!detailMember.isActive ? t('tenants.members.status.inactive', 'Inactiu') : detailMember.isPending ? t('tenants.members.status.pending_short', "Pendent d'activaci\u00f3") : t('tenants.members.status.active_short', 'Actiu')} />
                <Row label={t('tenants.members.detail.added_label', 'Afegit el')} value={fmtDate(detailMember.joinedAt)} />
              </Section>

              <Section title={t('tenants.members.detail.section_access', "Historial d'accés (registrat per l'app)")}>
                <Row
                  label={t('tenants.members.detail.first_access', 'Primer accés')}
                  value={detailMember.firstLoginAt ? fmtDateTime(detailMember.firstLoginAt) : '\u2014'}
                  muted={!detailMember.firstLoginAt}
                />
                <Row
                  label={t('tenants.members.detail.last_access', '\u00daltim accés')}
                  value={detailMember.lastLoginAt ? fmtDateTime(detailMember.lastLoginAt) : '—'}
                  muted={!detailMember.lastLoginAt}
                />
              </Section>

              <Section title={t('tenants.members.detail.section_auth', 'Compte Supabase Auth')}>
                {detailError ? (
                  <p className="text-xs text-red-600">{detailError}</p>
                ) : detailPending || !detailData ? (
                  <div className="flex items-center gap-2 text-xs text-gray-400 py-1">
                    <svg className="animate-spin w-3.5 h-3.5" viewBox="0 0 24 24" fill="none">
                      <circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4"/>
                      <path className="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8v8H4z"/>
                    </svg>
                    {t('tenants.members.detail.loading', 'Carregant…')}
                  </div>
                ) : (
                  <>
                    <Row label={t('tenants.members.detail.account_created', 'Compte creat')} value={detailData.authCreatedAt ? fmtDateTime(detailData.authCreatedAt) : '\u2014'} />
                    <Row label={t('tenants.members.detail.email_confirmed', 'Email confirmat')} value={detailData.emailConfirmedAt ? fmtDateTime(detailData.emailConfirmedAt) : t('tenants.members.detail.not_confirmed', 'No confirmat')} muted={!detailData.emailConfirmedAt} />
                    <Row label={t('tenants.members.detail.providers', 'Prove\u00efdors')} value={detailData.providers.length ? detailData.providers.join(', ') : '\u2014'} />
                    {detailData.phone && <Row label={t('tenants.members.detail.phone', 'Tel\u00e8fon')} value={detailData.phone} />}
                    {detailData.bannedUntil && <Row label={t('tenants.members.detail.banned_until', 'Bloquejat fins')} value={fmtDateTime(detailData.bannedUntil)} danger />}
                  </>
                )}
              </Section>
            </div>

            <div className="px-6 py-4 border-t border-gray-100 flex items-center justify-between gap-3">
              <div>
                {showSuspendConfirm ? (
                  <div className="flex items-center gap-2 flex-wrap">
                    <span className="text-xs text-red-600">{t('tenants.members.detail.suspend_confirm', 'Segur? Afectarà tots els tenants.')}</span>
                    <button
                      onClick={doSuspend}
                      disabled={suspendPending}
                      className="px-3 py-1.5 text-xs font-medium rounded-lg bg-red-600 text-white hover:bg-red-700 disabled:opacity-50 transition"
                    >
                      {suspendPending ? t('tenants.members.actions.suspending', 'Suspenent…') : t('tenants.members.actions.confirm', 'Confirmar')}
                    </button>
                    <button
                      onClick={() => setShowSuspendConfirm(false)}
                      disabled={suspendPending}
                      className="px-3 py-1.5 text-xs font-medium rounded-lg text-gray-600 hover:bg-gray-100 transition"
                    >
                      {t('tenants.members.modal.cancel', 'Cancel·lar')}
                    </button>
                  </div>
                ) : (
                  detailMember?.isActive && (
                    <button
                      onClick={() => setShowSuspendConfirm(true)}
                      className="px-3 py-1.5 text-xs font-medium rounded-lg text-red-600 hover:bg-red-50 transition"
                    >
                      {t('tenants.members.actions.suspend', 'Suspendre del sistema\u2026')}
                    </button>
                  )
                )}
              </div>
              <button
                onClick={closeDetail}
                className="px-4 py-2 text-sm font-medium rounded-lg text-gray-600 hover:text-gray-900 hover:bg-gray-100 transition"
              >
                {t('tenants.members.detail.close', 'Tancar')}
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  )
}

function HealthChip({
  label,
  value,
  variant,
}: {
  label: string
  value: string
  variant: 'neutral' | 'success' | 'danger'
}) {
  const styles: Record<string, string> = {
    neutral: 'bg-gray-50 text-gray-700',
    success: 'bg-green-50 text-green-700',
    danger: 'bg-red-50  text-red-700',
  }
  return (
    <div className={`flex items-center gap-2 px-3 py-2 rounded-lg ${styles[variant]}`}>
      <span className="text-xs text-gray-500">{label}:</span>
      <span className="font-semibold text-sm">{value}</span>
    </div>
  )
}

function Section({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <div>
      <h3 className="text-xs font-semibold text-gray-400 uppercase tracking-wide mb-2">{title}</h3>
      <div className="bg-gray-50 rounded-xl divide-y divide-gray-100">{children}</div>
    </div>
  )
}

function Row({
  label,
  value,
  muted,
  danger,
}: {
  label: string
  value: string
  muted?: boolean
  danger?: boolean
}) {
  return (
    <div className="flex items-start justify-between px-4 py-2.5 gap-4">
      <span className="text-xs text-gray-500 shrink-0">{label}</span>
      <span className={`text-xs text-right font-medium ${danger ? 'text-red-600' : muted ? 'text-gray-400 italic font-normal' : 'text-gray-800'}`}>
        {value}
      </span>
    </div>
  )
}

function fmtDate(iso: string): string {
  return new Date(iso).toLocaleDateString('ca-ES')
}

function fmtDateTime(iso: string): string {
  return new Date(iso).toLocaleString('ca-ES', {
    day: '2-digit', month: '2-digit', year: 'numeric',
    hour: '2-digit', minute: '2-digit',
  })
}
