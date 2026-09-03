-- =============================================================================
-- Secret Management — correccions crítiques
--
-- Bug 1: tenant_secret_refs mancat de last_rotation_alert_at
-- Bug 2: get_storage_provider_with_secret declarada STABLE però fa INSERTs
-- Bug 3: rotate_tenant_secret deixava secrets orfes al Vault si UPDATE fallava
-- Bug 4: check_secret_rotation_due - N+1 queries + spam diari (PGMQ no dedup)
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Bug 1: Afegir last_rotation_alert_at a tenant_secret_refs
-- Sense aquesta columna check_secret_rotation_due reenviava alertes cada dia.
-- -----------------------------------------------------------------------------

ALTER TABLE data.tenant_secret_refs
  ADD COLUMN IF NOT EXISTS last_rotation_alert_at timestamptz;

-- -----------------------------------------------------------------------------
-- Bug 2: get_storage_provider_with_secret STABLE → VOLATILE
-- Cridava api.get_tenant_secret (VOLATILE, fa INSERTs). Amb STABLE el planner
-- podia reutilitzar el resultat sense re-executar la funció, duplicant logs
-- o silenciant escriptures en transaccions read-only (repliques).
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.get_storage_provider_with_secret(
  p_tenant_id   uuid    DEFAULT NULL,
  p_provider_id uuid    DEFAULT NULL
)
RETURNS TABLE (
  id                   uuid,
  provider_type        text,
  endpoint_url         text,
  bucket_name          text,
  access_key           text,
  secret_key           text,
  region               text,
  allowed_mime_types   text[],
  max_file_size_bytes  bigint,
  is_locked            boolean
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = data, vault, public
AS $$
DECLARE
  v_rec record;
  v_sk  text;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  FOR v_rec IN
    SELECT sp.*
    FROM data.storage_providers sp
    WHERE sp.is_active = true AND sp.is_verified = true
      AND (
        (p_provider_id IS NOT NULL AND sp.id = p_provider_id)
        OR (p_provider_id IS NULL AND sp.tenant_id = p_tenant_id)
      )
  LOOP
    v_sk := api.get_tenant_secret(
      v_rec.tenant_id,
      'storage_secret_key',
      'storage:' || v_rec.id::text,
      'get_storage_provider_with_secret',
      'byos_access'
    );

    IF v_sk IS NULL AND v_rec.secret_key_id IS NOT NULL THEN
      SELECT decrypted_secret INTO v_sk
      FROM vault.decrypted_secrets WHERE id = v_rec.secret_key_id;
      PERFORM data.log_secret_access(
        v_rec.tenant_id, 'storage_secret_key', 'storage:' || v_rec.id::text,
        'get_storage_provider_with_secret', 'byos_access'
      );
    END IF;

    RETURN QUERY SELECT
      v_rec.id,
      v_rec.provider_type::text,
      v_rec.endpoint_url,
      v_rec.bucket_name,
      v_rec.access_key,
      v_sk,
      v_rec.region,
      v_rec.allowed_mime_types,
      v_rec.max_file_size_bytes,
      v_rec.is_locked;
  END LOOP;
END;
$$;

-- -----------------------------------------------------------------------------
-- Bug 3: rotate_tenant_secret — cleanup si UPDATE falla post vault.create_secret
-- Sense això el nou secret quedava orfe al Vault sense cap referència.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.rotate_tenant_secret(
  p_tenant_id   uuid,
  p_secret_type text,
  p_provider    text,
  p_new_value   text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, vault, public
AS $$
DECLARE
  v_existing   data.tenant_secret_refs%ROWTYPE;
  v_new_id     uuid;
  v_vault_name text;
  v_vault_desc text;
  v_initiated  text;
BEGIN
  IF COALESCE(auth.role(), '') = 'service_role' THEN
    v_initiated := 'admin';
  ELSIF (
    data.jwt_user_tenants() ? p_tenant_id::text
    AND (data.jwt_user_tenants() -> p_tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  ) THEN
    v_initiated := auth.uid()::text;
  ELSE
    RAISE EXCEPTION 'forbidden';
  END IF;

  SELECT * INTO v_existing
  FROM data.tenant_secret_refs
  WHERE tenant_id = p_tenant_id
    AND secret_type = p_secret_type
    AND provider = p_provider
    AND rotation_status IN ('active', 'rotating');

  IF NOT FOUND THEN
    RAISE EXCEPTION 'no active secret ref found';
  END IF;

  v_vault_name := p_secret_type || '_' || p_provider || '_' || p_tenant_id::text;
  v_vault_desc := coalesce(v_existing.label, p_secret_type);

  v_new_id := vault.create_secret(p_new_value, v_vault_name, v_vault_desc);

  BEGIN
    UPDATE data.tenant_secret_refs
    SET secret_id = v_new_id,
        key_version = v_existing.key_version + 1,
        rotation_status = 'active',
        last_rotated_at = now(),
        rotation_due_at = now() + interval '365 days',
        updated_at = now()
    WHERE id = v_existing.id;
  EXCEPTION WHEN OTHERS THEN
    BEGIN
      PERFORM vault.delete_secret(v_new_id);
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'could not clean up orphaned vault secret %: %', v_new_id, SQLERRM;
    END;
    RAISE;
  END;

  BEGIN
    PERFORM vault.delete_secret(v_existing.secret_id);
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'could not delete old vault secret %: %', v_existing.secret_id, SQLERRM;
  END;

  INSERT INTO data.secret_rotation_log (
    tenant_id, secret_type, provider,
    old_key_version, new_key_version,
    rotation_type, initiated_by, completed_at, status
  ) VALUES (
    p_tenant_id, p_secret_type, p_provider,
    v_existing.key_version, v_existing.key_version + 1,
    'manual', v_initiated, now(), 'completed'
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.rotate_tenant_secret(uuid, text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION api.rotate_tenant_secret(uuid, text, text, text) TO service_role;

-- -----------------------------------------------------------------------------
-- Bug 4: check_secret_rotation_due — N+1 queries + spam diari
--
-- Problemes originals:
-- a) Loop anidado: per cada ref feia una query a tenant_members (N+1)
--    → amb 5.000 tenants = 25.000+ queries per execució de cron
-- b) PGMQ.send no és idempotent: correlationId era camp JSON, no guard
--    → enviava una notificació nova CADA DIA durant 30 dies per secret
-- c) Cap límit inferior: secrets caducats fa un any seguien generant alertes
--
-- Solució:
-- a) UPDATE RETURNING + JOIN: una sola query per obtenir refs+membres
-- b) last_rotation_alert_at: guard de 7 dies per ref (similar a platform)
-- c) BETWEEN now()-60d AND now()+30d: finestra acotada
-- d) to_char(now(), 'IYYY-IW') al correlationId: unicitat setmanal per PGMQ
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION data.check_secret_rotation_due()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_row      record;
  v_platform record;
  v_sent     integer := 0;
BEGIN
  FOR v_row IN
    WITH due_refs AS (
      UPDATE data.tenant_secret_refs
      SET last_rotation_alert_at = now(), updated_at = now()
      WHERE rotation_status = 'active'
        AND rotation_due_at IS NOT NULL
        AND rotation_due_at BETWEEN now() - interval '60 days' AND now() + interval '30 days'
        AND (last_rotation_alert_at IS NULL
             OR last_rotation_alert_at < now() - interval '7 days')
      RETURNING tenant_id, secret_type, provider, label, rotation_due_at
    )
    SELECT
      r.tenant_id, r.secret_type, r.provider, r.label, r.rotation_due_at,
      m.user_id
    FROM due_refs r
    JOIN data.tenant_members m
      ON m.tenant_id = r.tenant_id
     AND m.site_id IS NULL
     AND m.role IN ('owner', 'manager')
     AND m.is_active = true
  LOOP
    PERFORM data.enqueue_notification_dispatch(jsonb_build_object(
      'tenantId',      v_row.tenant_id,
      'eventType',     'SECRET_ROTATION_DUE',
      'correlationId', 'secret_rotation_due:'
                       || v_row.tenant_id::text || ':' || v_row.secret_type || ':'
                       || v_row.provider || ':' || v_row.user_id::text
                       || ':' || to_char(now(), 'IYYY-IW'),
      'recipient',     jsonb_build_object('kind', 'tenant_member', 'userId', v_row.user_id),
      'entityType',    'system',
      'payload',       jsonb_build_object(
        'secret_type',     v_row.secret_type,
        'provider',        v_row.provider,
        'label',           coalesce(v_row.label, v_row.secret_type),
        'rotation_due_at', v_row.rotation_due_at,
        'deep_link',       '/settings/secrets',
        'message',         'Un secret de configuració caduca aviat. Revisa Configuració → Secrets.'
      )
    ));
    v_sent := v_sent + 1;
  END LOOP;

  -- Plataforma: marcar alerta per admin UI
  FOR v_platform IN
    SELECT id
    FROM data.platform_secret_registry
    WHERE rotation_status = 'active'
      AND rotation_due_at IS NOT NULL
      AND rotation_due_at BETWEEN now() - interval '60 days' AND now() + interval '30 days'
      AND (last_rotation_alert_at IS NULL
           OR last_rotation_alert_at < now() - interval '7 days')
  LOOP
    UPDATE data.platform_secret_registry
    SET last_rotation_alert_at = now(), updated_at = now()
    WHERE id = v_platform.id;
    v_sent := v_sent + 1;
  END LOOP;

  RETURN v_sent;
END;
$$;

REVOKE ALL ON FUNCTION data.check_secret_rotation_due() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.check_secret_rotation_due() TO service_role;
