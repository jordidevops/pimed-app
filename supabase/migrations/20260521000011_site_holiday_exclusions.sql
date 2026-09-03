-- =============================================================================
-- Migration: 20260521000011_site_holiday_exclusions.sql
--
-- Propòsit: Permetre que un centre desactivi festius concrets d'un calendari
--           heretat del tenant sense modificar el calendari original.
--
-- Patró:
--   · Un site pot marcar N holidays com a "exclosos" → la jornada s'aplica igualment.
--   · Les exclusions existeixen a nivell de site+holiday; no afecten altres sites.
--   · L'accés d'escriptura és exclusiu via RPC SECURITY DEFINER (labor_calendar.manage).
--
-- Taules / Vistes:
--   · data.site_holiday_exclusions
--   · api.site_holiday_exclusions  (view security_invoker)
--
-- RPCs:
--   · api.toggle_site_holiday_exclusion(p_site_id, p_holiday_id, p_is_excluded)
-- =============================================================================


-- =============================================================================
-- 1. Taula: data.site_holiday_exclusions
-- =============================================================================

CREATE TABLE data.site_holiday_exclusions (
  id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  site_id     uuid        NOT NULL REFERENCES data.sites(id)    ON DELETE CASCADE,
  holiday_id  uuid        NOT NULL REFERENCES data.holidays(id) ON DELETE CASCADE,
  created_by  uuid                 REFERENCES auth.users(id)   ON DELETE SET NULL,
  created_at  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_site_holiday_excl UNIQUE (site_id, holiday_id)
);

COMMENT ON TABLE data.site_holiday_exclusions IS
  'Festius desactivats per a un centre concret. '
  'Permet que un centre ignori festius heretats del tenant sense canviar el calendari global.';


-- =============================================================================
-- 2. RLS
-- =============================================================================

ALTER TABLE data.site_holiday_exclusions ENABLE ROW LEVEL SECURITY;

-- SELECT: membre actiu del tenant que posseeix el site
CREATE POLICY she_select ON data.site_holiday_exclusions FOR SELECT
  USING (EXISTS (
    SELECT 1
    FROM data.sites s
    JOIN data.tenant_members tm
      ON tm.tenant_id  = s.tenant_id
     AND tm.user_id    = auth.uid()
     AND tm.is_active  = true
    WHERE s.id = site_id
  ));

-- INSERT/UPDATE/DELETE: només via RPC (SECURITY DEFINER). No GRANT directe.


-- =============================================================================
-- 3. Grants data.*
-- =============================================================================

GRANT SELECT ON data.site_holiday_exclusions TO authenticated;
GRANT ALL    ON data.site_holiday_exclusions TO service_role;


-- =============================================================================
-- 4. Vista api.site_holiday_exclusions
-- =============================================================================

CREATE OR REPLACE VIEW api.site_holiday_exclusions
  WITH (security_invoker = true)
AS
SELECT
  she.id,
  she.site_id,
  she.holiday_id,
  she.created_at
FROM data.site_holiday_exclusions she;

GRANT SELECT ON api.site_holiday_exclusions TO authenticated;
GRANT SELECT ON api.site_holiday_exclusions TO service_role;


-- =============================================================================
-- 5. RPC: api.toggle_site_holiday_exclusion
-- =============================================================================

CREATE OR REPLACE FUNCTION api.toggle_site_holiday_exclusion(
  p_site_id    uuid,
  p_holiday_id uuid,
  p_is_excluded boolean
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_tenant_id uuid;
BEGIN
  IF p_site_id IS NULL OR p_holiday_id IS NULL THEN
    RAISE EXCEPTION 'invalid_params: site_id and holiday_id are required'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  -- Obtenir tenant del site
  SELECT s.tenant_id INTO v_tenant_id
  FROM data.sites s
  WHERE s.id = p_site_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'not_found: site_id % not found', p_site_id
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  -- Verificar permís
  IF NOT data.jwt_has_permission(v_tenant_id, 'labor_calendar.manage') THEN
    RAISE EXCEPTION 'insufficient_privilege: labor_calendar.manage required'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_is_excluded THEN
    -- Afegir exclusió
    INSERT INTO data.site_holiday_exclusions (site_id, holiday_id, created_by)
    VALUES (p_site_id, p_holiday_id, auth.uid())
    ON CONFLICT (site_id, holiday_id) DO NOTHING;

    PERFORM data.log_audit_event(
      v_tenant_id,
      COALESCE(auth.uid(), NULL),
      p_site_id,
      'HOLIDAY_EXCLUDED',
      'site_holiday_exclusion',
      p_holiday_id,
      jsonb_build_object('site_id', p_site_id, 'holiday_id', p_holiday_id)
    );
  ELSE
    -- Eliminar exclusió
    DELETE FROM data.site_holiday_exclusions
    WHERE site_id = p_site_id AND holiday_id = p_holiday_id;

    PERFORM data.log_audit_event(
      v_tenant_id,
      COALESCE(auth.uid(), NULL),
      p_site_id,
      'HOLIDAY_INCLUDED',
      'site_holiday_exclusion',
      p_holiday_id,
      jsonb_build_object('site_id', p_site_id, 'holiday_id', p_holiday_id)
    );
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION api.toggle_site_holiday_exclusion(uuid, uuid, boolean)
  TO authenticated, service_role;
