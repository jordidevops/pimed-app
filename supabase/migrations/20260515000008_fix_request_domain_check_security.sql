-- =============================================================================
-- Migració: 20260515000008_fix_request_domain_check_security.sql
-- Propòsit: Canviar api.request_domain_check a SECURITY DEFINER perquè pugui
--           cridar data.invoke_domain_verification_worker() (helper intern
--           de pg_cron sense GRANT a authenticated).
--
--           SECURITY INVOKER no funcionava perquè invoke_domain_verification_worker
--           no té EXECUTE grant per a authenticated. Amb SECURITY DEFINER la
--           funció s'executa amb els privilegis del propietari (postgres) però
--           data.active_tenant_id() segueix llegint del JWT de la sessió
--           del caller — la validació de pertinença al tenant és intact.
-- =============================================================================

CREATE OR REPLACE FUNCTION api.request_domain_check(p_domain_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_status    text;
BEGIN
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'missing_tenant_context'
      USING HINT = 'Envia la capçalera x-tenant-id amb el UUID del tenant.';
  END IF;

  SELECT status INTO v_status
  FROM data.public_domains
  WHERE id        = p_domain_id
    AND tenant_id = v_tenant_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'not_found'
      USING HINT = 'El domini no existeix o no pertany al tenant actiu.';
  END IF;

  -- Per dominis fallits: reseteja perquè el worker els reprengui
  IF v_status = 'failed' THEN
    UPDATE data.public_domains
    SET
      last_checked_at = NULL,
      failure_reason  = NULL,
      status          = 'pending'
    WHERE id        = p_domain_id
      AND tenant_id = v_tenant_id;
  END IF;

  -- Activa el worker de verificació (graceful degradation en local dev)
  PERFORM data.invoke_domain_verification_worker(20);
END;
$$;

GRANT EXECUTE ON FUNCTION api.request_domain_check(uuid) TO authenticated;
