import { useTranslation } from 'react-i18next'
import type { CommercialRelationshipBadge } from '../utils/commercialRelationshipBadges'

const LABEL: Record<CommercialRelationshipBadge, { key: string; fallback: string }> = {
  quote: { key: 'projects.commercial.badge_quote', fallback: 'Pressupost' },
  quote_contract: {
    key: 'projects.commercial.badge_quote_contract',
    fallback: 'Pressupost-contracte',
  },
  formal_contract: {
    key: 'projects.commercial.badge_formal_contract',
    fallback: 'Contracte formal',
  },
  agreement_pending: {
    key: 'projects.commercial.badge_agreement_pending',
    fallback: 'Acord pendent de firma',
  },
  agreement_active: {
    key: 'projects.commercial.badge_agreement_active',
    fallback: 'Acord actiu',
  },
}

export function CommercialRelationshipBadges({
  kinds,
}: {
  kinds: CommercialRelationshipBadge[]
}) {
  const { t } = useTranslation('projects')
  if (kinds.length === 0) return null
  return (
    <>
      {kinds.map((kind) => (
        <span
          key={kind}
          className="inline-flex items-center rounded-full border border-border bg-background px-2 py-0.5 text-xs text-foreground"
        >
          {t(LABEL[kind].key, LABEL[kind].fallback)}
        </span>
      ))}
    </>
  )
}
