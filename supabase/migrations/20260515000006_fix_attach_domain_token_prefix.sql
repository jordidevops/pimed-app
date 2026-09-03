-- =============================================================================
-- Migració: 20260515000006_fix_attach_domain_token_prefix.sql
-- Propòsit: Actualitzar api.attach_public_domain per usar un prefix de token
--           de verificació neutral (portal-verify=) en lloc del prefix antic
--           amb marca hardcoded.
-- Afecta:
--   · api.attach_public_domain (api schema)
-- Dependències:
--   · 20260513000002_public_portal_rls.sql (definició original)
-- =============================================================================

CREATE OR REPLACE FUNCTION api.attach_public_domain(
  p_public_site_id  uuid,
  p_domain          text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = data, public
AS $$
DECLARE
  v_id               uuid;
  v_tenant_id        uuid := data.active_tenant_id();
  v_verification_tok text;
BEGIN
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'missing_tenant_context'
      USING HINT = 'Envia la capçalera x-tenant-id amb el UUID del tenant.';
  END IF;

  -- Valida que el public_site pertany al tenant actiu
  IF NOT EXISTS (
    SELECT 1 FROM data.public_sites
    WHERE id = p_public_site_id AND tenant_id = v_tenant_id
  ) THEN
    RAISE EXCEPTION 'not_found'
      USING HINT = 'El public_site no existeix o no pertany al tenant actiu.';
  END IF;

  -- Genera token: prefix neutral 'portal-verify=' + hash sha256 determinista (site+domain)
  v_verification_tok := 'portal-verify='
    || encode(
         extensions.digest(
           p_public_site_id::text || '.' || lower(trim(p_domain)),
           'sha256'
         ),
         'hex'
       );

  INSERT INTO data.public_domains (
    public_site_id,
    tenant_id,
    domain,
    status,
    verification_token
  ) VALUES (
    p_public_site_id,
    v_tenant_id,
    lower(trim(p_domain)),
    'pending',
    v_verification_tok
  )
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

GRANT EXECUTE ON FUNCTION api.attach_public_domain(uuid, text) TO authenticated;
