-- =============================================================================
-- Migració: 20260515000007_request_domain_check_rpc.sql
-- Propòsit: RPC que permet al tenant demanar una verificació DNS immediata
--           d'un domini propi, sense esperar el cicle de 5 min del pg_cron.
--
-- Conté:
--   1. api.request_domain_check(p_domain_id uuid) — SECURITY INVOKER
--      · Valida que el domini pertany al tenant actiu (via RLS implícita)
--      · Per dominis failed: reset last_checked_at + failure_reason
--        perquè el worker els torni a processar
--      · Invoca data.invoke_domain_verification_worker() per activar la
--        Edge Function process-domain-verification immediatament
--
-- Notes:
--   · Per dominis pending/dns_verified: el worker ja els processa normalment,
--     aquesta crida simplement accelera el cicle.
--   · El worker fa servei graceful degradation: si els Vault secrets no estan
--     configurats (local dev sense pg_net/vault), retorna -1/-2 sense error.
--   · No s'exposa directament si el domini és verificat o no: la resposta
--     és void per evitar oracle de verificació.
--
-- Dependències:
--   · data.public_domains           (20260513000001_public_portal_core.sql)
--   · data.invoke_domain_verification_worker (20260514000001)
-- =============================================================================

CREATE OR REPLACE FUNCTION api.request_domain_check(p_domain_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY INVOKER
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
