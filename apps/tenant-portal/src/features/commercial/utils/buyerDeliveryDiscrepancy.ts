export type LiveBuyerContact = {
  email?: string | null
  phone?: string | null
  phone_alt?: string | null
  display_name?: string | null
}

export type BuyerDeliveryField = 'phone' | 'email' | 'display_name'

export type BuyerDeliveryDiscrepancy = {
  field: BuyerDeliveryField
  snapshot: string
  contact: string
}

function normText(value: string | null | undefined): string {
  return (value ?? '').trim()
}

function normPhone(value: string | null | undefined): string {
  return normText(value).replace(/[^\d+]/g, '')
}

function normEmail(value: string | null | undefined): string {
  return normText(value).toLowerCase()
}

export function liveContactPhone(contact: LiveBuyerContact): string {
  return normText(contact.phone) || normText(contact.phone_alt)
}

/** Fields where the frozen quote snapshot differs from the live contact (delivery uses contact). */
export function buyerDeliveryDiscrepancies(
  snapshot: {
    phone?: string | null
    email?: string | null
    display_name?: string | null
  } | null | undefined,
  contact: LiveBuyerContact | null,
): BuyerDeliveryDiscrepancy[] {
  if (!snapshot || !contact) return []
  const out: BuyerDeliveryDiscrepancy[] = []

  const snapPhone = normText(snapshot.phone)
  const contactPhone = liveContactPhone(contact)
  if (contactPhone && normPhone(snapPhone) !== normPhone(contactPhone)) {
    out.push({
      field: 'phone',
      snapshot: snapPhone || '—',
      contact: contactPhone,
    })
  }

  const snapEmail = normText(snapshot.email)
  const contactEmail = normText(contact.email)
  if (contactEmail && normEmail(snapEmail) !== normEmail(contactEmail)) {
    out.push({
      field: 'email',
      snapshot: snapEmail || '—',
      contact: contactEmail,
    })
  }

  const snapName = normText(snapshot.display_name)
  const contactName = normText(contact.display_name)
  if (contactName && snapName.toLowerCase() !== contactName.toLowerCase()) {
    out.push({
      field: 'display_name',
      snapshot: snapName || '—',
      contact: contactName,
    })
  }

  return out
}
