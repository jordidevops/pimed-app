/**
 * Derived commercial lifecycle for contacts (CF-24).
 * Rule documented in docs/plans/commercial-flow/cf24-contact-lifecycle.md
 */

export type ContactCommercialLifecycle = 'effective' | 'potential' | 'agenda'

export type ContactLifecycleSignals = {
  source?: string | null
  hasAcceptedOrSignedDoc: boolean
  hasIssuedOpenQuote: boolean
  hasExecuteProject: boolean
}

/**
 * effective: accepted/signed commercial doc, or an execute (non-assessment) operational project.
 * potential: not effective, but public_portal/web source or issued quote still open.
 * agenda: neither (supplier-like / unused contact).
 */
export function deriveContactCommercialLifecycle(
  signals: ContactLifecycleSignals,
): ContactCommercialLifecycle {
  if (signals.hasAcceptedOrSignedDoc || signals.hasExecuteProject) {
    return 'effective'
  }
  const source = (signals.source ?? '').toLowerCase()
  if (
    signals.hasIssuedOpenQuote ||
    source === 'public_portal' ||
    source === 'web'
  ) {
    return 'potential'
  }
  return 'agenda'
}

export type DocRow = {
  client_id: string | null
  doc_type: string | null
  status: string | null
}

export type ProjectRow = {
  client_id: string | null
  type: string | null
  status: string | null
  service_mode: string | null
  commercial_stage?: string | null
}

export function buildLifecycleByContactId(
  contacts: Array<{ id: string; source?: string | null }>,
  docs: DocRow[],
  projects: ProjectRow[],
): Map<string, ContactCommercialLifecycle> {
  const accepted = new Set<string>()
  const issuedQuote = new Set<string>()
  for (const doc of docs) {
    if (!doc.client_id) continue
    if (doc.status === 'accepted' || doc.status === 'signed') {
      accepted.add(doc.client_id)
    }
    if (
      doc.doc_type === 'quote' &&
      (doc.status === 'issued' || doc.status === 'draft')
    ) {
      issuedQuote.add(doc.client_id)
    }
  }

  const executeProject = new Set<string>()
  for (const project of projects) {
    if (!project.client_id) continue
    if (project.status === 'cancelled') continue
    const type = project.type ?? ''
    if (type !== 'work_order' && type !== 'maintenance' && type !== 'internal') continue
    // Prospect shells do not make the contact "effective"
    if ((project.commercial_stage ?? 'execute') === 'prospect') continue
    const mode = project.service_mode ?? 'execute'
    if (mode === 'execute' || mode === 'assessment') {
      executeProject.add(project.client_id)
    }
  }

  const map = new Map<string, ContactCommercialLifecycle>()
  for (const contact of contacts) {
    map.set(
      contact.id,
      deriveContactCommercialLifecycle({
        source: contact.source,
        hasAcceptedOrSignedDoc: accepted.has(contact.id),
        hasIssuedOpenQuote: issuedQuote.has(contact.id),
        hasExecuteProject: executeProject.has(contact.id),
      }),
    )
  }
  return map
}
