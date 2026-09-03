-- Actualitzar api.tenant_pause_configs per incloure els camps nous afegits
-- a data.tenant_pause_configs (site_id, default_duration_min, requires_justification, archetype_key).
-- list_pause_configs retorna SETOF api.tenant_pause_configs → cal que les columnes coincideixin.

-- CREATE OR REPLACE VIEW pot afegir columnes noves només al final.
CREATE OR REPLACE VIEW api.tenant_pause_configs AS
SELECT
  id,
  tenant_id,
  key,
  label_i18n,
  counts_as_work,
  max_duration_minutes,
  is_active,
  sort_order,
  created_at,
  updated_at,
  site_id,
  default_duration_min,
  requires_justification
FROM data.tenant_pause_configs;

-- Tornem a crear list_pause_configs perquè el tipus de retorn ha canviat.
CREATE OR REPLACE FUNCTION api.list_pause_configs()
RETURNS SETOF api.tenant_pause_configs
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = api, data, public
AS $$
  SELECT
    id, tenant_id, key, label_i18n, counts_as_work, max_duration_minutes,
    is_active, sort_order, created_at, updated_at,
    site_id, default_duration_min, requires_justification
  FROM data.tenant_pause_configs
  WHERE tenant_id = data.active_tenant_id()
    AND is_active = true
  ORDER BY sort_order, key;
$$;

GRANT EXECUTE ON FUNCTION api.list_pause_configs() TO authenticated;

-- Tornem a crear upsert_pause_config: cal eliminar l'overload vell primer.
DROP FUNCTION IF EXISTS api.upsert_pause_config(
  text, jsonb, boolean, integer, boolean, integer
);

CREATE OR REPLACE FUNCTION api.upsert_pause_config(
  p_key                  text,
  p_label_i18n           jsonb,
  p_counts_as_work       boolean,
  p_max_duration_minutes integer  DEFAULT NULL,
  p_is_active            boolean  DEFAULT true,
  p_sort_order           integer  DEFAULT 0,
  p_default_duration_min integer  DEFAULT NULL,
  p_requires_justification boolean DEFAULT false,
  p_site_id              uuid     DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = api, data, public
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_id        uuid;
BEGIN
  IF NOT data.jwt_has_permission(v_tenant_id, 'attendance.manage') THEN
    RAISE EXCEPTION 'insufficient_privilege: attendance.manage requerit';
  END IF;

  INSERT INTO data.tenant_pause_configs (
    tenant_id, site_id, key, label_i18n,
    counts_as_work, max_duration_minutes,
    default_duration_min, requires_justification,
    is_active, sort_order
  ) VALUES (
    v_tenant_id, p_site_id, p_key, p_label_i18n,
    p_counts_as_work, p_max_duration_minutes,
    p_default_duration_min, p_requires_justification,
    p_is_active, p_sort_order
  )
  ON CONFLICT (tenant_id, key) DO UPDATE SET
    label_i18n             = EXCLUDED.label_i18n,
    counts_as_work         = EXCLUDED.counts_as_work,
    max_duration_minutes   = EXCLUDED.max_duration_minutes,
    default_duration_min   = EXCLUDED.default_duration_min,
    requires_justification = EXCLUDED.requires_justification,
    is_active              = EXCLUDED.is_active,
    sort_order             = EXCLUDED.sort_order,
    updated_at             = now()
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

GRANT EXECUTE ON FUNCTION api.upsert_pause_config TO authenticated;
