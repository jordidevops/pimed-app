import { Navigate, useLocation, useSearchParams } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { passesGate, useNavGateContext } from '@/features/sidebar-nav'
import { usePermission } from '@/hooks/usePermission'
import { DeliveryNotesList } from './DeliveryNotesList'

export function DeliveryNotesPage() {
  const { t } = useTranslation('projects')
  const { ctx, gatesLoading } = useNavGateContext()
  const canViewInvoices = usePermission('invoices.view')
  const officeAllowed = !gatesLoading && passesGate('isOffice', ctx)
  const salesAllowed = officeAllowed || canViewInvoices || ctx.canViewSales

  if (gatesLoading) {
    return (
      <div className="mx-auto max-w-5xl px-4 py-6">
        <p className="text-sm text-muted-foreground">{t('projects.quotes.loading', 'Carregant…')}</p>
      </div>
    )
  }
  if (!salesAllowed) return <Navigate to={ctx.homePath} replace />
  return <DeliveryNotesList />
}

/** Legacy `/cobraments` → `/sales/delivery-notes` preserving query. */
export function CobramentsRedirect() {
  const { search } = useLocation()
  return <Navigate to={{ pathname: '/sales/delivery-notes', search }} replace />
}

/** Legacy `/quotes` → `/sales/quotes` preserving query. */
export function QuotesRedirect() {
  const { search } = useLocation()
  return <Navigate to={{ pathname: '/sales/quotes', search }} replace />
}

/** Legacy `/delivery-notes` → `/sales/delivery-notes`, mapping `?view=` to detail. */
export function DeliveryNotesRedirect() {
  const [searchParams] = useSearchParams()
  const view = searchParams.get('view')
  if (view) {
    const next = new URLSearchParams(searchParams)
    next.delete('view')
    const search = next.toString()
    return (
      <Navigate
        to={{ pathname: `/sales/delivery-notes/${view}`, search: search ? `?${search}` : '' }}
        replace
      />
    )
  }
  const { search } = useLocation()
  return <Navigate to={{ pathname: '/sales/delivery-notes', search }} replace />
}
