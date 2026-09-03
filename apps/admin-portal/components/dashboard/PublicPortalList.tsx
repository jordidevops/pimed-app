'use client'

import { useState, useTransition } from 'react'
import { ExternalLink, Globe, FileText, Link2, Users, ChevronRight, CheckCircle2, Clock, AlertCircle, Shield } from 'lucide-react'
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { togglePublicPortal } from '@/app/admin/actions/tenants'

export interface DomainRow {
  id: string
  domain: string
  status: string
}

export interface TenantPortalRow {
  id: string
  name: string
  slug: string
  is_active: boolean
  public_portal_enabled: boolean
  site: {
    id: string
    status: string
    seo_title: string | null
    domains: DomainRow[]
    _count: {
      public_pages: number
      public_domains: number
      public_leads: number
    }
  } | null
}

interface Props {
  tenants: TenantPortalRow[]
  portalBaseUrl: string
}

export function PublicPortalList({ tenants, portalBaseUrl }: Props) {
  const [selected, setSelected] = useState<TenantPortalRow | null>(null)
  const [isPending, startTransition] = useTransition()

  function handleToggle(tenant: TenantPortalRow) {
    startTransition(async () => {
      await togglePublicPortal(tenant.id, !tenant.public_portal_enabled)
      if (selected?.id === tenant.id) {
        setSelected((prev) =>
          prev ? { ...prev, public_portal_enabled: !prev.public_portal_enabled } : null,
        )
      }
    })
  }

  const portalUrl = (slug: string) => `${portalBaseUrl}/${slug}`

  return (
    <>
      <div className="rounded-xl border border-gray-200 bg-white overflow-hidden shadow-sm">
        <table className="w-full text-sm">
          <thead>
            <tr className="border-b bg-gray-50">
              <th className="text-left px-4 py-3 font-medium text-gray-500">Organització</th>
              <th className="text-left px-4 py-3 font-medium text-gray-500">Slug</th>
              <th className="text-left px-4 py-3 font-medium text-gray-500">Estat tenant</th>
              <th className="text-left px-4 py-3 font-medium text-gray-500">Portal</th>
              <th className="text-left px-4 py-3 font-medium text-gray-500">Site</th>
              <th className="px-4 py-3" />
            </tr>
          </thead>
          <tbody className="divide-y divide-gray-100">
            {tenants.length === 0 && (
              <tr>
                <td colSpan={6} className="px-4 py-8 text-center text-sm text-gray-400 italic">
                  Cap tenant trobat.
                </td>
              </tr>
            )}
            {tenants.map((tenant) => (
              <tr
                key={tenant.id}
                className="hover:bg-gray-50 transition cursor-pointer"
                onClick={() => setSelected(tenant)}
              >
                <td className="px-4 py-3 font-medium text-gray-900">{tenant.name}</td>
                <td className="px-4 py-3 font-mono text-xs text-gray-500">{tenant.slug}</td>
                <td className="px-4 py-3">
                  <span
                    className={`px-2 py-0.5 text-xs font-medium rounded-full ${
                      tenant.is_active ? 'bg-green-50 text-green-700' : 'bg-gray-100 text-gray-500'
                    }`}
                  >
                    {tenant.is_active ? 'Actiu' : 'Inactiu'}
                  </span>
                </td>
                <td className="px-4 py-3">
                  <span
                    className={`px-2 py-0.5 text-xs font-medium rounded-full ${
                      tenant.public_portal_enabled
                        ? 'bg-blue-50 text-blue-700'
                        : 'bg-gray-100 text-gray-500'
                    }`}
                  >
                    {tenant.public_portal_enabled ? 'Activat' : 'Desactivat'}
                  </span>
                </td>
                <td className="px-4 py-3">
                  {tenant.site ? (
                    <span
                      className={`px-2 py-0.5 text-xs font-medium rounded-full ${
                        tenant.site.status === 'published'
                          ? 'bg-green-50 text-green-700'
                          : tenant.site.status === 'suspended'
                            ? 'bg-red-50 text-red-600'
                            : 'bg-amber-50 text-amber-700'
                      }`}
                    >
                      {tenant.site.status === 'published'
                        ? 'Publicat'
                        : tenant.site.status === 'suspended'
                          ? 'Suspès'
                          : 'Esborrany'}
                    </span>
                  ) : (
                    <span className="text-xs text-gray-400 italic">Sense portal</span>
                  )}
                </td>
                <td className="px-4 py-3 text-right">
                  <ChevronRight className="h-4 w-4 text-gray-400 inline" />
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      {/* Modal de detalls */}
      <Dialog open={!!selected} onOpenChange={(open) => !open && setSelected(null)}>
        <DialogContent className="max-w-lg p-6">
          {selected && (
            <>
              <DialogHeader>
                <DialogTitle className="flex items-center gap-2 text-base">
                  <Globe className="h-5 w-5 text-indigo-500 shrink-0" />
                  {selected.name}
                </DialogTitle>
              </DialogHeader>

              <div className="mt-4 space-y-5">
                {/* URL del portal */}
                <div>
                  <p className="text-xs font-medium text-gray-500 mb-1">URL del portal</p>
                  <div className="flex items-center gap-2 bg-gray-50 rounded-lg px-3 py-2">
                    <span className="font-mono text-sm text-gray-700 truncate flex-1">
                      {portalUrl(selected.slug)}
                    </span>
                    <a
                      href={portalUrl(selected.slug)}
                      target="_blank"
                      rel="noopener noreferrer"
                      onClick={(e) => e.stopPropagation()}
                      className="text-indigo-600 hover:text-indigo-800 shrink-0"
                    >
                      <ExternalLink className="h-4 w-4" />
                    </a>
                  </div>
                </div>

                {/* Estadístiques */}
                {selected.site ? (
                  <div className="grid grid-cols-3 gap-3">
                    <div className="rounded-lg border bg-white px-4 py-3 text-center">
                      <FileText className="h-5 w-5 mx-auto mb-1 text-gray-400" />
                      <p className="text-2xl font-bold text-gray-900">
                        {selected.site._count.public_pages}
                      </p>
                      <p className="text-xs text-gray-500">Pàgines</p>
                    </div>
                    <div className="rounded-lg border bg-white px-4 py-3 text-center">
                      <Link2 className="h-5 w-5 mx-auto mb-1 text-gray-400" />
                      <p className="text-2xl font-bold text-gray-900">
                        {selected.site._count.public_domains}
                      </p>
                      <p className="text-xs text-gray-500">Dominis</p>
                    </div>
                    <div className="rounded-lg border bg-white px-4 py-3 text-center">
                      <Users className="h-5 w-5 mx-auto mb-1 text-gray-400" />
                      <p className="text-2xl font-bold text-gray-900">
                        {selected.site._count.public_leads}
                      </p>
                      <p className="text-xs text-gray-500">Leads</p>
                    </div>
                  </div>
                ) : (
                  <p className="text-sm text-gray-400 italic text-center py-4">
                    Aquest tenant no ha creat cap portal encara.
                  </p>
                )}

                {/* Dominis propis */}
                {selected.site && selected.site.domains.length > 0 && (
                  <div>
                    <p className="text-xs font-medium text-gray-500 mb-2">Dominis propis</p>
                    <div className="space-y-1.5">
                      {selected.site.domains.map((d) => {
                        const cfg = {
                          ssl_active:   { icon: <CheckCircle2 className="h-3.5 w-3.5 text-green-500" />, label: 'SSL actiu',          cls: 'bg-green-50 text-green-700' },
                          dns_verified: { icon: <Shield className="h-3.5 w-3.5 text-blue-500" />,        label: 'DNS verificat',       cls: 'bg-blue-50 text-blue-700' },
                          pending:      { icon: <Clock className="h-3.5 w-3.5 text-amber-500" />,        label: 'Pendent verificació', cls: 'bg-amber-50 text-amber-700' },
                          failed:       { icon: <AlertCircle className="h-3.5 w-3.5 text-red-500" />,    label: 'Error',               cls: 'bg-red-50 text-red-600' },
                        }[d.status] ?? { icon: <Clock className="h-3.5 w-3.5 text-gray-400" />, label: d.status, cls: 'bg-gray-50 text-gray-500' }

                        return (
                          <div key={d.id} className="flex items-center justify-between rounded-lg border bg-gray-50 px-3 py-2">
                            <span className="font-mono text-xs text-gray-700 truncate">{d.domain}</span>
                            <span className={`flex items-center gap-1 px-2 py-0.5 text-xs font-medium rounded-full shrink-0 ml-2 ${cfg.cls}`}>
                              {cfg.icon}
                              {cfg.label}
                            </span>
                          </div>
                        )
                      })}
                    </div>
                  </div>
                )}

                {/* Estat */}
                <div className="flex items-center justify-between rounded-lg border px-4 py-3">
                  <div>
                    <p className="text-sm font-medium text-gray-700">Mòdul portal públic</p>
                    <p className="text-xs text-gray-400 mt-0.5">
                      {selected.public_portal_enabled
                        ? "El tenant pot gestionar el seu portal públic."
                        : "El tenant no té accés al mòdul de portal públic."}
                    </p>
                  </div>
                  <button
                    onClick={() => handleToggle(selected)}
                    disabled={isPending}
                    className={`px-4 py-1.5 rounded-lg text-sm font-medium transition disabled:opacity-50 ${
                      selected.public_portal_enabled
                        ? 'bg-red-50 text-red-600 hover:bg-red-100'
                        : 'bg-indigo-50 text-indigo-700 hover:bg-indigo-100'
                    }`}
                  >
                    {selected.public_portal_enabled ? 'Desactivar' : 'Activar'}
                  </button>
                </div>
              </div>
            </>
          )}
        </DialogContent>
      </Dialog>
    </>
  )
}
