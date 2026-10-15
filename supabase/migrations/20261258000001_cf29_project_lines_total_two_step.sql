-- CF-29 fase 1: alinear api.project_lines.total_with_tax amb line_net + IVA
-- en dos passos (com issue_commercial_document). Vector D10:
-- qty 1.236, price 81, tax 21% → un pas 121.14, dos passos 121.15.

CREATE OR REPLACE VIEW api.project_lines
  WITH (security_invoker = true)
AS
SELECT
  pl.id,
  pl.tenant_id,
  pl.project_id,
  pl.catalog_item_id,
  pl.kind,
  pl.name,
  pl.description,
  pl.unit,
  pl.quantity,
  pl.unit_price,
  pl.discount_pct,
  pl.tax_rate,
  pl.position,
  pl.notes,
  pl.created_at,
  pl.updated_at,
  data.line_net(pl.quantity, pl.unit_price, pl.discount_pct) AS subtotal,
  (
    data.line_net(pl.quantity, pl.unit_price, pl.discount_pct)
    + ROUND(
        data.line_net(pl.quantity, pl.unit_price, pl.discount_pct) * pl.tax_rate / 100,
        2
      )
  ) AS total_with_tax,
  ci.name AS catalog_item_name,
  ci.sku  AS catalog_item_sku,
  pl.client_op_id,
  pl.source_quote_line_id
FROM data.project_lines pl
LEFT JOIN data.catalog_items ci ON ci.id = pl.catalog_item_id
WHERE pl.tenant_id = data.active_tenant_id();

GRANT SELECT ON api.project_lines TO authenticated;

COMMENT ON VIEW api.project_lines IS
  'Línies d''OS. total_with_tax = line_net + ROUND(net*tax/100,2) (CF-29 D10).';
