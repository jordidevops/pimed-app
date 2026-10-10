# CF-24 — Vocabulari tancat de plantilles comercials

> **Estat:** font de veritat (2026-10-08). Extret de:
> - [`commercial-document-context.ts`](../../../supabase/functions/_shared/commercial-document-context.ts)
> - [`commercial-agreement-context.ts`](../../../supabase/functions/_shared/commercial-agreement-context.ts)
> - Validadors: `validate_commercial_template_locale` (`20261228000008`), `validate_commercial_agreement_template_locale` (`20261188000001`)
>
> Mirall portal: [`commercialClosedVocabulary.ts`](../../../apps/tenant-portal/src/features/signing/utils/commercialClosedVocabulary.ts), [`commercialTemplateContract.ts`](../../../apps/tenant-portal/src/features/signing/utils/commercialTemplateContract.ts).

## Capes

| Capa | Ús |
|------|-----|
| **Contracte de plantilla** | Camins Liquid `{{ … }}` / DOCX `[[ … ]]` que l’autor pot escriure |
| **Snapshot intern** | Fallbacks al construir el context (`partyName`: `display_name` → `legal_name` → `name`). **No** són camins de plantilla |

## Família `quote` / `delivery_note` / `quote_amendment`

| Bloc | Camps del contracte |
|------|---------------------|
| `globals` | `today`, `date`, `year`, `now` |
| `tenant` | `name`, `tax_id`, `address`, `phone`, `email`, `logo_url` |
| `document` | `doc_type`, `doc_number`, `status`, `locale`, `currency`, `issued_at`, `valid_until`, `created_at`, `issued_at_display`, `valid_until_display`, `created_at_display`, `is_amendment`, `parent_doc_number`, `show_prices`, `terms_text` |
| `seller` / `buyer` | `display_name`, `tax_id`, `email`, `phone`, `address_line1`, `address_line2`, `city`, `postal_code` |
| `service_address` | `label`, `line1`, `line2`, `city`, `postal_code`, `region`, `country` |
| `lines[]` | `name`, `description`, `unit`, `quantity`, `unit_price`, `discount_pct`, `tax_rate`, `line_total`, `kind` — **no** `line_subtotal` al context públic |
| `totals` | `subtotal`, `total`, `tax_breakdown[]` (`tax_rate`, `tax_amount`, `tax_base`) |
| `legal` | `retention_days`, `jurisdiction_text` |

Alias de bucle Liquid: dins `{% for line in lines %}`, `line.<camp>` amb els camps de `lines[]`.

### Tokens mínims (SQL CF-28)

- Quote / amendment: loop `lines`, `totals.total`, `document.doc_number`, `document.valid_until`, `totals.tax_breakdown`, rol **`client_accept`**.
- Delivery note: loop `lines`, `document.doc_number`, rol **`client_delivery`**.
- **`client_reject` no és obligatori** (refús via enllaç de decisió).

Rols opcionals: `issuer`. Històric: `client_reject` tolerat en plantilles velles.

## Família `commercial_agreement`

| Bloc | Camps |
|------|-------|
| `agreement` | `id`, `status`, `kind`, `work_gate`, `starts_on`, `ends_on`, `notice_days`, `sla.response_hours`, `sla.resolution_hours`, `sla.coverage_notes`, `billing.cadence`, `billing.amount_cents`, `billing.currency`, `billing.anchor_day`, `billing.next_billing_on` |
| `source_quote` | `id`, `doc_number`, `content_hash`, `document_id` |
| `document` | `locale`, `currency` |
| `tenant` | `name` |
| `seller` / `buyer` | `display_name` només |
| `lines[]` | pass-through incl. `line_subtotal` (a diferència de quote) |
| `totals` | `subtotal`, `total` (sense `tax_breakdown`) |

Tokens mínims: `source_quote.doc_number`, `source_quote.content_hash`, loop `lines`, `totals.total`, rol **`client`**; prohibit `client_accept` / `client_reject`.

## Política de validació unknown

| Cas | Comportament |
|-----|----------------|
| Plantilla / locale **existent** | Avís (toast); no bloqueja el desar |
| Locale **nou** o publicar contingut nou | Error; missatge amb camp ofès + suggeriment si n’hi ha (`buyer.name` → `buyer.display_name`) |

SQL continua comprovant només tokens mínims. El portal aplica el catàleg unknown en desar locales full-body.

## Fora d’abast

- Placeholders lliures / inferència Word→CRM.
- `custom.*` (proposta futura, només presentació).
- Càlcul d’IVA a la plantilla.
