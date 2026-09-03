import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { MapPin, Pencil, Trash2 } from 'lucide-react'
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { useToast } from '@/hooks/use-toast'
import { AddressLocationFields } from '@/components/maps/AddressLocationFields'
import {
  CoordinatePicker,
  type CoordinatePoint,
  type CoordinateSelectionContext,
} from '@/components/maps/CoordinatePicker'
import {
  parseGeoCoordinates,
  buildGeoCoordinates,
  formatAddressLine,
  proposeLocationNameFromAddress,
  type StructuredAddress,
} from '@/lib/geo/geoCoordinates'
import type { ContactSite } from '../api/contactsService'
import {
  createContactSite,
  updateContactSite,
  deleteContactSite,
  formatContactSiteAddress,
} from '../api/contactsService'

interface ContactSitesListProps {
  sites: ContactSite[]
  loading?: boolean
  contactId: string
  tenantId: string
  onChanged: () => void
}

function contextToStructuredAddress(
  context: CoordinateSelectionContext | null,
  addressInput: string,
  structured: StructuredAddress,
): StructuredAddress {
  const trimmedAddress = addressInput.trim()
  return {
    street: structured.street ?? context?.street ?? null,
    street_number: structured.street_number ?? context?.street_number ?? null,
    city: structured.city ?? context?.city ?? null,
    province: structured.province ?? context?.province ?? null,
    postal_code: structured.postal_code ?? context?.postal_code ?? null,
    country_code: structured.country_code ?? context?.country_code ?? null,
    address: trimmedAddress.length > 0 ? trimmedAddress : (context?.address ?? null),
  }
}

export function ContactSitesList({
  sites,
  loading,
  contactId,
  tenantId,
  onChanged,
}: ContactSitesListProps) {
  const { t } = useTranslation('contacts')
  const { toast } = useToast()
  const [dialogOpen, setDialogOpen] = useState(false)
  const [editingSite, setEditingSite] = useState<ContactSite | null>(null)
  const [saving, setSaving] = useState(false)

  const [name, setName] = useState('')
  const [nameTouched, setNameTouched] = useState(false)
  const [notes, setNotes] = useState('')
  const [addressInput, setAddressInput] = useState('')
  const [structuredAddress, setStructuredAddress] = useState<StructuredAddress>({})
  const [coordinates, setCoordinates] = useState<CoordinatePoint | null>(null)
  const [coordinateContext, setCoordinateContext] = useState<CoordinateSelectionContext | null>(null)
  const [nameError, setNameError] = useState(false)

  useEffect(() => {
    if (!dialogOpen) return
    setNameError(false)
  }, [dialogOpen])

  function resetForm(site: ContactSite | null) {
    setNameTouched(false)
    if (!site) {
      setName('')
      setNotes('')
      setAddressInput('')
      setStructuredAddress({})
      setCoordinates(null)
      setCoordinateContext(null)
      return
    }

    const geo = parseGeoCoordinates(site.geo_coordinates)
    const address: StructuredAddress = geo.point
      ? geo.address
      : {
          street: site.street ?? null,
          street_number: site.street_number ?? null,
          city: site.city ?? null,
          province: site.province ?? null,
          postal_code: site.postal_code ?? null,
          country_code: site.country_code ?? null,
          address: site.address ?? null,
        }

    setName(site.name ?? '')
    setNameTouched(Boolean(site.name?.trim()))
    setNotes(site.notes ?? '')
    setAddressInput(address.address ?? site.address ?? '')
    setStructuredAddress(address)
    setCoordinates(geo.point)
    setCoordinateContext(
      geo.point
        ? {
            ...address,
            address: address.address ?? null,
            provider: geo.provider ?? 'manual',
            source: geo.source ?? 'manual_input',
            providerData: geo.providerData,
          }
        : null,
    )
  }

  function openCreate() {
    setEditingSite(null)
    resetForm(null)
    setDialogOpen(true)
  }

  function openEdit(site: ContactSite) {
    setEditingSite(site)
    resetForm(site)
    setDialogOpen(true)
  }

  function handleCoordinateContextChange(context: CoordinateSelectionContext | null) {
    setCoordinateContext(context)
    if (!context) {
      setStructuredAddress({})
      setAddressInput('')
      if (!nameTouched) setName('')
      return
    }

    const nextStructured: StructuredAddress = {
      street: context.street ?? null,
      street_number: context.street_number ?? null,
      city: context.city ?? null,
      province: context.province ?? null,
      postal_code: context.postal_code ?? null,
      country_code: context.country_code ?? null,
      address: context.address ?? null,
    }
    setStructuredAddress(nextStructured)
    setAddressInput(context.address ?? '')

    if (!nameTouched) {
      const proposed = proposeLocationNameFromAddress(nextStructured)
      setName(proposed)
    }
  }

  function handleAddressFieldsChange(next: StructuredAddress) {
    setStructuredAddress(next)
    setCoordinateContext((prev) => ({
      address: prev?.address ?? next.address ?? null,
      provider: prev?.provider ?? 'manual',
      source: prev?.source ?? 'manual_input',
      providerData: prev?.providerData,
      street: next.street ?? null,
      street_number: next.street_number ?? null,
      city: next.city ?? null,
      province: next.province ?? null,
      postal_code: next.postal_code ?? null,
      country_code: next.country_code ?? null,
    }))
    if (!nameTouched) {
      setName(proposeLocationNameFromAddress(next))
    }
  }

  async function handleSubmit(event: React.FormEvent) {
    event.preventDefault()

    const structured = contextToStructuredAddress(
      coordinateContext,
      addressInput,
      structuredAddress,
    )
    const proposedName =
      name.trim() || proposeLocationNameFromAddress(structured)

    if (!proposedName) {
      setNameError(true)
      return
    }
    setNameError(false)

    const geo_coordinates = coordinates
      ? buildGeoCoordinates(
          coordinates,
          structured,
          coordinateContext
            ? {
                provider: coordinateContext.provider,
                source: coordinateContext.source,
                providerData: coordinateContext.providerData,
              }
            : undefined,
        )
      : null

    setSaving(true)
    try {
      const payload = {
        name: proposedName,
        address: formatAddressLine(structured) || addressInput.trim() || null,
        street: structured.street ?? null,
        street_number: structured.street_number ?? null,
        city: structured.city ?? null,
        province: structured.province ?? null,
        postal_code: structured.postal_code ?? null,
        country_code: structured.country_code ?? null,
        geo_coordinates,
        notes: notes.trim() || null,
      }

      if (editingSite?.id) {
        await updateContactSite(editingSite.id, payload)
        toast({ title: t('detail.sites_updated', 'Adreça actualitzada') })
      } else {
        await createContactSite({
          tenant_id: tenantId,
          contact_id: contactId,
          ...payload,
        })
        toast({ title: t('detail.sites_created', 'Adreça creada') })
      }
      setDialogOpen(false)
      onChanged()
    } catch {
      toast({
        variant: 'destructive',
        title: t('detail.sites_save_failed', 'Error en desar l\'adreça'),
      })
    } finally {
      setSaving(false)
    }
  }

  async function handleDelete(site: ContactSite) {
    if (!site.id) return
    const confirmed = window.confirm(
      t('detail.sites_delete_confirm', 'Eliminar aquesta adreça?'),
    )
    if (!confirmed) return

    try {
      await deleteContactSite(site.id)
      toast({ title: t('detail.sites_deleted', 'Adreça eliminada') })
      onChanged()
    } catch {
      toast({
        variant: 'destructive',
        title: t('detail.sites_delete_failed', 'Error en eliminar l\'adreça'),
      })
    }
  }

  const nameSuggestion = proposeLocationNameFromAddress(structuredAddress)

  if (loading) {
    return (
      <div className="space-y-2">
        {[1, 2].map((i) => (
          <div key={i} className="h-16 rounded-xl bg-accent/40 animate-pulse" />
        ))}
      </div>
    )
  }

  return (
    <>
      <div className="space-y-3">
        {sites.length === 0 ? (
          <p className="text-sm text-muted-foreground">
            {t('detail.sites_empty', 'No hi ha adreces registrades')}
          </p>
        ) : (
          <ul className="space-y-2">
            {sites.map((site) => {
              const addressLine = formatContactSiteAddress(site)
              return (
                <li
                  key={site.id}
                  className="flex items-start gap-3 rounded-xl border border-border bg-background p-3"
                >
                  <MapPin className="h-4 w-4 text-muted-foreground mt-0.5 shrink-0" />
                  <div className="min-w-0 flex-1">
                    {site.name && (
                      <p className="text-sm font-medium text-foreground">{site.name}</p>
                    )}
                    {addressLine && (
                      <p className="text-xs text-muted-foreground mt-0.5">{addressLine}</p>
                    )}
                    {site.notes && (
                      <p className="text-xs text-muted-foreground/70 mt-0.5 italic">{site.notes}</p>
                    )}
                  </div>
                  <div className="flex shrink-0 gap-1">
                    <Button
                      type="button"
                      variant="ghost"
                      size="icon"
                      className="h-8 w-8"
                      onClick={() => openEdit(site)}
                      aria-label={t('detail.sites_edit', 'Editar adreça')}
                    >
                      <Pencil className="h-3.5 w-3.5" />
                    </Button>
                    <Button
                      type="button"
                      variant="ghost"
                      size="icon"
                      className="h-8 w-8 text-destructive hover:text-destructive"
                      onClick={() => handleDelete(site)}
                      aria-label={t('detail.sites_delete', 'Eliminar adreça')}
                    >
                      <Trash2 className="h-3.5 w-3.5" />
                    </Button>
                  </div>
                </li>
              )
            })}
          </ul>
        )}

        <button
          type="button"
          onClick={openCreate}
          className="text-sm text-indigo-600 hover:text-indigo-700 font-medium"
        >
          + {t('detail.sites_add', 'Afegir adreça')}
        </button>
      </div>

      <Dialog open={dialogOpen} onOpenChange={setDialogOpen}>
        <DialogContent className="sm:max-w-4xl flex flex-col max-h-[90vh]">
          <DialogHeader className="shrink-0">
            <DialogTitle>
              {editingSite
                ? t('detail.sites_edit_title', 'Editar adreça')
                : t('detail.sites_add_title', 'Nova adreça')}
            </DialogTitle>
          </DialogHeader>

          <form onSubmit={handleSubmit} className="flex flex-col flex-1 min-h-0">
            <div className="overflow-y-auto flex-1 pt-2 px-1 pb-2">
              <div className="grid gap-4 lg:grid-cols-2 lg:items-start">
                <div className="space-y-3">
                  <div className="space-y-1">
                    <label className="text-sm font-medium" htmlFor="site-name">
                      {t('detail.sites_name', 'Nom')}{' '}
                      <span className="text-muted-foreground text-xs">
                        ({t('common:optional', 'opcional')})
                      </span>
                    </label>
                    <Input
                      id="site-name"
                      value={name}
                      onChange={(event) => {
                        setNameTouched(true)
                        setName(event.target.value)
                      }}
                      placeholder={
                        nameSuggestion ||
                        t(
                          'detail.sites_name_ph',
                          'Ex: Carrer Major, 12 - Girona',
                        )
                      }
                    />
                    <p className="text-[11px] text-muted-foreground">
                      {t(
                        'detail.sites_name_hint',
                        'Si el deixes buit, s\'usarà «Carrer, Número - Ciutat».',
                      )}
                    </p>
                    {nameError && (
                      <p className="text-xs text-destructive">
                        {t(
                          'detail.sites_name_required',
                          'Cal un nom o una adreça amb carrer/ciutat.',
                        )}
                      </p>
                    )}
                  </div>

                  <AddressLocationFields
                    value={structuredAddress}
                    onChange={handleAddressFieldsChange}
                    disabled={saving}
                  />

                  <div className="space-y-1">
                    <label className="text-sm font-medium" htmlFor="site-address">
                      {t('detail.sites_address', 'Adreça completa')}
                    </label>
                    <Input
                      id="site-address"
                      value={addressInput}
                      onChange={(event) => setAddressInput(event.target.value)}
                      placeholder={t(
                        'detail.sites_address_ph',
                        'S\'omple en seleccionar un resultat o el punt al mapa',
                      )}
                    />
                  </div>

                  <div className="space-y-1">
                    <label className="text-sm font-medium" htmlFor="site-notes">
                      {t('detail.sites_notes', 'Notes')}
                    </label>
                    <textarea
                      id="site-notes"
                      rows={2}
                      value={notes}
                      onChange={(event) => setNotes(event.target.value)}
                      className="w-full rounded-md border border-input bg-background px-3 py-2 text-sm resize-none"
                    />
                  </div>
                </div>

                <div className="space-y-2">
                  <p className="text-xs text-muted-foreground">
                    {t(
                      'detail.sites_map_hint',
                      'Cerca o marca al mapa. Cada cerca / «La meva ubicació» reinicia el punt anterior.',
                    )}
                  </p>
                  <CoordinatePicker
                    value={coordinates}
                    onChange={setCoordinates}
                    onContextChange={handleCoordinateContextChange}
                    disabled={saving}
                    showHeader={false}
                    mapClassName="h-72"
                  />
                </div>
              </div>
            </div>

            <div className="shrink-0 flex justify-end gap-2 pt-3 border-t mt-1">
              <Button type="button" variant="outline" onClick={() => setDialogOpen(false)}>
                {t('form.cancel', 'Cancel·lar')}
              </Button>
              <Button type="submit" disabled={saving}>
                {saving ? t('form.saving', 'Desant…') : t('form.save', 'Desar')}
              </Button>
            </div>
          </form>
        </DialogContent>
      </Dialog>
    </>
  )
}
