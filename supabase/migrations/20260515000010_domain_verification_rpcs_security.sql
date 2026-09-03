-- =============================================================================
-- Migració: 20260515000010_domain_verification_rpcs_security.sql
-- Propòsit : Afegir RPCs api.* per al worker de verificació de dominis i
--            eliminar la necessitat d'exposar l'esquema data a PostgREST.
--
-- Problema resolt:
--   La migració 20260515000009 va afegir data a config.toml schemas per
--   permetre createAdminClient().schema("data").from(...) al worker.
--   Això exposava TOTES les taules de data.* com a endpoints REST directes,
--   bypassing la capa api.* i permetent accés directe a authenticated/anon.
--
-- Solució:
--   1. Dues RPCs SECURITY DEFINER a api.* per encapsular les operacions
--      del worker (fetch batch + update individual).
--   2. REVOKE d'anon i authenticated; GRANT exclusivament a service_role.
--   3. Amb això, config.toml pot tornar a schemas = ["api", "graphql_public"].
--
-- Conté:
--   1. api.fetch_domains_for_verification  — retorna batch de dominis pendents
--   2. api.update_domain_check_result      — actualitza estat/camps via JSONB patch
--   3. GRANTs i REVOKEs de seguretat
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. api.fetch_domains_for_verification
--
-- Retorna el batch de dominis que necessiten verificació:
--   - status IN ('pending', 'dns_verified')
--   - status = 'failed' AND (last_checked_at IS NULL OR fa > 1h)
-- Ordenat per last_checked_at ASC NULLS FIRST (els mai comprovats primer).
-- Limitat a LEAST(p_batch_size, 50) per seguretat.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.fetch_domains_for_verification(
  p_batch_size integer DEFAULT 20
)
RETURNS TABLE (
  id                  uuid,
  public_site_id      uuid,
  tenant_id           uuid,
  domain              text,
  status              text,
  verification_token  text,
  check_count         integer,
  last_checked_at     timestamptz,
  failure_reason      text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = data, public
AS $$
  SELECT
    id,
    public_site_id,
    tenant_id,
    domain,
    status::text,
    verification_token,
    check_count,
    last_checked_at,
    failure_reason
  FROM data.public_domains
  WHERE status IN ('pending', 'dns_verified')
     OR (
       status = 'failed'
       AND (last_checked_at IS NULL OR last_checked_at < now() - interval '1 hour')
     )
  ORDER BY last_checked_at ASC NULLS FIRST
  LIMIT LEAST(p_batch_size, 50);
$$;

REVOKE ALL   ON FUNCTION api.fetch_domains_for_verification(integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.fetch_domains_for_verification(integer) TO service_role;

-- ---------------------------------------------------------------------------
-- 2. api.update_domain_check_result
--
-- Actualitza camps d'un domini via JSONB patch. Camps suportats:
--   status             text         — 'pending','dns_verified','ssl_active','failed'
--   check_count        int
--   failure_reason     text | null  — JSON null elimina el valor anterior
--   ssl_provisioned_at timestamptz | null
--
-- last_checked_at s'actualitza SEMPRE a now() (no cal passar-lo).
--
-- Semàntica JSONB patch:
--   - Clau present al JSON → actualitza el camp (fins i tot si el valor és null)
--   - Clau absent al JSON → el camp no es modifica
--
-- Exemples:
--   { "status": "dns_verified", "check_count": 0, "failure_reason": null }
--     → status = 'dns_verified', check_count = 0, failure_reason = NULL (netejat)
--   { "check_count": 5, "failure_reason": "DNS not found" }
--     → només actualitza check_count i failure_reason; status no canvia
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.update_domain_check_result(
  p_id      uuid,
  p_updates jsonb
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
BEGIN
  UPDATE data.public_domains
  SET
    status = CASE
      WHEN p_updates ? 'status'
        THEN p_updates->>'status'
      ELSE status::text
    END,
    check_count = CASE
      WHEN p_updates ? 'check_count'
        THEN (p_updates->>'check_count')::integer
      ELSE check_count
    END,
    -- Semàntica intencional: clau present amb valor JSON null → SQL NULL (neteja el camp)
    failure_reason = CASE
      WHEN p_updates ? 'failure_reason'
        THEN p_updates->>'failure_reason'
      ELSE failure_reason
    END,
    ssl_provisioned_at = CASE
      WHEN p_updates ? 'ssl_provisioned_at'
        THEN (p_updates->>'ssl_provisioned_at')::timestamptz
      ELSE ssl_provisioned_at
    END,
    last_checked_at = now()
  WHERE id = p_id;
END;
$$;

REVOKE ALL    ON FUNCTION api.update_domain_check_result(uuid, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.update_domain_check_result(uuid, jsonb) TO service_role;

-- ---------------------------------------------------------------------------
-- Comentari de context per a futures revisions
-- ---------------------------------------------------------------------------
-- IMPORTANT: config.toml ha de tenir schemas = ["api", "graphql_public"]
-- (sense "data"). Les RPCs anteriors basten per al worker.
-- Els GRANTs de la migració 20260515000009 (GRANT ... ON data.public_domains
-- TO service_role) queden obsolets però inofensius: service_role pot accedir
-- a data.* via SQL directe (Prisma/admin-portal) però JA NO via PostgREST
-- un cop "data" és tret de schemas.
-- Els GRANTs a anon/authenticated sobre data.public_sites/pages (migració
-- 20260513000002) són necessaris per a les vistes api.* amb security_invoker.
-- Sense "data" a schemas, anon/authenticated NO poden adreçar data.* via REST.
