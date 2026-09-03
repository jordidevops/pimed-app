-- Admin UI + sync automàtic /models -> needs_review

-- ---------------------------------------------------------------------------
-- register_ai_models_for_review (service_role)
-- Inserta models nous detectats per sync amb needs_review=true.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.register_ai_models_for_review(
  p_provider text,
  p_models   text[],
  p_source   text DEFAULT 'provider_sync'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_provider      data.ai_provider;
  v_source        text := COALESCE(NULLIF(trim(p_source), ''), 'provider_sync');
  v_received      integer := 0;
  v_inserted      integer := 0;
  v_revived       integer := 0;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  v_provider := api.parse_ai_provider(p_provider);

  WITH incoming AS (
    SELECT DISTINCT nullif(trim(model_id), '') AS model_id
    FROM unnest(COALESCE(p_models, '{}'::text[])) AS u(model_id)
    WHERE nullif(trim(model_id), '') IS NOT NULL
  ), inserted AS (
    INSERT INTO data.ai_model_capabilities (
      provider,
      model_id,
      needs_review,
      source,
      updated_at
    )
    SELECT
      v_provider,
      i.model_id,
      true,
      v_source,
      now()
    FROM incoming i
    ON CONFLICT (provider, model_id) DO NOTHING
    RETURNING 1
  ), revived AS (
    UPDATE data.ai_model_capabilities c
    SET deprecated_at = NULL,
        updated_at = now()
    FROM incoming i
    WHERE c.provider = v_provider
      AND c.model_id = i.model_id
      AND c.deprecated_at IS NOT NULL
    RETURNING 1
  )
  SELECT
    (SELECT COUNT(*) FROM incoming),
    (SELECT COUNT(*) FROM inserted),
    (SELECT COUNT(*) FROM revived)
  INTO v_received, v_inserted, v_revived;

  RETURN jsonb_build_object(
    'provider', v_provider,
    'received', v_received,
    'inserted', v_inserted,
    'revived', v_revived
  );
END;
$$;

REVOKE ALL ON FUNCTION api.register_ai_models_for_review(text, text[], text) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.register_ai_models_for_review(text, text[], text) FROM authenticated;
REVOKE ALL ON FUNCTION api.register_ai_models_for_review(text, text[], text) FROM anon;
GRANT EXECUTE ON FUNCTION api.register_ai_models_for_review(text, text[], text) TO service_role;

-- ---------------------------------------------------------------------------
-- persist_tenant_ai_provider_models (service_role) + register capabilities
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.persist_tenant_ai_provider_models(
  p_tenant_id uuid,
  p_provider  text,
  p_models    text[]
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_provider      data.ai_provider;
  v_sync_stats    jsonb := '{}'::jsonb;
BEGIN
  v_provider := api.parse_ai_provider(p_provider);

  INSERT INTO data.tenant_ai_provider_config (tenant_id, provider, model, available_models, last_models_sync_at)
  VALUES (
    p_tenant_id,
    v_provider,
    api.ai_provider_default_model(v_provider),
    COALESCE(p_models, '{}'::text[]),
    now()
  )
  ON CONFLICT (tenant_id, provider) DO UPDATE
    SET available_models = COALESCE(EXCLUDED.available_models, '{}'::text[]),
        last_models_sync_at = now();

  SELECT api.register_ai_models_for_review(v_provider::text, COALESCE(p_models, '{}'::text[]), 'tenant_sync')
  INTO v_sync_stats;

  RETURN jsonb_build_object(
    'success', true,
    'provider', v_provider,
    'models', COALESCE(p_models, '{}'::text[]),
    'synced_at', now(),
    'capabilities_sync', v_sync_stats
  );
END;
$$;

REVOKE ALL ON FUNCTION api.persist_tenant_ai_provider_models(uuid, text, text[]) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.persist_tenant_ai_provider_models(uuid, text, text[]) FROM authenticated;
REVOKE ALL ON FUNCTION api.persist_tenant_ai_provider_models(uuid, text, text[]) FROM anon;
GRANT EXECUTE ON FUNCTION api.persist_tenant_ai_provider_models(uuid, text, text[]) TO service_role;

-- ---------------------------------------------------------------------------
-- persist_platform_ai_provider_models (service_role) + register capabilities
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.persist_platform_ai_provider_models(
  p_provider text,
  p_models   text[]
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_provider      data.ai_provider;
  v_sync_stats    jsonb := '{}'::jsonb;
BEGIN
  v_provider := api.parse_ai_provider(p_provider);

  UPDATE data.platform_ai_defaults
  SET
    available_models = COALESCE(p_models, '{}'::text[]),
    last_models_sync_at = now(),
    updated_at = now()
  WHERE provider = v_provider;

  SELECT api.register_ai_models_for_review(v_provider::text, COALESCE(p_models, '{}'::text[]), 'platform_sync')
  INTO v_sync_stats;

  RETURN jsonb_build_object(
    'success', true,
    'provider', v_provider,
    'models', COALESCE(p_models, '{}'::text[]),
    'synced_at', now(),
    'capabilities_sync', v_sync_stats
  );
END;
$$;

REVOKE ALL ON FUNCTION api.persist_platform_ai_provider_models(text, text[]) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.persist_platform_ai_provider_models(text, text[]) FROM authenticated;
REVOKE ALL ON FUNCTION api.persist_platform_ai_provider_models(text, text[]) FROM anon;
GRANT EXECUTE ON FUNCTION api.persist_platform_ai_provider_models(text, text[]) TO service_role;

-- ---------------------------------------------------------------------------
-- get_ai_model_capabilities_admin (service_role)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.get_ai_model_capabilities_admin(
  p_provider           text DEFAULT NULL,
  p_only_needs_review  boolean DEFAULT false,
  p_include_deprecated boolean DEFAULT true
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_provider data.ai_provider := NULL;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  IF p_provider IS NOT NULL AND NULLIF(trim(p_provider), '') IS NOT NULL THEN
    v_provider := api.parse_ai_provider(p_provider);
  END IF;

  RETURN COALESCE((
    SELECT jsonb_agg(
      jsonb_build_object(
        'provider', c.provider,
        'model_id', c.model_id,
        'vision', c.vision,
        'tools', c.tools,
        'tools_with_vision', c.tools_with_vision,
        'streaming', c.streaming,
        'max_image_size_mb', c.max_image_size_mb,
        'supported_image_mimes', c.supported_image_mimes,
        'max_file_size_mb', c.max_file_size_mb,
        'supported_file_mimes', c.supported_file_mimes,
        'context_window', c.context_window,
        'deprecated_at', c.deprecated_at,
        'needs_review', c.needs_review,
        'source', c.source,
        'updated_at', c.updated_at
      )
      ORDER BY c.provider, c.model_id
    )
    FROM data.ai_model_capabilities c
    WHERE (v_provider IS NULL OR c.provider = v_provider)
      AND (NOT p_only_needs_review OR c.needs_review)
      AND (p_include_deprecated OR c.deprecated_at IS NULL)
  ), '[]'::jsonb);
END;
$$;

REVOKE ALL ON FUNCTION api.get_ai_model_capabilities_admin(text, boolean, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.get_ai_model_capabilities_admin(text, boolean, boolean) FROM authenticated;
REVOKE ALL ON FUNCTION api.get_ai_model_capabilities_admin(text, boolean, boolean) FROM anon;
GRANT EXECUTE ON FUNCTION api.get_ai_model_capabilities_admin(text, boolean, boolean) TO service_role;

-- ---------------------------------------------------------------------------
-- upsert_ai_model_capability_admin (service_role)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.upsert_ai_model_capability_admin(
  p_provider              text,
  p_model_id              text,
  p_vision                boolean DEFAULT false,
  p_tools                 boolean DEFAULT true,
  p_tools_with_vision     boolean DEFAULT false,
  p_streaming             boolean DEFAULT true,
  p_max_image_size_mb     integer DEFAULT 5,
  p_supported_image_mimes text[] DEFAULT ARRAY['image/jpeg', 'image/png', 'image/webp'],
  p_max_file_size_mb      integer DEFAULT 10,
  p_supported_file_mimes  text[] DEFAULT ARRAY['application/pdf'],
  p_context_window        integer DEFAULT NULL,
  p_deprecated            boolean DEFAULT false,
  p_needs_review          boolean DEFAULT false,
  p_source                text DEFAULT 'admin'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_provider data.ai_provider;
  v_model_id text := NULLIF(trim(p_model_id), '');
  v_source   text := COALESCE(NULLIF(trim(p_source), ''), 'admin');
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  v_provider := api.parse_ai_provider(p_provider);

  IF v_model_id IS NULL THEN
    RAISE EXCEPTION 'model_id is required';
  END IF;

  IF p_max_image_size_mb IS NULL OR p_max_image_size_mb < 1 OR p_max_image_size_mb > 50 THEN
    RAISE EXCEPTION 'max_image_size_mb out of range (1..50)';
  END IF;

  IF p_max_file_size_mb IS NULL OR p_max_file_size_mb < 1 OR p_max_file_size_mb > 50 THEN
    RAISE EXCEPTION 'max_file_size_mb out of range (1..50)';
  END IF;

  IF p_context_window IS NOT NULL AND p_context_window < 1 THEN
    RAISE EXCEPTION 'context_window must be positive';
  END IF;

  INSERT INTO data.ai_model_capabilities (
    provider,
    model_id,
    vision,
    tools,
    tools_with_vision,
    streaming,
    max_image_size_mb,
    supported_image_mimes,
    max_file_size_mb,
    supported_file_mimes,
    context_window,
    deprecated_at,
    needs_review,
    source,
    updated_at
  ) VALUES (
    v_provider,
    v_model_id,
    COALESCE(p_vision, false),
    COALESCE(p_tools, true),
    COALESCE(p_tools_with_vision, false),
    COALESCE(p_streaming, true),
    p_max_image_size_mb,
    COALESCE(p_supported_image_mimes, ARRAY['image/jpeg', 'image/png', 'image/webp']),
    p_max_file_size_mb,
    COALESCE(p_supported_file_mimes, ARRAY['application/pdf']),
    p_context_window,
    CASE WHEN p_deprecated THEN now() ELSE NULL END,
    COALESCE(p_needs_review, false),
    v_source,
    now()
  )
  ON CONFLICT (provider, model_id) DO UPDATE
  SET
    vision = EXCLUDED.vision,
    tools = EXCLUDED.tools,
    tools_with_vision = EXCLUDED.tools_with_vision,
    streaming = EXCLUDED.streaming,
    max_image_size_mb = EXCLUDED.max_image_size_mb,
    supported_image_mimes = EXCLUDED.supported_image_mimes,
    max_file_size_mb = EXCLUDED.max_file_size_mb,
    supported_file_mimes = EXCLUDED.supported_file_mimes,
    context_window = EXCLUDED.context_window,
    deprecated_at = EXCLUDED.deprecated_at,
    needs_review = EXCLUDED.needs_review,
    source = EXCLUDED.source,
    updated_at = now();

  RETURN jsonb_build_object(
    'success', true,
    'provider', v_provider,
    'model_id', v_model_id
  );
END;
$$;

REVOKE ALL ON FUNCTION api.upsert_ai_model_capability_admin(text, text, boolean, boolean, boolean, boolean, integer, text[], integer, text[], integer, boolean, boolean, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.upsert_ai_model_capability_admin(text, text, boolean, boolean, boolean, boolean, integer, text[], integer, text[], integer, boolean, boolean, text) FROM authenticated;
REVOKE ALL ON FUNCTION api.upsert_ai_model_capability_admin(text, text, boolean, boolean, boolean, boolean, integer, text[], integer, text[], integer, boolean, boolean, text) FROM anon;
GRANT EXECUTE ON FUNCTION api.upsert_ai_model_capability_admin(text, text, boolean, boolean, boolean, boolean, integer, text[], integer, text[], integer, boolean, boolean, text) TO service_role;
