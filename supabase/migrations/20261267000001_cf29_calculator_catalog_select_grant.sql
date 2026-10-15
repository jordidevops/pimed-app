-- CF-29: api.calculator_catalog usa security_invoker=true → cal GRANT SELECT a data.*
-- Sense això PostgREST retorna 42501 permission denied for table calculator_catalog.

GRANT SELECT ON data.calculator_catalog TO authenticated;
