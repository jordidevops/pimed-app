-- Inherit commercial_regime from contact on INSERT: column DEFAULT was applied
-- before BEFORE INSERT, so the trigger never saw NULL. Drop default.

ALTER TABLE data.projects
  ALTER COLUMN commercial_regime DROP DEFAULT;

CREATE OR REPLACE FUNCTION data.trg_projects_default_commercial_regime()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_is_consumer boolean;
  v_source_regime text;
BEGIN
  -- Follow-up WOs inherit regime from source and always execute (not assessment).
  IF NEW.source_project_id IS NOT NULL THEN
    SELECT sp.commercial_regime
    INTO v_source_regime
    FROM data.projects sp
    WHERE sp.id = NEW.source_project_id;
    IF v_source_regime IS NOT NULL THEN
      NEW.commercial_regime := v_source_regime;
    END IF;
    NEW.service_mode := 'execute';
  END IF;

  IF NEW.commercial_regime IS NULL THEN
    IF NEW.client_id IS NULL THEN
      NEW.commercial_regime := 'contractual';
    ELSE
      SELECT COALESCE(c.is_consumer, c.kind = 'person', true)
      INTO v_is_consumer
      FROM data.contacts c
      WHERE c.id = NEW.client_id
        AND c.tenant_id = NEW.tenant_id;
      NEW.commercial_regime := CASE
        WHEN COALESCE(v_is_consumer, true) THEN 'consumer'
        ELSE 'contractual'
      END;
    END IF;
  END IF;

  IF NEW.service_mode IS NULL THEN
    NEW.service_mode := 'execute';
  END IF;

  RETURN NEW;
END;
$$;

NOTIFY pgrst, 'reload schema';
