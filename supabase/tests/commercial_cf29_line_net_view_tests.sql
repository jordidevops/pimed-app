-- CF-29 D10: total_with_tax de la vista = dos passos, no un sol ROUND.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap;
SELECT plan(3);

SELECT is(
  ROUND((1.236::numeric * 81 * 1.21), 2),
  121.14::numeric,
  'un pas divergeix a 121.14'
);

SELECT is(
  ROUND(1.236::numeric * 81, 2) + ROUND(ROUND(1.236::numeric * 81, 2) * 0.21, 2),
  121.15::numeric,
  'dos passos donen 121.15'
);

SELECT is(
  data.line_net(1.236, 81, 0) + ROUND(data.line_net(1.236, 81, 0) * 21 / 100, 2),
  121.15::numeric,
  'line_net + IVA coincideix amb dos passos'
);

SELECT * FROM finish();
ROLLBACK;
