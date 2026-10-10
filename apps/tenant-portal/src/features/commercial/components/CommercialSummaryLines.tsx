import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Switch } from '@/components/ui/switch'
import {
  formatMoney,
  type CommercialDocumentLine,
} from '../utils/commercialDocumentModel'

type VatGroup = {
  rate: number
  base: number
  tax: number
  lines: CommercialDocumentLine[]
}

function vatGroups(lines: CommercialDocumentLine[]): VatGroup[] {
  const order: number[] = []
  const map = new Map<number, VatGroup>()
  for (const line of lines) {
    const raw = Number(line.tax_rate)
    const rate = Number.isFinite(raw) ? raw : 0
    let group = map.get(rate)
    if (!group) {
      group = { rate, base: 0, tax: 0, lines: [] }
      map.set(rate, group)
      order.push(rate)
    }
    group.lines.push(line)
    group.base += Number(line.line_subtotal ?? 0)
    group.tax += Number(line.line_tax ?? 0)
  }
  return order.map((rate) => map.get(rate)!)
}

function formatRate(rate: number): string {
  return new Intl.NumberFormat('ca-ES', { maximumFractionDigits: 2 }).format(rate)
}

function LineRow({
  line,
  currency,
  showPrices,
  amount,
  extra,
}: {
  line: CommercialDocumentLine
  currency: string
  showPrices: boolean
  amount: number
  extra?: string
}) {
  return (
    <li className="flex items-start justify-between gap-3 px-3 py-3">
      <div className="min-w-0">
        <p className="text-sm font-medium text-foreground">{line.name}</p>
        <p className="text-xs tabular-nums text-muted-foreground">
          {Number(line.quantity)} {line.unit}
          {showPrices ? ` · ${formatMoney(line.unit_price, currency)}` : ''}
          {extra ? ` · ${extra}` : ''}
        </p>
      </div>
      {showPrices ? (
        <p className="shrink-0 text-sm font-medium tabular-nums text-foreground">
          {formatMoney(amount, currency)}
        </p>
      ) : null}
    </li>
  )
}

export function CommercialSummaryLines({
  lines,
  currency,
  showPrices,
  subtotal,
  total,
}: {
  lines: CommercialDocumentLine[]
  currency: string
  showPrices: boolean
  subtotal: number
  total: number
}) {
  const { t } = useTranslation('projects')
  const groups = vatGroups(lines)
  const singleRate = groups.length <= 1
  const [groupVat, setGroupVat] = useState(true)
  const grouped = singleRate || groupVat
  const rate = groups[0]?.rate ?? 0

  return (
    <>
      {!singleRate ? (
        <label className="flex items-center justify-between gap-3 text-sm">
          <span>{t('projects.commercial.group_vat', 'Agrupar IVA')}</span>
          <Switch checked={groupVat} onCheckedChange={setGroupVat} />
        </label>
      ) : null}

      {grouped ? (
        <div className="space-y-3">
          {groups.map((group) => (
            <section key={group.rate} className="space-y-1">
              {!singleRate ? (
                <p className="text-xs font-medium text-muted-foreground">
                  {t('projects.commercial.vat_rate', 'IVA {{rate}}%', { rate: formatRate(group.rate) })}
                </p>
              ) : null}
              <ul className="divide-y divide-border rounded-xl border border-border">
                {group.lines.map((line) => (
                  <LineRow
                    key={line.id}
                    line={line}
                    currency={currency}
                    showPrices={showPrices}
                    amount={Number(line.line_subtotal ?? 0)}
                  />
                ))}
              </ul>
            </section>
          ))}
        </div>
      ) : (
        <ul className="divide-y divide-border rounded-xl border border-border">
          {lines.map((line) => (
            <LineRow
              key={line.id}
              line={line}
              currency={currency}
              showPrices={showPrices}
              amount={Number(line.line_total ?? 0)}
              extra={
                showPrices
                  ? t('projects.commercial.vat_rate', 'IVA {{rate}}%', {
                      rate: formatRate(Number(line.tax_rate) || 0),
                    })
                  : undefined
              }
            />
          ))}
        </ul>
      )}

      {showPrices ? (
        <section className="space-y-1 text-sm">
          {grouped && !singleRate
            ? groups.map((group) => (
                <div key={group.rate} className="space-y-1">
                  <div className="flex justify-between text-muted-foreground">
                    <span>
                      {t('projects.commercial.vat_base', 'Base IVA {{rate}}%', {
                        rate: formatRate(group.rate),
                      })}
                    </span>
                    <span className="tabular-nums">{formatMoney(group.base, currency)}</span>
                  </div>
                  <div className="flex justify-between text-muted-foreground">
                    <span>
                      {t('projects.commercial.vat_rate', 'IVA {{rate}}%', {
                        rate: formatRate(group.rate),
                      })}
                    </span>
                    <span className="tabular-nums">{formatMoney(group.tax, currency)}</span>
                  </div>
                </div>
              ))
            : (
              <>
                <div className="flex justify-between text-muted-foreground">
                  <span>{t('projects.commercial.view_subtotal', 'Base')}</span>
                  <span className="tabular-nums">{formatMoney(subtotal, currency)}</span>
                </div>
                <div className="flex justify-between text-muted-foreground">
                  <span>
                    {singleRate
                      ? t('projects.commercial.vat_rate', 'IVA {{rate}}%', { rate: formatRate(rate) })
                      : t('projects.commercial.view_tax', 'IVA')}
                  </span>
                  <span className="tabular-nums">
                    {formatMoney(
                      singleRate ? (groups[0]?.tax ?? 0) : groups.reduce((sum, g) => sum + g.tax, 0),
                      currency,
                    )}
                  </span>
                </div>
              </>
            )}
          <div className="flex justify-between border-t border-border pt-1 text-base font-semibold text-foreground">
            <span>{t('projects.commercial.view_total', 'Total')}</span>
            <span className="tabular-nums">{formatMoney(total, currency)}</span>
          </div>
        </section>
      ) : null}
    </>
  )
}
