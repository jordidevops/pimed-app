-- =============================================================================
-- Maps JS client error telemetry (per tenant)
-- =============================================================================

CREATE TABLE IF NOT EXISTS data.maps_js_client_errors (
  tenant_id uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  category  text NOT NULL,
  code       text NOT NULL,
  origin     text NOT NULL,
  first_seen_at timestamptz NOT NULL DEFAULT now(),
  last_seen_at  timestamptz NOT NULL DEFAULT now(),
  count          bigint NOT NULL DEFAULT 0,
  PRIMARY KEY (tenant_id, category, code, origin)
);

CREATE INDEX IF NOT EXISTS idx_maps_js_client_errors_last_seen
  ON data.maps_js_client_errors (last_seen_at DESC);

GRANT SELECT ON TABLE data.maps_js_client_errors TO prisma_admin;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE data.maps_js_client_errors TO service_role;

-- -----------------------------------------------------------------------------
-- RPC: record_maps_js_client_error (called by authenticated clients)
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.record_maps_js_client_error(
  p_tenant_id uuid,
  p_category  text,
  p_code      text,
  p_origin    text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_user_id uuid := auth.uid();
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'unauthenticated';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM data.tenant_members tm
    WHERE tm.tenant_id = p_tenant_id
      AND tm.user_id = v_user_id
      AND tm.is_active = true
    LIMIT 1
  ) THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  INSERT INTO data.maps_js_client_errors (tenant_id, category, code, origin, count)
  VALUES (p_tenant_id, p_category, p_code, p_origin, 1)
  ON CONFLICT (tenant_id, category, code, origin) DO UPDATE SET
    count = data.maps_js_client_errors.count + 1,
    last_seen_at = now();

  RETURN jsonb_build_object('ok', true);
END;
$$;

REVOKE ALL ON FUNCTION api.record_maps_js_client_error(uuid, text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.record_maps_js_client_error(uuid, text, text, text) TO authenticated;

