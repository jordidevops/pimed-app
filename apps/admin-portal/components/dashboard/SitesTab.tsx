'use client'

import { useState, useTransition } from 'react'
import { useTranslation } from 'react-i18next'
import type { SiteRow } from '@/app/admin/actions/sites'
import {
  createSiteForTenant,
  updateSite,
  toggleSiteActive,
} from '@/app/admin/actions/sites'

interface Props {
  tenantId:  string
  maxSites:  number
  sites:     SiteRow[]
}

// ---------------------------------------------------------------------------
// SitesTab — client component rendered inside the tenant detail page.
// El superadmin pot crear sites sense límit de quota (bypass via service_role).
// ---------------------------------------------------------------------------
export function SitesTab({ tenantId, maxSites, sites: initialSites }: Props) {
  const { t } = useTranslation('tenants')
  const [sites, setSites] = useState<SiteRow[]>(initialSites)

  // Create modal
  const [showCreate,    setShowCreate]    = useState(false)
  const [createName,    setCreateName]    = useState('')
  const [createAddress, setCreateAddress] = useState('')
  const [createError,   setCreateError]   = useState<string | null>(null)
  const [createPending, startCreate]      = useTransition()

  // Edit inline state: siteId → { name, address }
  const [editingId,      setEditingId]      = useState<string | null>(null)
  const [editName,       setEditName]       = useState('')
  const [editAddress,    setEditAddress]    = useState('')
  const [editError,      setEditError]      = useState<string | null>(null)
  const [editPending,    startEdit]         = useTransition()

  // Toggle active
  const [togglingId,    setTogglingId]     = useState<string | null>(null)
  const [togglePending, startToggle]       = useTransition()

  // Feedback
  const [successMsg,    setSuccessMsg]     = useState<string | null>(null)

  function flash(msg: string) {
    setSuccessMsg(msg)
    setTimeout(() => setSuccessMsg(null), 4000)
  }

  // ── Create ──────────────────────────────────────────────────────────────
  function openCreate() {
    setCreateName('')
    setCreateAddress('')
    setCreateError(null)
    setShowCreate(true)
  }

  function handleCreateSubmit(e: React.FormEvent) {
    e.preventDefault()
    setCreateError(null)
    if (!createName.trim()) {
      setCreateError(t('tenants.sites.modal.name_required', 'El nom del local és obligatori.'))
      return
    }
    startCreate(async () => {
      try {
        await createSiteForTenant(tenantId, createName.trim(), createAddress.trim() || null)
        setShowCreate(false)
        flash(`${t('tenants.sites.flash.created_prefix', 'Local')} "${createName.trim()}" ${t('tenants.sites.flash.created_suffix', 'creat correctament.')}`)
        // La revalidatePath de l'action s'encarrega de refrescar les dades
      } catch (err) {
        setCreateError(err instanceof Error ? err.message : t('tenants.sites.flash.create_error', 'Error en crear el local.'))
      }
    })
  }

  // ── Edit inline ─────────────────────────────────────────────────────────
  function startEditing(site: SiteRow) {
    setEditingId(site.id)
    setEditName(site.name)
    setEditAddress(site.address ?? '')
    setEditError(null)
  }

  function cancelEditing() {
    setEditingId(null)
    setEditError(null)
  }

  function handleEditSubmit(siteId: string) {
    setEditError(null)
    if (!editName.trim()) {
      setEditError(t('tenants.sites.modal.name_required', 'El nom del local és obligatori.'))
      return
    }
    startEdit(async () => {
      try {
        await updateSite(siteId, tenantId, {
          name:    editName.trim(),
          address: editAddress.trim() || null,
        })
        setSites((prev) =>
          prev.map((s) =>
            s.id === siteId
              ? { ...s, name: editName.trim(), address: editAddress.trim() || null }
              : s,
          ),
        )
        setEditingId(null)
        flash(t('tenants.sites.flash.updated', 'Local actualitzat.'))
      } catch (err) {
        setEditError(err instanceof Error ? err.message : t('tenants.sites.flash.update_error', 'Error en actualitzar el local.'))
      }
    })
  }

  // ── Toggle active ────────────────────────────────────────────────────────
  function handleToggle(site: SiteRow) {
    setTogglingId(site.id)
    startToggle(async () => {
      try {
        await toggleSiteActive(site.id, tenantId, !site.is_active)
        setSites((prev) =>
          prev.map((s) => (s.id === site.id ? { ...s, is_active: !site.is_active } : s)),
        )
        flash(`${t('tenants.sites.flash.toggled_prefix', 'Local')} "${site.name}" ${!site.is_active ? t('tenants.sites.flash.activated', 'activat') : t('tenants.sites.flash.deactivated', 'desactivat')}.`)
      } catch (err) {
        flash(err instanceof Error ? err.message : t('tenants.sites.flash.toggle_error', "Error en canviar l'estat del local."))
      } finally {
        setTogglingId(null)
      }
    })
  }

  const activeSiteCount = sites.filter((s) => s.is_active).length
  const hasPlanLimit = maxSites > 0
  const isAtLimit = hasPlanLimit && activeSiteCount >= maxSites

  return (
    <div className="space-y-4">
      {/* Header bar */}
      <div className="flex items-center justify-between">
        <div className="flex items-center gap-3">
          <div className="flex items-center gap-2 flex-wrap">
            <span className="text-sm text-gray-500">
              {t('tenants.sites.header.occupied', 'Locals ocupats')}: {hasPlanLimit ? `${activeSiteCount} / ${maxSites}` : String(activeSiteCount)}
            </span>
            <span className="text-xs px-2 py-0.5 rounded-full bg-gray-100 text-gray-600">
              {hasPlanLimit ? t('tenants.sites.header.plan_limit', 'Límit del pla') : t('tenants.sites.header.no_limit', 'Sense límit definit')}
            </span>
            {isAtLimit && (
              <span className="text-xs px-2 py-0.5 rounded-full bg-amber-50 text-amber-700 border border-amber-200">
                {t('tenants.sites.header.limit_reached', 'Límit assolit')}
              </span>
            )}
          </div>
        </div>
        <button
          onClick={openCreate}
          disabled={isAtLimit}
          title={isAtLimit ? t('tenants.sites.actions.create_disabled_title', 'Aquest tenant ha arribat al límit de locals del pla.') : undefined}
          className="text-sm px-4 py-2 rounded-lg bg-indigo-600 text-white font-medium hover:bg-indigo-700 transition disabled:opacity-50 disabled:cursor-not-allowed"
        >
          {t('tenants.sites.actions.create', '+ Nou local')}
        </button>
      </div>

      {/* Feedback banner */}
      {successMsg && (
        <div className="rounded-lg bg-green-50 border border-green-200 px-4 py-3 text-sm text-green-700">
          {successMsg}
        </div>
      )}

      {/* Sites list */}
      {sites.length === 0 ? (
        <div className="rounded-xl border-2 border-dashed border-gray-200 p-10 text-center">
          <p className="text-sm text-gray-400">
            {t('tenants.sites.table.empty', "Aquest tenant no té cap local. Crea'n un per començar.")}
          </p>
        </div>
      ) : (
        <div className="rounded-2xl border border-gray-100 overflow-hidden shadow-sm">
          <table className="w-full text-sm">
            <thead className="bg-gray-50 text-gray-500 text-xs uppercase tracking-wide">
              <tr>
                <th className="px-4 py-3 text-left font-medium">{t('tenants.sites.table.col_name', 'Nom')}</th>
                <th className="px-4 py-3 text-left font-medium">{t('tenants.sites.table.col_address', 'Adreça')}</th>
                <th className="px-4 py-3 text-left font-medium">{t('tenants.sites.table.col_status', 'Estat')}</th>
                <th className="px-4 py-3 text-right font-medium">{t('tenants.sites.table.col_actions', 'Accions')}</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-gray-100 bg-white">
              {sites.map((site) => (
                <tr key={site.id} className={!site.is_active ? 'opacity-50' : ''}>
                  {editingId === site.id ? (
                    /* ── Inline edit row ── */
                    <>
                      <td className="px-4 py-2">
                        <input
                          autoFocus
                          type="text"
                          value={editName}
                          onChange={(e) => setEditName(e.target.value)}
                          className="w-full text-sm rounded border border-gray-200 px-2 py-1 focus:outline-none focus:ring-2 focus:ring-indigo-400"
                          disabled={editPending}
                        />
                        {editError && (
                          <p className="text-xs text-red-500 mt-1">{editError}</p>
                        )}
                      </td>
                      <td className="px-4 py-2">
                        <input
                          type="text"
                          value={editAddress}
                          onChange={(e) => setEditAddress(e.target.value)}
                          placeholder="Adreça (opcional)"
                          className="w-full text-sm rounded border border-gray-200 px-2 py-1 focus:outline-none focus:ring-2 focus:ring-indigo-400"
                          disabled={editPending}
                        />
                      </td>
                      <td />
                      <td className="px-4 py-2 text-right">
                        <div className="flex items-center justify-end gap-2">
                          <button
                            onClick={() => handleEditSubmit(site.id)}
                            disabled={editPending}
                            className="text-xs px-3 py-1.5 rounded-lg bg-indigo-600 text-white font-medium hover:bg-indigo-700 disabled:opacity-50 transition"
                          >
                          {editPending ? t('tenants.sites.actions.saving', 'Desant…') : t('tenants.sites.actions.save', 'Desar')}
                          </button>
                          <button
                            onClick={cancelEditing}
                            disabled={editPending}
                            className="text-xs px-3 py-1.5 rounded-lg border border-gray-200 text-gray-600 hover:bg-gray-50 transition"
                          >
                            {t('tenants.sites.actions.cancel', 'Cancel·lar')}
                          </button>
                        </div>
                      </td>
                    </>
                  ) : (
                    /* ── Normal row ── */
                    <>
                      <td className="px-4 py-3 font-medium text-gray-800">{site.name}</td>
                      <td className="px-4 py-3 text-gray-500">{site.address ?? '—'}</td>
                      <td className="px-4 py-3">
                        <span
                          className={`inline-flex items-center px-2 py-0.5 rounded-full text-xs font-semibold ${
                            site.is_active
                              ? 'bg-green-50 text-green-700'
                              : 'bg-gray-100 text-gray-500'
                          }`}
                        >
                          {site.is_active ? t('tenants.sites.status.active', 'Actiu') : t('tenants.sites.status.inactive', 'Inactiu')}
                        </span>
                      </td>
                      <td className="px-4 py-3 text-right">
                        <div className="flex items-center justify-end gap-2">
                          <button
                            onClick={() => startEditing(site)}
                            className="text-xs px-3 py-1.5 rounded-lg border border-gray-200 text-gray-600 hover:bg-gray-50 transition"
                          >
                            {t('tenants.sites.actions.edit', 'Editar')}
                          </button>
                          <button
                            onClick={() => handleToggle(site)}
                            disabled={togglePending && togglingId === site.id}
                            className={`text-xs px-3 py-1.5 rounded-lg border font-medium transition disabled:opacity-50 ${
                              site.is_active
                                ? 'border-red-200 text-red-600 hover:bg-red-50'
                                : 'border-green-200 text-green-700 hover:bg-green-50'
                            }`}
                          >
                            {togglePending && togglingId === site.id
                              ? '…'
                              : site.is_active
                              ? t('tenants.sites.actions.deactivate', 'Desactivar')
                              : t('tenants.sites.actions.activate', 'Activar')}
                          </button>
                        </div>
                      </td>
                    </>
                  )}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      {/* ── Create modal ────────────────────────────────────────────────── */}
      {showCreate && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40">
          <div className="bg-white rounded-2xl shadow-xl w-full max-w-md p-6 space-y-5">
            <h3 className="text-lg font-semibold text-gray-900">{t('tenants.sites.modal.title', 'Nou local')}</h3>

            <form onSubmit={handleCreateSubmit} className="space-y-4">
              {createError && (
                <div className="rounded-lg bg-red-50 border border-red-200 px-4 py-3 text-sm text-red-700">
                  {createError}
                </div>
              )}

              <div className="space-y-1.5">
                <label className="block text-sm font-medium text-gray-700">
                  {t('tenants.sites.modal.name_label', 'Nom')} <span className="text-red-500">*</span>
                </label>
                <input
                  autoFocus
                  type="text"
                  value={createName}
                  onChange={(e) => setCreateName(e.target.value)}
                  placeholder="Ex: Acme Eixample"
                  disabled={createPending}
                  className="w-full text-sm rounded-lg border border-gray-200 px-3 py-2 focus:outline-none focus:ring-2 focus:ring-indigo-400 disabled:opacity-50"
                />
              </div>

              <div className="space-y-1.5">
                <label className="block text-sm font-medium text-gray-700">
                  {t('tenants.sites.modal.address_label', 'Adreça')} <span className="text-gray-400 text-xs">({t('tenants.sites.modal.optional', 'opcional')})</span>
                </label>
                <input
                  type="text"
                  value={createAddress}
                  onChange={(e) => setCreateAddress(e.target.value)}
                  placeholder="Ex: Carrer Major, 1, 08001 Barcelona"
                  disabled={createPending}
                  className="w-full text-sm rounded-lg border border-gray-200 px-3 py-2 focus:outline-none focus:ring-2 focus:ring-indigo-400 disabled:opacity-50"
                />
              </div>

              <div className="flex justify-end gap-3 pt-2">
                <button
                  type="button"
                  onClick={() => setShowCreate(false)}
                  disabled={createPending}
                  className="text-sm px-4 py-2 rounded-lg border border-gray-200 text-gray-600 hover:bg-gray-50 transition"
                >
                  {t('tenants.sites.actions.cancel', 'Cancel·lar')}
                </button>
                <button
                  type="submit"
                  disabled={createPending}
                  className="text-sm px-4 py-2 rounded-lg bg-indigo-600 text-white font-medium hover:bg-indigo-700 disabled:opacity-50 transition"
                >
                  {createPending ? t('tenants.sites.modal.creating', 'Creant…') : t('tenants.sites.modal.submit', 'Crear local')}
                </button>
              </div>
            </form>
          </div>
        </div>
      )}
    </div>
  )
}
