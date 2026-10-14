import { useTranslation } from 'react-i18next'
import {
  parseSignerProgress,
  signerProgressMark,
  type SignerProgressItem,
} from '../utils/signerProgress'

export function signerProgressRoleLabel(
  item: SignerProgressItem,
  t: (key: string, fallback: string) => string,
): string {
  if (item.roleKey === 'issuer') return t('detail.signerRoleLabel.issuer', 'Prestador')
  if (item.roleKey === 'client') return t('detail.signerRoleLabel.client', 'Client')
  return item.role || item.name || t('detail.signerRoleLabel.other', 'Signant')
}

export function SignerProgressLine({ signers }: { signers: unknown }) {
  const { t } = useTranslation('signing')
  const rows = parseSignerProgress(signers)
  if (rows.length === 0) return <span className="text-muted-foreground">—</span>
  return (
    <span className="block text-xs text-foreground">
      {rows.map((row, index) => (
        <span key={`${row.role}-${row.order}-${index}`}>
          {index > 0 ? ' · ' : null}
          {signerProgressRoleLabel(row, t)} {signerProgressMark(row.status)}
        </span>
      ))}
    </span>
  )
}
