-- =============================================================================
-- EX-04.5 follow-up — append-only anomaly_codes sense trencar immutabilitat
-- =============================================================================
-- RDL 8/2019: no es poden mutar camps de negoci del punch.
-- Sí es permet afegir codis d'anomalia (superset) detectats després de l'INSERT
-- (p.ex. WRONG_SCHEDULED_LOCATION a l'estació).

CREATE OR REPLACE FUNCTION data.trg_immutable_time_punches()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
BEGIN
  IF TG_OP = 'UPDATE' THEN
    -- GDPR: anonimització geo (E5)
    IF OLD.geo_anonymized_at IS NULL
       AND NEW.geo_anonymized_at IS NOT NULL
       AND NEW.geo_lat IS NULL AND NEW.geo_lng IS NULL
       AND NEW.geo IS NULL
       AND NEW.tenant_id = OLD.tenant_id
       AND NEW.site_id = OLD.site_id
       AND NEW.employee_id = OLD.employee_id
       AND NEW.punch_type = OLD.punch_type
       AND NEW.occurred_at = OLD.occurred_at
       AND NEW.client_op_id = OLD.client_op_id
    THEN
      RETURN NEW;
    END IF;

    -- Append-only anomalies (camps de negoci intactes)
    IF NEW.tenant_id = OLD.tenant_id
       AND NEW.site_id IS NOT DISTINCT FROM OLD.site_id
       AND NEW.employee_id = OLD.employee_id
       AND NEW.device_id IS NOT DISTINCT FROM OLD.device_id
       AND NEW.location_id IS NOT DISTINCT FROM OLD.location_id
       AND NEW.client_op_id IS NOT DISTINCT FROM OLD.client_op_id
       AND NEW.punch_type = OLD.punch_type
       AND NEW.occurred_at = OLD.occurred_at
       AND NEW.received_at IS NOT DISTINCT FROM OLD.received_at
       AND NEW.source IS NOT DISTINCT FROM OLD.source
       AND NEW.notes IS NOT DISTINCT FROM OLD.notes
       AND NEW.pause_type IS NOT DISTINCT FROM OLD.pause_type
       AND NEW.geo_lat IS NOT DISTINCT FROM OLD.geo_lat
       AND NEW.geo_lng IS NOT DISTINCT FROM OLD.geo_lng
       AND NEW.geo IS NOT DISTINCT FROM OLD.geo
       AND NEW.geo_anonymized_at IS NOT DISTINCT FROM OLD.geo_anonymized_at
       AND NEW.location_name_snapshot IS NOT DISTINCT FROM OLD.location_name_snapshot
       AND NEW.device_name_snapshot IS NOT DISTINCT FROM OLD.device_name_snapshot
       AND COALESCE(NEW.anomaly_codes, ARRAY[]::text[]) @> COALESCE(OLD.anomaly_codes, ARRAY[]::text[])
    THEN
      RETURN NEW;
    END IF;
  END IF;

  RAISE EXCEPTION 'time_punches_immutable: UPDATE i DELETE no permesos (RDL 8/2019)'
    USING ERRCODE = 'check_violation';
END;
$$;

COMMENT ON FUNCTION data.trg_immutable_time_punches() IS
  'Immutabilitat punch: bloqueja mutacions; permet anonimització geo i append-only anomaly_codes.';
