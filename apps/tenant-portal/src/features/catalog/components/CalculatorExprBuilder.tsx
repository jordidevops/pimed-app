import { useTranslation } from 'react-i18next'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import type { Definition, Expr, Parameter } from '@pimed/price-calculator'

type Props = {
  value: Expr
  onChange: (next: Expr) => void
  definition: Definition
  /** Limita opcions (p. ex. when → boolean-friendly). */
  allowBoolean?: boolean
  depth?: number
}

const CMP = ['gt', 'gte', 'lt', 'lte', 'eq', 'neq'] as const

function blankConst(n = 0): Expr {
  return { op: 'const', value: n }
}

function wrapRound(inner: Expr, decimals: 0 | 2 | 3 = 2): Expr {
  return { op: 'round', value: inner, decimals, mode: 'half_away_from_zero' }
}

export function defaultBlankLineExpr(kind: 'quantity' | 'unit_price' | 'tax' | 'discount'): Expr {
  if (kind === 'quantity') return wrapRound(blankConst(1), 3)
  if (kind === 'unit_price') return wrapRound(blankConst(0), 2)
  if (kind === 'tax') return blankConst(21)
  return blankConst(0)
}

export function CalculatorExprBuilder({
  value,
  onChange,
  definition,
  allowBoolean = true,
  depth = 0,
}: Props) {
  const { t } = useTranslation('catalog')
  const params = definition.parameters ?? []
  const constants = definition.constants ?? []
  const tables = definition.tables ?? []

  function setOp(op: Expr['op']) {
    if (op === 'const') onChange({ op: 'const', value: 0 })
    else if (op === 'param') onChange({ op: 'param', key: params[0]?.key ?? 'x' })
    else if (op === 'const_ref') onChange({ op: 'const_ref', key: constants[0]?.key ?? 'c' })
    else if (op === 'add' || op === 'mul' || op === 'min' || op === 'max') {
      onChange({ op, args: [blankConst(0), blankConst(0)] })
    } else if (op === 'sub' || op === 'div') {
      onChange({ op, left: blankConst(0), right: blankConst(0) })
    } else if (op === 'round') {
      onChange(wrapRound(blankConst(0), 2))
    } else if (op === 'cmp') {
      onChange({
        op: 'cmp',
        cmp: 'gt',
        left: { op: 'param', key: params[0]?.key ?? 'x' },
        right: blankConst(0),
      })
    } else if (op === 'if') {
      onChange({
        op: 'if',
        cond: { op: 'const', value: true },
        then: blankConst(1),
        else: blankConst(0),
      })
    } else if (op === 'lookup_exact') {
      onChange({
        op: 'lookup_exact',
        table: tables[0]?.key ?? 't',
        field: 'id',
      })
    } else if (op === 'lookup_tier') {
      onChange({
        op: 'lookup_tier',
        table: tables.find((x) => x.lookup === 'tier')?.key ?? tables[0]?.key ?? 't',
        value: wrapRound(blankConst(0), 2),
      })
    } else if (op === 'row') {
      onChange({ op: 'row', field: 'hours' })
    } else if (op === 'not') {
      onChange({ op: 'not', arg: { op: 'const', value: true } })
    } else if (op === 'and' || op === 'or') {
      onChange({ op, args: [{ op: 'const', value: true }, { op: 'const', value: false }] })
    } else if (op === 'coalesce') {
      onChange({ op: 'coalesce', args: [blankConst(0), blankConst(0)] })
    }
  }

  const box =
    depth === 0
      ? 'space-y-2 rounded-lg border border-border p-3'
      : 'space-y-2 rounded-md border border-border/70 bg-muted/20 p-2'

  return (
    <div className={box}>
      <div className="flex flex-wrap items-center gap-2">
        <select
          className="flex h-8 rounded-md border border-input bg-background px-2 text-xs"
          value={value.op}
          onChange={(e) => setOp(e.target.value as Expr['op'])}
        >
          <option value="const">{t('catalog.calculators.expr_const', 'Constant')}</option>
          <option value="param">{t('catalog.calculators.expr_param', 'Paràmetre')}</option>
          <option value="const_ref">{t('catalog.calculators.expr_const_ref', 'Tarifa')}</option>
          <option value="add">+</option>
          <option value="sub">−</option>
          <option value="mul">×</option>
          <option value="div">÷</option>
          <option value="min">min</option>
          <option value="max">max</option>
          <option value="round">{t('catalog.calculators.expr_round', 'Arrodonir')}</option>
          <option value="cmp">{t('catalog.calculators.expr_cmp', 'Comparar')}</option>
          <option value="if">if</option>
          <option value="lookup_exact">lookup exact</option>
          <option value="lookup_tier">lookup tram</option>
          <option value="row">row</option>
          {allowBoolean ? (
            <>
              <option value="and">and</option>
              <option value="or">or</option>
              <option value="not">not</option>
            </>
          ) : null}
          <option value="coalesce">coalesce</option>
        </select>
      </div>

      {value.op === 'const' ? (
        <Input
          className="h-8"
          type="number"
          value={value.value == null ? '' : String(value.value)}
          onChange={(e) => {
            const raw = e.target.value.trim()
            if (raw === '') onChange({ op: 'const', value: null })
            else if (raw === 'true' || raw === 'false')
              onChange({ op: 'const', value: raw === 'true' })
            else onChange({ op: 'const', value: Number(raw.replace(',', '.')) })
          }}
        />
      ) : null}

      {value.op === 'param' ? (
        <ParamSelect
          params={params}
          value={value.key}
          onChange={(key) => onChange({ op: 'param', key })}
        />
      ) : null}

      {value.op === 'const_ref' ? (
        <select
          className="flex h-8 w-full rounded-md border border-input bg-background px-2 text-xs"
          value={value.key}
          onChange={(e) => onChange({ op: 'const_ref', key: e.target.value })}
        >
          {constants.map((c) => (
            <option key={c.key} value={c.key}>
              {c.key}
            </option>
          ))}
        </select>
      ) : null}

      {value.op === 'add' ||
      value.op === 'mul' ||
      value.op === 'min' ||
      value.op === 'max' ||
      value.op === 'and' ||
      value.op === 'or' ||
      value.op === 'coalesce' ? (
        <div className="space-y-2">
          {value.args.map((arg, i) => (
            <CalculatorExprBuilder
              key={i}
              value={arg}
              definition={definition}
              allowBoolean={allowBoolean}
              depth={depth + 1}
              onChange={(next) => {
                const args = [...value.args]
                args[i] = next
                onChange({ ...value, args })
              }}
            />
          ))}
          <Button
            type="button"
            size="sm"
            variant="outline"
            onClick={() => onChange({ ...value, args: [...value.args, blankConst(0)] })}
          >
            + arg
          </Button>
        </div>
      ) : null}

      {value.op === 'sub' || value.op === 'div' ? (
        <div className="space-y-2">
          <CalculatorExprBuilder
            value={value.left}
            definition={definition}
            depth={depth + 1}
            onChange={(left) => onChange({ ...value, left })}
          />
          <CalculatorExprBuilder
            value={value.right}
            definition={definition}
            depth={depth + 1}
            onChange={(right) => onChange({ ...value, right })}
          />
        </div>
      ) : null}

      {value.op === 'round' ? (
        <div className="space-y-2">
          <select
            className="flex h-8 rounded-md border border-input bg-background px-2 text-xs"
            value={value.decimals}
            onChange={(e) =>
              onChange({
                ...value,
                decimals: Number(e.target.value) as 0 | 2 | 3,
              })
            }
          >
            <option value={0}>0</option>
            <option value={2}>2</option>
            <option value={3}>3</option>
          </select>
          <CalculatorExprBuilder
            value={value.value}
            definition={definition}
            depth={depth + 1}
            onChange={(inner) => onChange({ ...value, value: inner })}
          />
        </div>
      ) : null}

      {value.op === 'cmp' ? (
        <div className="space-y-2">
          <select
            className="flex h-8 rounded-md border border-input bg-background px-2 text-xs"
            value={value.cmp}
            onChange={(e) =>
              onChange({ ...value, cmp: e.target.value as (typeof CMP)[number] })
            }
          >
            {CMP.map((c) => (
              <option key={c} value={c}>
                {c}
              </option>
            ))}
          </select>
          <CalculatorExprBuilder
            value={value.left}
            definition={definition}
            depth={depth + 1}
            onChange={(left) => onChange({ ...value, left })}
          />
          <CalculatorExprBuilder
            value={value.right}
            definition={definition}
            depth={depth + 1}
            onChange={(right) => onChange({ ...value, right })}
          />
        </div>
      ) : null}

      {value.op === 'if' ? (
        <div className="space-y-2">
          <p className="text-xs text-muted-foreground">cond</p>
          <CalculatorExprBuilder
            value={value.cond}
            definition={definition}
            allowBoolean
            depth={depth + 1}
            onChange={(cond) => onChange({ ...value, cond })}
          />
          <p className="text-xs text-muted-foreground">then</p>
          <CalculatorExprBuilder
            value={value.then}
            definition={definition}
            depth={depth + 1}
            onChange={(then) => onChange({ ...value, then })}
          />
          <p className="text-xs text-muted-foreground">else</p>
          <CalculatorExprBuilder
            value={value.else}
            definition={definition}
            depth={depth + 1}
            onChange={(elseExpr) => onChange({ ...value, else: elseExpr })}
          />
        </div>
      ) : null}

      {value.op === 'lookup_exact' ? (
        <div className="grid gap-2 sm:grid-cols-2">
          <select
            className="flex h-8 rounded-md border border-input bg-background px-2 text-xs"
            value={value.table}
            onChange={(e) => onChange({ ...value, table: e.target.value })}
          >
            {tables.map((tbl) => (
              <option key={tbl.key} value={tbl.key}>
                {tbl.key}
              </option>
            ))}
          </select>
          <Input
            className="h-8"
            value={value.field}
            onChange={(e) => onChange({ ...value, field: e.target.value })}
            placeholder="field"
          />
        </div>
      ) : null}

      {value.op === 'lookup_tier' ? (
        <div className="space-y-2">
          <select
            className="flex h-8 w-full rounded-md border border-input bg-background px-2 text-xs"
            value={value.table}
            onChange={(e) => onChange({ ...value, table: e.target.value })}
          >
            {tables.map((tbl) => (
              <option key={tbl.key} value={tbl.key}>
                {tbl.key}
              </option>
            ))}
          </select>
          <CalculatorExprBuilder
            value={value.value}
            definition={definition}
            depth={depth + 1}
            onChange={(inner) => onChange({ ...value, value: inner })}
          />
        </div>
      ) : null}

      {value.op === 'row' ? (
        <Input
          className="h-8"
          value={value.field}
          onChange={(e) => onChange({ op: 'row', field: e.target.value })}
        />
      ) : null}

      {value.op === 'not' ? (
        <CalculatorExprBuilder
          value={value.arg}
          definition={definition}
          allowBoolean
          depth={depth + 1}
          onChange={(arg) => onChange({ op: 'not', arg })}
        />
      ) : null}
    </div>
  )
}

function ParamSelect({
  params,
  value,
  onChange,
}: {
  params: Parameter[]
  value: string
  onChange: (key: string) => void
}) {
  return (
    <select
      className="flex h-8 w-full rounded-md border border-input bg-background px-2 text-xs"
      value={value}
      onChange={(e) => onChange(e.target.value)}
    >
      {params.map((p) => (
        <option key={p.key} value={p.key}>
          {p.key}
        </option>
      ))}
    </select>
  )
}
