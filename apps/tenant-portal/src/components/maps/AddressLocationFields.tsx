import type { ChangeEvent } from 'react'
import { useTranslation } from 'react-i18next'
import { Input } from '@/components/ui/input'
import type { StructuredAddress } from '@/lib/geo/geoCoordinates'

interface AddressLocationFieldsProps {
  value: StructuredAddress
  onChange: (value: StructuredAddress) => void
  disabled?: boolean
  className?: string
}

function updateField(
  value: StructuredAddress,
  onChange: (value: StructuredAddress) => void,
  field: keyof StructuredAddress,
) {
  return (event: ChangeEvent<HTMLInputElement>) => {
    const next = event.target.value
    onChange({ ...value, [field]: next.length > 0 ? next : null })
  }
}

/**
 * Shared structured address inputs (street/number/city/province/postal code/country).
 * Used alongside `CoordinatePicker` by any entity that captures a location — see
 * docs/plans/maps-geocoding-byok/ADR-geo-coordinates.md.
 */
export function AddressLocationFields({
  value,
  onChange,
  disabled = false,
  className,
}: AddressLocationFieldsProps) {
  const { t } = useTranslation('maps')

  return (
    <div className={className ?? 'grid grid-cols-1 md:grid-cols-2 gap-3'}>
      <div className="space-y-1 md:col-span-2">
        <label className="text-xs font-medium text-muted-foreground">
          {t('address_fields.street', 'Carrer')}
        </label>
        <Input
          type="text"
          value={value.street ?? ''}
          onChange={updateField(value, onChange, 'street')}
          disabled={disabled}
          placeholder={t('address_fields.street_placeholder', 'Carrer Major')}
        />
      </div>

      <div className="space-y-1">
        <label className="text-xs font-medium text-muted-foreground">
          {t('address_fields.street_number', 'Número')}
        </label>
        <Input
          type="text"
          value={value.street_number ?? ''}
          onChange={updateField(value, onChange, 'street_number')}
          disabled={disabled}
          placeholder={t('address_fields.street_number_placeholder', '12')}
        />
      </div>

      <div className="space-y-1">
        <label className="text-xs font-medium text-muted-foreground">
          {t('address_fields.postal_code', 'Codi postal')}
        </label>
        <Input
          type="text"
          value={value.postal_code ?? ''}
          onChange={updateField(value, onChange, 'postal_code')}
          disabled={disabled}
          placeholder={t('address_fields.postal_code_placeholder', '17004')}
        />
      </div>

      <div className="space-y-1">
        <label className="text-xs font-medium text-muted-foreground">
          {t('address_fields.city', 'Ciutat')}
        </label>
        <Input
          type="text"
          value={value.city ?? ''}
          onChange={updateField(value, onChange, 'city')}
          disabled={disabled}
          placeholder={t('address_fields.city_placeholder', 'Girona')}
        />
      </div>

      <div className="space-y-1">
        <label className="text-xs font-medium text-muted-foreground">
          {t('address_fields.province', 'Província')}
        </label>
        <Input
          type="text"
          value={value.province ?? ''}
          onChange={updateField(value, onChange, 'province')}
          disabled={disabled}
          placeholder={t('address_fields.province_placeholder', 'Girona')}
        />
      </div>

      <div className="space-y-1 md:col-span-2">
        <label className="text-xs font-medium text-muted-foreground">
          {t('address_fields.country_code', 'País')}
        </label>
        <Input
          type="text"
          value={value.country_code ?? ''}
          onChange={updateField(value, onChange, 'country_code')}
          disabled={disabled}
          placeholder={t('address_fields.country_code_placeholder', 'ES')}
        />
      </div>
    </div>
  )
}
