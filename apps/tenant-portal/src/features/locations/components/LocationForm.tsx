import { useEffect, useState } from 'react'
import { useForm } from 'react-hook-form'
import { zodResolver } from '@hookform/resolvers/zod'
import { useTranslation } from 'react-i18next'
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { useToast } from '@/hooks/use-toast'
import { useTenant } from '@/contexts/TenantContext'
import {
  CoordinatePicker,
  type CoordinatePoint,
  type CoordinateSelectionContext,
} from '@/components/maps/CoordinatePicker'
import { AddressLocationFields } from '@/components/maps/AddressLocationFields'
import {
  parseGeoCoordinates,
  buildGeoCoordinates,
  proposeLocationNameFromAddress,
  type StructuredAddress,
} from '@/lib/geo/geoCoordinates'
import { cn } from '@/lib/utils'
import { locationSchema, LOCATION_TYPES, LOCATION_STATUSES } from '../schemas/locationSchema'
import type { LocationFormValues } from '../schemas/locationSchema'
import { useCreateLocation } from '../api/useCreateLocation'
import { useUpdateLocation } from '../api/useUpdateLocation'
import { getDescendantIds, normalizeLocError } from '../api/locationsService'
import type { Location } from '../api/locationsService'

interface LocationFormProps {
  open: boolean
  onClose: () => void
  editLocation?: Location | null
  defaultParentId?: string | null
  allLocations: Location[]
}

function contextToStructuredAddress(
  context: CoordinateSelectionContext | null,
  addressInput: string,
): StructuredAddress {
  const trimmedAddress = addressInput.trim()
  return {
    street: context?.street ?? null,
    street_number: context?.street_number ?? null,
    city: context?.city ?? null,
    province: context?.province ?? null,
    postal_code: context?.postal_code ?? null,
    country_code: context?.country_code ?? null,
    address: trimmedAddress.length > 0 ? trimmedAddress : (context?.address ?? null),
  }
}

export function LocationForm({
  open,
  onClose,
  editLocation,
  defaultParentId,
  allLocations,
}: LocationFormProps) {
  const { t } = useTranslation('locations')
  const { toast } = useToast()
  const { activeSite, activeTenant } = useTenant()
  const isEditing = !!editLocation

  const createMutation = useCreateLocation()
  const updateMutation = useUpdateLocation()
  const [externalCoordinates, setExternalCoordinates] = useState<CoordinatePoint | null>(null)
  const [externalCoordinateContext, setExternalCoordinateContext] = useState<CoordinateSelectionContext | null>(null)
  const [externalAddress, setExternalAddress] = useState('')
  const [externalStructuredAddress, setExternalStructuredAddress] = useState<StructuredAddress>({})
  const [showCoordinates, setShowCoordinates] = useState(false)

  const {
    register,
    handleSubmit,
    reset,
    setValue,
    watch,
    formState: { errors, isSubmitting },
  } = useForm<LocationFormValues>({
    resolver: zodResolver(locationSchema),
    defaultValues: { name: '', type: 'room', status: 'active', parent_id: null },
  })

  // Sync form values whenever the dialog opens or the target changes
  useEffect(() => {
    if (!open) return
    if (editLocation) {
      const parsedGeo = parseGeoCoordinates(editLocation.geo_coordinates)
      reset({
        name: editLocation.name ?? '',
        type: (editLocation.type as LocationFormValues['type']) ?? 'room',
        status: (editLocation.status as LocationFormValues['status']) ?? 'active',
        parent_id: editLocation.parent_id ?? null,
      })
      setExternalCoordinates(parsedGeo.point)
      setExternalCoordinateContext(
        parsedGeo.point
          ? {
              ...parsedGeo.address,
              address: parsedGeo.address.address ?? null,
              provider: parsedGeo.provider ?? 'manual',
              source: parsedGeo.source ?? 'manual_input',
              providerData: parsedGeo.providerData,
            }
          : null,
      )
      setExternalStructuredAddress(parsedGeo.address)
      setExternalAddress(parsedGeo.address.address ?? '')
      setShowCoordinates(!!parsedGeo.point)
    } else {
      reset({
        name: '',
        type: 'room',
        status: 'active',
        parent_id: defaultParentId ?? null,
      })
      setExternalCoordinates(null)
      setExternalCoordinateContext(null)
      setExternalAddress('')
      setExternalStructuredAddress({})
      setShowCoordinates(false)
    }
  }, [open, editLocation, defaultParentId, reset])

  const selectedParentId = watch('parent_id')
  const selectedType = watch('type')
  const selectedStatus = watch('status')

  function handleExternalCoordinateContextChange(context: CoordinateSelectionContext | null) {
    setExternalCoordinateContext(context)
    if (!context) {
      setExternalStructuredAddress({})
      setExternalAddress('')
      return
    }

    setExternalStructuredAddress({
      street: context.street ?? null,
      street_number: context.street_number ?? null,
      city: context.city ?? null,
      province: context.province ?? null,
      postal_code: context.postal_code ?? null,
      country_code: context.country_code ?? null,
      address: context.address ?? null,
    })
    // Avoid keeping a stale search address when starting geolocation / map click.
    setExternalAddress(context.address ?? '')
  }

  function handleExternalAddressFieldsChange(next: StructuredAddress) {
    setExternalStructuredAddress(next)
    setExternalCoordinateContext((prev) => ({
      address: prev?.address ?? null,
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
  }

  // Exclude self + descendants to prevent circular hierarchies
  const excludedIds: (string | null | undefined)[] = editLocation
    ? [editLocation.id, ...getDescendantIds(allLocations, editLocation.id!)]
    : []

  // Parents must be from the same site
  const currentSiteId = editLocation?.site_id ?? activeSite?.id
  const parentOptions = allLocations.filter(
    (l) =>
      l.status !== 'inactive' &&
      !excludedIds.includes(l.id) &&
      (!currentSiteId || l.site_id === currentSiteId),
  )

  async function onSubmit(values: LocationFormValues) {
    try {
      const nextGeoCoordinates = showCoordinates
        ? externalCoordinates
          ? (buildGeoCoordinates(
              externalCoordinates,
              contextToStructuredAddress(externalCoordinateContext, externalAddress),
              externalCoordinateContext
                ? {
                    provider: externalCoordinateContext.provider,
                    source: externalCoordinateContext.source,
                    providerData: externalCoordinateContext.providerData,
                  }
                : undefined,
            ) as Location['geo_coordinates'])
          : null
        : undefined

      if (isEditing) {
        await updateMutation.mutateAsync({
          id: editLocation!.id!,
          params: {
            name: values.name,
            type: values.type,
            status: values.status,
            parent_id: values.parent_id ?? null,
            ...(typeof nextGeoCoordinates !== 'undefined'
              ? { geo_coordinates: nextGeoCoordinates }
              : {}),
          },
        })
        toast({ description: t('locations.toast.updated', 'Ubicació actualitzada') })
      } else {
        if (!activeTenant?.id) {
          toast({
            variant: 'destructive',
            description: t('locations.errors.no_tenant', 'Selecciona una organització per crear una ubicació'),
          })
          return
        }
        if (!activeSite?.id) {
          toast({
            variant: 'destructive',
            description: t('locations.errors.no_site', 'Selecciona un local per crear una ubicació'),
          })
          return
        }
        await createMutation.mutateAsync({
          tenant_id: activeTenant.id,
          name: values.name,
          type: values.type,
          status: values.status,
          site_id: activeSite.id,
          parent_id: values.parent_id ?? null,
          ...(typeof nextGeoCoordinates !== 'undefined'
            ? { geo_coordinates: nextGeoCoordinates }
            : {}),
        })
        toast({ description: t('locations.toast.created', 'Ubicació creada') })
      }
      onClose()
    } catch (err) {
      const kind = normalizeLocError(err)
      toast({
        variant: 'destructive',
        description:
          kind === 'unauthorized'
            ? t('locations.errors.unauthorized', 'No tens permís per fer aquesta acció')
            : t('locations.errors.save_failed', "Error en desar la ubicació"),
      })
    }
  }

  return (
    <Dialog open={open} onOpenChange={(v) => !v && onClose()}>
      <DialogContent
        className={cn(
          'flex flex-col max-h-[90vh]',
          showCoordinates ? 'sm:max-w-4xl' : 'sm:max-w-lg',
        )}
      >
        <DialogHeader className="shrink-0">
          <DialogTitle>
            {isEditing
              ? t('locations.form.title_edit', 'Editar ubicació')
              : t('locations.form.title_create', 'Nova ubicació')}
          </DialogTitle>
        </DialogHeader>

        <form onSubmit={handleSubmit(onSubmit)} className="flex flex-col flex-1 min-h-0">
          <div className="overflow-y-auto flex-1 space-y-4 pt-1 pl-1 pr-1 pb-4">
          <div className={cn(showCoordinates && 'grid gap-4 lg:grid-cols-2 lg:items-start')}>
            <div className="space-y-4">
          {/* Name */}
          <div className="space-y-1.5">
            <label className="text-sm font-medium text-foreground">
              {t('locations.form.name_label', 'Nom')} *
            </label>
            <Input
              {...register('name')}
              placeholder={
                showCoordinates && proposeLocationNameFromAddress(externalStructuredAddress)
                  ? proposeLocationNameFromAddress(externalStructuredAddress)
                  : t('locations.form.name_placeholder', "p.ex. Sala de reunions A")
              }
              autoFocus
            />
            {errors.name && (
              <p className="text-xs text-destructive">
                {t('locations.form.errors.name_required', 'El nom és obligatori')}
              </p>
            )}
          </div>

          {/* Type + Status */}
          <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
          <div className="space-y-1.5">
            <label className="text-sm font-medium text-foreground">
              {t('locations.form.type_label', 'Tipus')} *
            </label>
            <select
              id="loc-type"
              aria-label={t('locations.form.type_label', 'Tipus')}
              value={selectedType}
              onChange={(e) =>
                setValue('type', e.target.value as LocationFormValues['type'], {
                  shouldValidate: true,
                })
              }
              className="w-full h-9 rounded-md border border-input bg-background px-3 text-sm focus:outline-none focus:ring-1 focus:ring-ring"
            >
              {LOCATION_TYPES.map((lt) => (
                <option key={lt} value={lt}>
                  {t(`locations.type.${lt}`, lt)}
                </option>
              ))}
            </select>
          </div>

          <div className="space-y-1.5">
            <label className="text-sm font-medium text-foreground">
              {t('locations.form.status_label', 'Estat')} *
            </label>
            <select
              id="loc-status"
              aria-label={t('locations.form.status_label', 'Estat')}
              value={selectedStatus}
              onChange={(e) =>
                setValue('status', e.target.value as LocationFormValues['status'], {
                  shouldValidate: true,
                })
              }
              className="w-full h-9 rounded-md border border-input bg-background px-3 text-sm focus:outline-none focus:ring-1 focus:ring-ring"
            >
              {LOCATION_STATUSES.map((ls) => (
                <option key={ls} value={ls}>
                  {t(`locations.status.${ls}`, ls)}
                </option>
              ))}
            </select>
          </div>
          </div>

          {/* Parent selector */}
          <div className="space-y-1.5">
            <label className="text-sm font-medium text-foreground">
              {t('locations.form.parent_label', 'Ubicació pare')}
            </label>
            <select
              id="loc-parent"
              aria-label={t('locations.form.parent_label', 'Ubicació pare')}
              value={selectedParentId ?? ''}
              onChange={(e) =>
                setValue('parent_id', e.target.value || null, { shouldValidate: true })
              }
              className="w-full h-9 rounded-md border border-input bg-background px-3 text-sm focus:outline-none focus:ring-1 focus:ring-ring"
            >
              <option value="">
                {t('locations.form.no_parent', '(Arrel, sense pare)')}
              </option>
              {parentOptions.map((l) => (
                <option key={l.id} value={l.id!}>
                  {l.name ?? l.id}
                </option>
              ))}
            </select>
          </div>

          {/* Coordinates toggle */}
          <div className="flex items-center gap-2">
            <input
              id="loc-coords-toggle"
              type="checkbox"
              checked={showCoordinates}
              onChange={(e) => {
                setShowCoordinates(e.target.checked)
                if (!e.target.checked) {
                  setExternalCoordinates(null)
                  setExternalCoordinateContext(null)
                  setExternalAddress('')
                  setExternalStructuredAddress({})
                }
              }}
              className="h-4 w-4 rounded border-input accent-primary"
            />
            <label htmlFor="loc-coords-toggle" className="text-sm font-medium text-foreground cursor-pointer">
              {t('locations.form.coordinates_toggle', 'Afegir coordenades GPS')}
            </label>
          </div>

          {showCoordinates && (
            <div className="space-y-3">
              <AddressLocationFields
                value={externalStructuredAddress}
                onChange={handleExternalAddressFieldsChange}
                disabled={isSubmitting}
              />

              <div className="space-y-1.5">
                <label className="text-sm font-medium text-foreground">
                  {t('locations.form.external_address_label', 'Direcció')}
                </label>
                <Input
                  value={externalAddress}
                  onChange={(event) => setExternalAddress(event.target.value)}
                  placeholder={t(
                    'locations.form.external_address_placeholder',
                    'Ex: Carrer Major 1, Barcelona',
                  )}
                />
              </div>
            </div>
          )}
            </div>

          {showCoordinates && (
            <div className="space-y-2">
              <p className="text-xs text-muted-foreground">
                {t(
                  'locations.form.external_coordinates_hint',
                  'Cerca o marca al mapa. Cada cerca / «La meva ubicació» reinicia el punt anterior.',
                )}
              </p>

              <CoordinatePicker
                value={externalCoordinates}
                onChange={setExternalCoordinates}
                onContextChange={handleExternalCoordinateContextChange}
                disabled={isSubmitting}
                showHeader={false}
                mapClassName="h-72"
              />
            </div>
          )}
          </div>

          </div>{/* end scrollable */}

          {/* Footer always visible */}
          <div className="shrink-0 flex justify-end gap-2 pt-3 border-t mt-3">
            <Button type="button" variant="outline" onClick={onClose} disabled={isSubmitting}>
              {t('locations.form.cancel', 'Cancel·lar')}
            </Button>
            <Button type="submit" disabled={isSubmitting}>
              {isSubmitting
                ? t('locations.form.saving', 'Desant…')
                : t('locations.form.save', 'Desar')}
            </Button>
          </div>
        </form>
      </DialogContent>
    </Dialog>
  )
}
