import { useTranslation } from 'react-i18next'
import { lineNet, lineTax, type OutputLine, type PreviewTotals } from '@pimed/price-calculator'

const moneyFmt = new Intl.NumberFormat('ca-ES', {
  style: 'currency',
  currency: 'EUR',
})

function lineSubtotal(line: OutputLine): number {
  return Number(lineNet(line.quantity, line.unit_price, line.discount_pct).toFixed(2))
}

function lineTotalWithTax(line: OutputLine): number {
  const net = lineNet(line.quantity, line.unit_price, line.discount_pct)
  const tax = lineTax(net, line.tax_rate)
  return Number(net.add(tax).toFixed(2))
}

type Props = {
  lines: OutputLine[]
  totals: PreviewTotals | null
}

/** Full de preus només lectura — mateix format que Preparar (OS). */
export function CalculatorPreviewSheet({ lines, totals }: Props) {
  const { t } = useTranslation('catalog')

  if (lines.length === 0) {
    return (
      <div className="flex flex-col items-center justify-center gap-2 rounded-xl border border-dashed border-border py-8">
        <p className="text-sm text-muted-foreground">
          {t('catalog.calculators.preview_no_lines', 'Cap línia amb aquests paràmetres.')}
        </p>
      </div>
    )
  }

  const subtotal = totals
    ? Number(totals.subtotal)
    : lines.reduce((a, l) => a + lineSubtotal(l), 0)
  const taxTotal = totals
    ? Number(totals.tax_total)
    : lines.reduce((a, l) => a + (lineTotalWithTax(l) - lineSubtotal(l)), 0)
  const total = totals ? Number(totals.total) : subtotal + taxTotal

  return (
    <div className="space-y-3">
      <div className="space-y-2 sm:hidden">
        {lines.map((line) => (
          <div
            key={line.key}
            className="space-y-2 rounded-xl border border-border bg-card p-4"
          >
            <div className="flex items-start justify-between gap-2">
              <span className="font-medium text-foreground">{line.name}</span>
              <span className="text-xs text-muted-foreground">{line.kind}</span>
            </div>
            {line.description ? (
              <p className="text-xs text-muted-foreground">{line.description}</p>
            ) : null}
            <div className="flex flex-wrap gap-x-3 gap-y-1 text-sm tabular-nums text-muted-foreground">
              <span>
                {line.quantity} {line.unit}
              </span>
              <span>{moneyFmt.format(Number(line.unit_price))}</span>
              {Number(line.discount_pct) > 0 ? <span>−{line.discount_pct}%</span> : null}
              <span>IVA {line.tax_rate}%</span>
            </div>
            <div className="flex justify-between text-sm">
              <span className="text-muted-foreground">
                {t('catalog.calculators.col_total', 'Total')}
              </span>
              <span className="font-semibold tabular-nums text-foreground">
                {moneyFmt.format(lineTotalWithTax(line))}
              </span>
            </div>
          </div>
        ))}
        <div className="space-y-1 rounded-xl border border-border bg-muted/20 px-4 py-3">
          <div className="flex justify-between text-sm text-muted-foreground">
            <span>{t('catalog.calculators.totals_subtotal', 'Subtotal (sense IVA)')}</span>
            <span className="font-medium tabular-nums text-foreground">
              {moneyFmt.format(subtotal)}
            </span>
          </div>
          <div className="flex justify-between text-sm text-muted-foreground">
            <span>{t('catalog.calculators.totals_tax', 'IVA')}</span>
            <span className="font-medium tabular-nums text-foreground">
              {moneyFmt.format(taxTotal)}
            </span>
          </div>
          <div className="flex justify-between text-sm font-semibold text-foreground">
            <span>{t('catalog.calculators.totals_total', 'Total (amb IVA)')}</span>
            <span className="tabular-nums">{moneyFmt.format(total)}</span>
          </div>
        </div>
      </div>

      <div className="hidden overflow-hidden rounded-xl border border-border sm:block">
        <table className="w-full text-sm">
          <thead>
            <tr className="border-b border-border bg-muted/40">
              <th className="px-4 py-2.5 text-left font-medium text-muted-foreground">
                {t('catalog.calculators.col_name', 'Descripció')}
              </th>
              <th className="px-4 py-2.5 text-right font-medium text-muted-foreground">
                {t('catalog.calculators.col_qty', 'Qtd')}
              </th>
              <th className="hidden px-4 py-2.5 text-left font-medium text-muted-foreground md:table-cell">
                {t('catalog.calculators.col_unit', 'Unitat')}
              </th>
              <th className="px-4 py-2.5 text-right font-medium text-muted-foreground">
                {t('catalog.calculators.col_unit_price', 'Preu unit.')}
              </th>
              <th className="hidden px-4 py-2.5 text-right font-medium text-muted-foreground md:table-cell">
                {t('catalog.calculators.col_discount', 'Dte%')}
              </th>
              <th className="px-4 py-2.5 text-right font-medium text-muted-foreground">
                {t('catalog.calculators.col_tax', 'IVA%')}
              </th>
              <th className="px-4 py-2.5 text-right font-medium text-muted-foreground">
                {t('catalog.calculators.col_subtotal', 'Subtotal')}
              </th>
              <th className="px-4 py-2.5 text-right font-medium text-muted-foreground">
                {t('catalog.calculators.col_total', 'Total')}
              </th>
            </tr>
          </thead>
          <tbody className="divide-y divide-border">
            {lines.map((line) => (
              <tr key={line.key} className="transition-colors hover:bg-muted/20">
                <td className="px-4 py-2.5 font-medium text-foreground">
                  {line.name}
                  {line.description ? (
                    <span className="mt-0.5 block text-xs font-normal text-muted-foreground">
                      {line.description}
                    </span>
                  ) : null}
                </td>
                <td className="px-4 py-2.5 text-right tabular-nums">{line.quantity}</td>
                <td className="hidden px-4 py-2.5 text-muted-foreground md:table-cell">
                  {line.unit}
                </td>
                <td className="px-4 py-2.5 text-right tabular-nums">
                  {moneyFmt.format(Number(line.unit_price))}
                </td>
                <td className="hidden px-4 py-2.5 text-right tabular-nums md:table-cell">
                  {Number(line.discount_pct) > 0 ? line.discount_pct : '—'}
                </td>
                <td className="px-4 py-2.5 text-right tabular-nums">{line.tax_rate}</td>
                <td className="px-4 py-2.5 text-right tabular-nums">
                  {moneyFmt.format(lineSubtotal(line))}
                </td>
                <td className="px-4 py-2.5 text-right font-medium tabular-nums">
                  {moneyFmt.format(lineTotalWithTax(line))}
                </td>
              </tr>
            ))}
          </tbody>
          <tfoot>
            <tr className="border-t border-border bg-muted/20">
              <td colSpan={6} className="px-4 py-2 text-right text-sm text-muted-foreground">
                {t('catalog.calculators.totals_subtotal', 'Subtotal (sense IVA)')}
              </td>
              <td className="px-4 py-2 text-right font-medium tabular-nums" colSpan={2}>
                {moneyFmt.format(subtotal)}
              </td>
            </tr>
            <tr className="bg-muted/20">
              <td colSpan={6} className="px-4 py-2 text-right text-sm text-muted-foreground">
                {t('catalog.calculators.totals_tax', 'IVA')}
              </td>
              <td className="px-4 py-2 text-right font-medium tabular-nums" colSpan={2}>
                {moneyFmt.format(taxTotal)}
              </td>
            </tr>
            <tr className="bg-muted/30">
              <td colSpan={6} className="px-4 py-2.5 text-right text-sm font-semibold">
                {t('catalog.calculators.totals_total', 'Total (amb IVA)')}
              </td>
              <td className="px-4 py-2.5 text-right text-sm font-semibold tabular-nums" colSpan={2}>
                {moneyFmt.format(total)}
              </td>
            </tr>
          </tfoot>
        </table>
      </div>
    </div>
  )
}
