import { monthLabel } from '@/features/attendance/api/monthlyReportService'

function normalizePhoneForWhatsApp(phone: string): string {
  return phone.replace(/[^\d+]/g, '').replace(/^\+/, '')
}

export function buildMonthlyConfirmWhatsAppMessage(
  year: number,
  month: number,
  locale = 'ca-ES',
): string {
  const label = monthLabel(year, month, locale)
  return [
    `Hola! Si us plau confirma el teu registre mensual de ${label}.`,
    'Obre el teu enllaç personal del portal empleat i ves a «Registre mensual».',
    'Gràcies!',
  ].join(' ')
}

export function buildMonthlyConfirmWhatsAppUrl(phone: string, message: string): string {
  const normalized = normalizePhoneForWhatsApp(phone)
  return `https://wa.me/${normalized}?text=${encodeURIComponent(message)}`
}

export function openMonthlyConfirmWhatsApp(
  phone: string | null | undefined,
  year: number,
  month: number,
  locale = 'ca-ES',
): { ok: true; url: string } | { ok: false; message: string } {
  const message = buildMonthlyConfirmWhatsAppMessage(year, month, locale)
  if (!phone?.trim()) {
    return { ok: false, message }
  }
  return { ok: true, url: buildMonthlyConfirmWhatsAppUrl(phone, message) }
}
