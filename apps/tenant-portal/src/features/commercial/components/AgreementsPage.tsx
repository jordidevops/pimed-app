import { useMemo, useState } from 'react'
import { Link, Navigate, useLocation, useNavigate, useSearchParams } from 'react-router-dom'
import { useInfiniteQuery, useQueryClient } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import { Button } from '@/components/ui/button'
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from '@/components/ui/table'
import {
  AGREEMENTS_PAGE_SIZE,
  listCommercialAgreementsPage,
} from '../api/commercialFlowService'
import {
  formatAgreementIdentity,
  formatAgreementValidityLine,
} from '../utils/agreementIdentity'
import { commercialRelationshipBadges } from '../utils/commercialRelationshipBadges'
import { AGREEMENT_TEMPLATES_HREF, commercialTemplatesHref } from '../utils/commercialTemplatePaths'
import { enrichAgreementRows } from '../utils/enrichAgreementRows'
import { useSectorLabel } from '@/hooks/useSectorLabel'
import { useTenant } from '@/contexts/TenantContext'
import { CommercialRelationshipBadges } from './CommercialRelationshipBadges'
import { CreateFrameworkAgreementDialog } from './CreateFrameworkAgreementDialog'

export function AgreementsPage() {
  const { t } = useTranslation('projects')
  const location = useLocation()
  const navigate = useNavigate()
  const isSalesHub = location.pathname.startsWith('/sales')
  const { activeTenant, activeRole } = useTenant()
  const canManage = activeRole === 'owner' || activeRole === 'manager'
  const tenantId = activeTenant?.id ?? ''
  const queryClient = useQueryClient()
  const [createOpen, setCreateOpen] = useState(false)
  const agreementsLabel = useSectorLabel(
    'agreement_plural',
    t('projects.agreements.title', 'Acords comercials'),
  )
  const [searchParams, setSearchParams] = useSearchParams()
  const viewId = searchParams.get('view')
  const viewRedirect = viewId ? `/sales/agreements/${viewId}` : null
  const rawSignature = searchParams.get('signature')
  const signature: 'all' | 'none' | 'pending' | 'signed' =
    rawSignature === 'none' || rawSignature === 'pending' || rawSignature === 'signed'
      ? rawSignature
      : 'all'
  const rawValidity = searchParams.get('validity')
  const validity: 'all' | 'active' | 'expiring' | 'finished' =
    rawValidity === 'active' || rawValidity === 'expiring' || rawValidity === 'finished'
      ? rawValidity
      : 'all'
  const statusFilter = searchParams.get('status') === 'suspended' ? 'suspended' : null

  const signatureFilter =
    signature === 'none' ? 'draft' : signature === 'all' ? 'all' : signature

  const listQuery = useInfiniteQuery({
    queryKey: ['commercial_agreements', tenantId, 'list', signatureFilter, validity, statusFilter],
    enabled: !!tenantId,
    initialPageParam: null as { createdAt: string; id: string } | null,
    queryFn: async ({ pageParam }) => {
      const page = await listCommercialAgreementsPage({
        limit: AGREEMENTS_PAGE_SIZE,
        cursor: pageParam,
        signatureFilter,
        validityFilter: validity,
      })
      const enriched = await enrichAgreementRows(page.rows)
      return { rows: enriched, nextCursor: page.nextCursor }
    },
    getNextPageParam: (last) => last.nextCursor,
  })

  const rows = useMemo(() => {
    const all = listQuery.data?.pages.flatMap((page) => page.rows) ?? []
    if (statusFilter === 'suspended') return all.filter((row) => row.status === 'suspended')
    return all
  }, [listQuery.data, statusFilter])

  function setSignature(next: 'all' | 'none' | 'pending' | 'signed') {
    const params = new URLSearchParams(searchParams)
    if (next === 'all') params.delete('signature')
    else params.set('signature', next)
    params.delete('status')
    setSearchParams(params, { replace: true })
  }

  function setValidity(next: 'all' | 'active' | 'expiring' | 'finished') {
    const params = new URLSearchParams(searchParams)
    if (next === 'all') params.delete('validity')
    else params.set('validity', next)
    params.delete('status')
    setSearchParams(params, { replace: true })
  }

  function clearStatusFilter() {
    const params = new URLSearchParams(searchParams)
    params.delete('status')
    setSearchParams(params, { replace: true })
  }

  async function invalidateAgreements() {
    await queryClient.invalidateQueries({ queryKey: ['commercial_agreements', tenantId] })
  }

  if (viewRedirect) {
    return <Navigate to={viewRedirect} replace />
  }

  return (
    <div
      className={
        isSalesHub
          ? 'space-y-5'
          : 'mx-auto max-w-4xl space-y-5 px-4 py-6'
      }
    >
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          {!isSalesHub ? (
            <>
              <h1 className="text-2xl font-bold text-foreground">{agreementsLabel}</h1>
              <p className="mt-1 text-sm text-muted-foreground">
                {t(
                  'projects.agreements.subtitle',
                  'Contractes preparats a partir d’un pressupost acceptat, o acords marc sense pressupost.',
                )}
              </p>
            </>
          ) : null}
          <div className={`flex flex-wrap gap-x-3 gap-y-1 ${isSalesHub ? '' : 'mt-1'}`}>
            {!isSalesHub ? (
              <Link to="/sales/quotes" className="text-sm text-indigo-600 hover:underline">
                {t('projects.quotes.title', 'Pressupostos')}
              </Link>
            ) : null}
            <Link to={AGREEMENT_TEMPLATES_HREF} className="text-sm text-indigo-600 hover:underline">
              {t('projects.agreements.templates_link', 'Plantilles de contracte')}
            </Link>
            <Link
              to={commercialTemplatesHref('commercial_agreement', { create: true })}
              className="text-sm text-indigo-600 hover:underline"
            >
              {t('projects.agreements.templates_new', 'Nova plantilla')}
            </Link>
          </div>
        </div>
        {tenantId && canManage ? (
          <Button type="button" size="sm" onClick={() => setCreateOpen(true)}>
            {t('projects.agreements.framework_new', 'Nou acord marc')}
          </Button>
        ) : null}
      </div>

      <CreateFrameworkAgreementDialog
        open={createOpen}
        tenantId={tenantId}
        onOpenChange={setCreateOpen}
        onCreated={(id) => {
          void invalidateAgreements()
          navigate(`/sales/agreements/${id}`)
        }}
      />

      <div className="flex flex-wrap gap-4">
        <label className="flex max-w-xs flex-col gap-1 text-xs text-muted-foreground">
          {t('projects.quotes.filter_signature', 'Firma de l’acord')}
          <select
            className="h-10 rounded-md border border-input bg-background px-3 text-sm text-foreground"
            value={signature}
            onChange={(event) =>
              setSignature(event.target.value as 'all' | 'none' | 'pending' | 'signed')
            }
          >
            <option value="all">{t('projects.quotes.filter_all', 'Tots')}</option>
            <option value="none">{t('projects.quotes.filter_signature_none', 'Sense enviar')}</option>
            <option value="pending">
              {t('projects.commercial.badge_agreement_pending', 'Acord pendent de firma')}
            </option>
            <option value="signed">
              {t('projects.commercial.agreement_status_signed', 'Contracte signat')}
            </option>
          </select>
        </label>
        <label className="flex max-w-xs flex-col gap-1 text-xs text-muted-foreground">
          {t('projects.agreements.filter_validity', 'Vigència')}
          <select
            className="h-10 rounded-md border border-input bg-background px-3 text-sm text-foreground"
            value={validity}
            onChange={(event) => setValidity(event.target.value as typeof validity)}
          >
            <option value="all">{t('projects.quotes.filter_all', 'Tots')}</option>
            <option value="active">{t('projects.agreements.filter_active', 'Actius')}</option>
            <option value="expiring">
              {t('projects.agreements.filter_expiring', 'A caducar')}
            </option>
            <option value="finished">
              {t('projects.agreements.filter_finished', 'Finalitzats / cancel·lats')}
            </option>
          </select>
        </label>
        {statusFilter === 'suspended' ? (
          <div className="flex items-end gap-2">
            <p className="rounded-md border border-amber-500/40 bg-amber-500/10 px-3 py-2 text-sm text-foreground">
              {t('projects.agreements.filter_suspended_active', 'Filtre: suspesos')}
            </p>
            <Button type="button" size="sm" variant="ghost" onClick={clearStatusFilter}>
              {t('projects.quotes.filter_all', 'Tots')}
            </Button>
          </div>
        ) : null}
      </div>

      {listQuery.isLoading ? (
        <p className="text-sm text-muted-foreground">{t('projects.quotes.loading', 'Carregant…')}</p>
      ) : null}
      {listQuery.error ? (
        <p className="text-sm text-destructive">
          {t('projects.agreements.load_failed', 'No s’han pogut carregar els acords')}
        </p>
      ) : null}
      {!listQuery.isLoading && !listQuery.error && rows.length === 0 ? (
        <p className="rounded-2xl border border-dashed border-border p-6 text-center text-sm text-muted-foreground">
          {t('projects.agreements.empty', 'Cap acord no coincideix amb el filtre.')}
        </p>
      ) : null}
      {rows.length > 0 ? (
        <Table containerClassName="overflow-hidden rounded-2xl border border-border bg-card">
          <TableHeader className="bg-muted/50">
            <TableRow>
              <TableHead>{t('projects.agreements.col_agreement', 'Acord')}</TableHead>
              <TableHead>{t('projects.quotes.col_client', 'Client')}</TableHead>
              <TableHead>{t('projects.agreements.col_state', 'Estat')}</TableHead>
              <TableHead>{t('projects.agreements.filter_validity', 'Vigència')}</TableHead>
              <TableHead>{t('projects.agreements.col_projects', 'Projectes')}</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {rows.map((row) => {
              const identity = formatAgreementIdentity({
                primaryLineName: row.primaryLineName,
                quoteNumber: row.quoteNumber,
                kind: row.kind,
                agreementStatus: row.status,
                versionStatus: row.versionStatus,
                startsOn: row.cycleStartsOn ?? row.startsOn,
                t,
              })
              const validityLine = formatAgreementValidityLine({
                startsOn: row.cycleStartsOn ?? row.startsOn,
                endsOn: row.cycleEndsOn ?? row.endsOn,
                noticeDays: row.noticeDays,
                t,
              })
              return (
                <TableRow
                  key={row.id}
                  className="cursor-pointer"
                  onClick={() => navigate(`/sales/agreements/${row.id}`)}
                >
                  <TableCell className="font-medium">{identity}</TableCell>
                  <TableCell>
                    <Link
                      to={`/contacts/${row.clientId}`}
                      className="text-indigo-600 hover:underline"
                      onClick={(event) => event.stopPropagation()}
                    >
                      {row.clientName}
                    </Link>
                  </TableCell>
                  <TableCell>
                    <CommercialRelationshipBadges
                      kinds={commercialRelationshipBadges({
                        docType: 'quote',
                        formalizationMode: 'separate_agreement',
                        agreementStatus: row.status,
                        versionStatus: row.versionStatus,
                      })}
                    />
                  </TableCell>
                  <TableCell className="text-muted-foreground">{validityLine || '—'}</TableCell>
                  <TableCell className="text-muted-foreground">
                    {row.projectNames.length > 0
                      ? row.projectNames.join(', ')
                      : t('projects.agreements.no_projects', 'Sense projectes vinculats')}
                  </TableCell>
                </TableRow>
              )
            })}
          </TableBody>
        </Table>
      ) : null}

      {listQuery.hasNextPage ? (
        <div className="flex justify-center">
          <Button
            type="button"
            variant="outline"
            size="sm"
            disabled={listQuery.isFetchingNextPage}
            onClick={() => void listQuery.fetchNextPage()}
          >
            {t('projects.agreements.load_more', 'Carregar més')}
          </Button>
        </div>
      ) : null}
    </div>
  )
}
