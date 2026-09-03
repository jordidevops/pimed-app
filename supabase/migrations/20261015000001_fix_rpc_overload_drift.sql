-- Reparació drift: overloads RPC ambigus deixats per migracions additives anteriors.
-- Idempotent: segur en BD neta i en entorns amb drift parcial.

DROP FUNCTION IF EXISTS api.record_time_punch(
  uuid, uuid, text, timestamptz, jsonb, text, text, text,
  uuid, text, boolean, boolean, boolean, text, jsonb
);

DROP FUNCTION IF EXISTS api.log_employee_portal_access_event(
  uuid, uuid, uuid, text, smallint, text, inet, text
);
