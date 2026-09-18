-- RAISE sense UUID, COALESCE (incl. string buida), vault-miss real, feature disposable.
-- Snapshot primer; cleanup sempre. No reescriu files d'admin (només test.ai_composer_ux).
DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000003';
  v_missing uuid := '00000000-0000-0000-0000-00000000dead';
  v_secret uuid;
  v_result jsonb;
  v_prompt text;
  v_had_cfg boolean := false;
  v_had_provider boolean := false;
  v_had_ref boolean := false;
  v_old_active boolean;
  v_old_default data.ai_provider;
  v_old_legacy_prompt text;
  v_old_provider data.tenant_ai_provider_config%ROWTYPE;
  v_old_ref data.tenant_secret_refs%ROWTYPE;
  v_old_platform_prompt text;
  v_msg text;
  v_err text;
  v_denied boolean;
  v_test_feature text := 'test.ai_composer_ux';
BEGIN
  PERFORM set_config('request.jwt.claim.role', 'service_role', true);
  PERFORM set_config('request.jwt.claims', '{"role":"service_role"}', true);

  SELECT EXISTS (
    SELECT 1 FROM data.tenant_ai_config WHERE tenant_id = v_tenant
  ) INTO v_had_cfg;
  IF v_had_cfg THEN
    SELECT is_active, default_provider, system_prompt
    INTO v_old_active, v_old_default, v_old_legacy_prompt
    FROM data.tenant_ai_config
    WHERE tenant_id = v_tenant;
  END IF;

  SELECT * INTO v_old_provider
  FROM data.tenant_ai_provider_config
  WHERE tenant_id = v_tenant AND provider = 'openai';
  v_had_provider := FOUND;

  SELECT * INTO v_old_ref
  FROM data.tenant_secret_refs
  WHERE tenant_id = v_tenant
    AND secret_type = 'ai_api_key'
    AND provider = 'openai';
  v_had_ref := FOUND;

  SELECT system_prompt INTO v_old_platform_prompt
  FROM data.platform_ai_defaults
  WHERE provider = 'openai';

  DELETE FROM vault.secrets WHERE name LIKE 'ai_composer_ux_test_%';
  DELETE FROM data.platform_ai_feature_prompts WHERE feature = v_test_feature;

  BEGIN
    BEGIN
      PERFORM api.get_ai_api_key_for_generation(v_missing);
      RAISE EXCEPTION 'expected No AI config enabled';
    EXCEPTION WHEN OTHERS THEN
      v_msg := SQLERRM;
      IF v_msg <> 'No AI config enabled' THEN
        RAISE EXCEPTION 'unexpected no-config message: %', v_msg;
      END IF;
      IF v_msg ILIKE '%' || v_missing::text || '%' THEN
        RAISE EXCEPTION 'tenant uuid leaked in no-config error';
      END IF;
    END;

    INSERT INTO data.tenant_ai_config (tenant_id, default_provider, is_active, system_prompt)
    VALUES (v_tenant, 'openai', true, 'LEGACY_COMPOSER_TEST_PROMPT')
    ON CONFLICT (tenant_id) DO UPDATE
      SET is_active = true,
          default_provider = 'openai',
          system_prompt = 'LEGACY_COMPOSER_TEST_PROMPT';

    DELETE FROM data.tenant_ai_provider_config
    WHERE tenant_id = v_tenant AND provider = 'openai';

    BEGIN
      PERFORM api.get_ai_api_key_for_generation(v_tenant, 'openai');
      RAISE EXCEPTION 'expected No AI API key configured';
    EXCEPTION WHEN OTHERS THEN
      v_msg := SQLERRM;
      IF v_msg <> 'No AI API key configured for provider openai' THEN
        RAISE EXCEPTION 'unexpected missing-key message: %', v_msg;
      END IF;
      IF v_msg ILIKE '%' || v_tenant::text || '%' THEN
        RAISE EXCEPTION 'tenant uuid leaked in missing-key error';
      END IF;
    END;

    v_secret := vault.create_secret(
      'sk-test-ai-composer-ux',
      'ai_composer_ux_test_' || v_tenant::text,
      'Disposable composer UX test key'
    );

    INSERT INTO data.tenant_ai_provider_config (
      tenant_id, provider, model, ai_key_secret_id, key_verified_at, system_prompt
    ) VALUES (
      v_tenant, 'openai', 'gpt-4o-mini', v_secret, NULL, NULL
    )
    ON CONFLICT (tenant_id, provider) DO UPDATE
      SET model = 'gpt-4o-mini',
          ai_key_secret_id = EXCLUDED.ai_key_secret_id,
          key_verified_at = NULL,
          system_prompt = NULL;

    BEGIN
      PERFORM api.get_ai_api_key_for_generation(v_tenant, 'openai');
      RAISE EXCEPTION 'expected unverified key';
    EXCEPTION WHEN OTHERS THEN
      v_msg := SQLERRM;
      IF v_msg <> 'AI API key for provider openai is not verified' THEN
        RAISE EXCEPTION 'unexpected unverified message: %', v_msg;
      END IF;
      IF v_msg ILIKE '%' || v_tenant::text || '%' THEN
        RAISE EXCEPTION 'tenant uuid leaked in unverified error';
      END IF;
    END;

    DELETE FROM data.tenant_secret_refs
    WHERE tenant_id = v_tenant
      AND secret_type = 'ai_api_key'
      AND provider = 'openai';

    UPDATE data.tenant_ai_provider_config
    SET key_verified_at = now(),
        ai_key_secret_id = '00000000-0000-0000-0000-00000000beef'
    WHERE tenant_id = v_tenant AND provider = 'openai';

    BEGIN
      PERFORM api.get_ai_api_key_for_generation(v_tenant, 'openai');
      RAISE EXCEPTION 'expected vault miss';
    EXCEPTION WHEN OTHERS THEN
      v_msg := SQLERRM;
      IF v_msg <> 'AI API key not found in vault' THEN
        RAISE EXCEPTION 'unexpected vault-miss message: %', v_msg;
      END IF;
      IF v_msg ILIKE '%' || v_tenant::text || '%' THEN
        RAISE EXCEPTION 'tenant uuid leaked in vault-miss error';
      END IF;
    END;

    UPDATE data.platform_ai_defaults
    SET system_prompt = 'PLATFORM_COMPOSER_TEST_PROMPT'
    WHERE provider = 'openai';

    UPDATE data.tenant_ai_provider_config
    SET ai_key_secret_id = v_secret,
        key_verified_at = now(),
        system_prompt = NULL,
        temperature = NULL,
        max_tokens = NULL
    WHERE tenant_id = v_tenant AND provider = 'openai';

    v_result := api.get_ai_api_key_for_generation(v_tenant, 'openai');
    IF v_result->>'system_prompt' IS DISTINCT FROM 'PLATFORM_COMPOSER_TEST_PROMPT' THEN
      RAISE EXCEPTION 'platform prompt COALESCE failed: %', v_result->>'system_prompt';
    END IF;
    IF v_result->>'api_key' IS NULL OR length(v_result->>'api_key') = 0 THEN
      RAISE EXCEPTION 'vault key not returned';
    END IF;

    UPDATE data.tenant_ai_provider_config
    SET system_prompt = '   '
    WHERE tenant_id = v_tenant AND provider = 'openai';

    v_result := api.get_ai_api_key_for_generation(v_tenant, 'openai');
    IF v_result->>'system_prompt' IS DISTINCT FROM 'PLATFORM_COMPOSER_TEST_PROMPT' THEN
      RAISE EXCEPTION 'empty provider prompt masked platform: %', v_result->>'system_prompt';
    END IF;

    UPDATE data.tenant_ai_provider_config
    SET system_prompt = 'PROVIDER_COMPOSER_TEST_PROMPT'
    WHERE tenant_id = v_tenant AND provider = 'openai';

    v_result := api.get_ai_api_key_for_generation(v_tenant, 'openai');
    IF v_result->>'system_prompt' IS DISTINCT FROM 'PROVIDER_COMPOSER_TEST_PROMPT' THEN
      RAISE EXCEPTION 'provider prompt COALESCE failed: %', v_result->>'system_prompt';
    END IF;

    IF api.get_platform_ai_feature_prompt('commercial.price_sheet') IS NULL
       OR length(api.get_platform_ai_feature_prompt('commercial.price_sheet')) = 0 THEN
      RAISE EXCEPTION 'missing commercial.price_sheet seed';
    END IF;

    PERFORM api.upsert_platform_ai_feature_prompt(
      v_test_feature,
      'Test compositor UX',
      'FEATURE_PROMPT_OVERRIDE_TEST'
    );
    IF api.get_platform_ai_feature_prompt(v_test_feature) IS DISTINCT FROM 'FEATURE_PROMPT_OVERRIDE_TEST' THEN
      RAISE EXCEPTION 'feature prompt upsert did not replace instructions';
    END IF;

    v_prompt := api.get_platform_ai_feature_prompt('does.not.exist');
    IF v_prompt IS NOT NULL THEN
      RAISE EXCEPTION 'unknown feature should return null';
    END IF;

    PERFORM set_config('request.jwt.claim.role', 'authenticated', true);
    PERFORM set_config('request.jwt.claims', '{"role":"authenticated"}', true);
    v_denied := false;
    BEGIN
      PERFORM api.get_platform_ai_feature_prompt('commercial.price_sheet');
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM ILIKE '%forbidden%' THEN
        v_denied := true;
      ELSE
        RAISE EXCEPTION 'expected forbidden, got %', SQLERRM;
      END IF;
    END;
    IF NOT v_denied THEN
      RAISE EXCEPTION 'authenticated was allowed to read feature prompts';
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_err := SQLERRM;
  END;

  PERFORM set_config('request.jwt.claim.role', 'service_role', true);
  PERFORM set_config('request.jwt.claims', '{"role":"service_role"}', true);

  UPDATE data.platform_ai_defaults
  SET system_prompt = v_old_platform_prompt
  WHERE provider = 'openai';

  DELETE FROM data.tenant_ai_provider_config
  WHERE tenant_id = v_tenant AND provider = 'openai';
  IF v_had_provider THEN
    INSERT INTO data.tenant_ai_provider_config
    SELECT v_old_provider.*;
  END IF;

  IF v_had_cfg THEN
    UPDATE data.tenant_ai_config
    SET is_active = v_old_active,
        default_provider = v_old_default,
        system_prompt = v_old_legacy_prompt
    WHERE tenant_id = v_tenant;
  ELSE
    DELETE FROM data.tenant_ai_config WHERE tenant_id = v_tenant;
  END IF;

  DELETE FROM data.tenant_secret_refs
  WHERE tenant_id = v_tenant
    AND secret_type = 'ai_api_key'
    AND provider = 'openai';
  IF v_had_ref THEN
    INSERT INTO data.tenant_secret_refs
    SELECT v_old_ref.*;
  END IF;

  DELETE FROM data.platform_ai_feature_prompts WHERE feature = v_test_feature;

  IF v_secret IS NOT NULL THEN
    DELETE FROM vault.secrets
    WHERE id = v_secret
       OR name LIKE 'ai_composer_ux_test_%';
  ELSE
    DELETE FROM vault.secrets WHERE name LIKE 'ai_composer_ux_test_%';
  END IF;

  IF v_err IS NOT NULL THEN
    RAISE EXCEPTION '%', v_err;
  END IF;
END $$;
