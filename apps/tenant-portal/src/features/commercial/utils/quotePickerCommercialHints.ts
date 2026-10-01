import { supabase } from '@/lib/supabase'
import {
  hintFromAgreementState,
  hintFromQuoteWithoutAgreement,
  pickStrongerQuotePickerHint,
  type QuotePickerCommercialHint,
} from './quotePickerCommercialHintsLogic'

export type { QuotePickerCommercialHint } from './quotePickerCommercialHintsLogic'
export {
  hintFromAgreementState,
  hintFromQuoteWithoutAgreement,
  pickStrongerQuotePickerHint,
  rankQuotePickerHint,
} from './quotePickerCommercialHintsLogic'

type QuoteRow = {
  id: string
  project_id: string | null
  status: string
  formalization_mode: string | null
  created_at: string
}

type AgreementRow = {
  id: string
  status: string
  source_quote_id: string | null
  active_version_id: string | null
}

type VersionRow = {
  id: string
  status: string
}

type LinkRow = {
  project_id: string
  agreement_id: string
}

/**
 * Loads a best-effort commercial hint per project for the quote-create picker.
 * Priority: active/pending contract > draft agreement > pending prepare > open quote > none.
 */
export async function loadQuotePickerCommercialHints(
  projectIds: string[],
): Promise<Map<string, QuotePickerCommercialHint>> {
  const result = new Map<string, QuotePickerCommercialHint>()
  for (const id of projectIds) result.set(id, 'no_quote')
  if (projectIds.length === 0) return result

  const { data: quotesData, error: quotesError } = await supabase
    .from('commercial_documents')
    .select('id, project_id, status, formalization_mode, created_at')
    .in('project_id', projectIds)
    .in('doc_type', ['quote', 'quote_amendment'])
    .neq('status', 'cancelled')
    .order('created_at', { ascending: false })
  if (quotesError) throw quotesError

  const quotes = (quotesData ?? []) as QuoteRow[]
  const quotesByProject = new Map<string, QuoteRow[]>()
  for (const q of quotes) {
    if (!q.project_id) continue
    const list = quotesByProject.get(q.project_id) ?? []
    list.push(q)
    quotesByProject.set(q.project_id, list)
  }

  const quoteIds = quotes.map((q) => q.id)

  const [{ data: agreementsByQuote, error: agrQuoteErr }, { data: linksData, error: linksErr }] =
    await Promise.all([
      quoteIds.length
        ? supabase
            .from('commercial_agreements' as never)
            .select('id, status, source_quote_id, active_version_id')
            .in('source_quote_id', quoteIds)
            .neq('status', 'cancelled')
        : Promise.resolve({ data: [], error: null }),
      supabase
        .from('commercial_agreement_projects' as never)
        .select('project_id, agreement_id')
        .in('project_id', projectIds),
    ])
  if (agrQuoteErr) throw agrQuoteErr
  if (linksErr) throw linksErr

  const links = (linksData ?? []) as LinkRow[]
  const linkedAgreementIds = [...new Set(links.map((l) => l.agreement_id))]

  const { data: linkedAgreementsData, error: linkedAgrErr } = linkedAgreementIds.length
    ? await supabase
        .from('commercial_agreements' as never)
        .select('id, status, source_quote_id, active_version_id')
        .in('id', linkedAgreementIds)
        .neq('status', 'cancelled')
    : { data: [], error: null }
  if (linkedAgrErr) throw linkedAgrErr

  const agreements = [
    ...((agreementsByQuote ?? []) as AgreementRow[]),
    ...((linkedAgreementsData ?? []) as AgreementRow[]),
  ]
  const agreementById = new Map(agreements.map((a) => [a.id, a]))
  const agreementsByQuoteId = new Map<string, AgreementRow[]>()
  for (const a of agreements) {
    if (!a.source_quote_id) continue
    const list = agreementsByQuoteId.get(a.source_quote_id) ?? []
    list.push(a)
    agreementsByQuoteId.set(a.source_quote_id, list)
  }

  const versionIds = [
    ...new Set(
      agreements
        .map((a) => a.active_version_id)
        .filter((id): id is string => !!id),
    ),
  ]
  const { data: versionsData, error: versionsErr } = versionIds.length
    ? await supabase
        .from('commercial_agreement_versions' as never)
        .select('id, status')
        .in('id', versionIds)
    : { data: [], error: null }
  if (versionsErr) throw versionsErr
  const versionById = new Map(
    ((versionsData ?? []) as VersionRow[]).map((v) => [v.id, v]),
  )

  for (const projectId of projectIds) {
    let best: QuotePickerCommercialHint = 'no_quote'

    for (const link of links.filter((l) => l.project_id === projectId)) {
      const agr = agreementById.get(link.agreement_id)
      const ver = agr?.active_version_id ? versionById.get(agr.active_version_id) : undefined
      best = pickStrongerQuotePickerHint(
        best,
        hintFromAgreementState(agr, ver),
      )
    }

    const projectQuotes = quotesByProject.get(projectId) ?? []
    if (projectQuotes.length === 0 && best === 'no_quote') {
      result.set(projectId, 'no_quote')
      continue
    }

    for (const quote of projectQuotes) {
      const quoteAgreements = agreementsByQuoteId.get(quote.id) ?? []
      for (const agr of quoteAgreements) {
        const ver = agr.active_version_id ? versionById.get(agr.active_version_id) : undefined
        best = pickStrongerQuotePickerHint(
          best,
          hintFromAgreementState(agr, ver),
        )
      }

      if (quoteAgreements.length === 0) {
        best = pickStrongerQuotePickerHint(best, hintFromQuoteWithoutAgreement(quote))
      }
    }

    result.set(projectId, best)
  }

  return result
}
