-- list_shift_openings soft-expires rows with UPDATE before SELECT.
-- STABLE forbids writes → 0A000 "UPDATE is not allowed in a non-volatile function".
ALTER FUNCTION api.list_shift_openings(uuid, date, date, text) VOLATILE;
