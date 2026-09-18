-- Tenant terminology overlay: sanitizer, revert {}, wipe only on profile change.
DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000003';
  v_owner uuid := '20000000-0000-0000-0000-000000000002';
  v_old_settings jsonb;
  v_old_profile uuid;
  v_fsm uuid;
  v_generic uuid;
  v_map jsonb;
  v_after jsonb;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', v_owner::text, true);
  PERFORM set_config(
    'request.jwt.claims',
    json_build_object(
      'sub', v_owner,
      'role', 'authenticated',
      'app_metadata', json_build_object(
        'user_tenants', json_build_object(
          v_tenant::text, json_build_object('global_role', 'owner', 'sites', json_build_object())
        ),
        'user_permissions', json_build_object(
          v_tenant::text, json_build_object(
            'global_permissions', json_build_array('*'),
            'sites', json_build_object()
          )
        )
      )
    )::text,
    true
  );
  PERFORM set_config('request.jwt.claim', current_setting('request.jwt.claims', true), true);
  PERFORM set_config(
    'request.headers',
    json_build_object('x-tenant-id', v_tenant)::text,
    true
  );

  SELECT settings, sector_profile_id
    INTO v_old_settings, v_old_profile
  FROM data.tenants
  WHERE id = v_tenant;

  SELECT id INTO v_fsm
  FROM data.sector_profiles
  WHERE archetype = 'field_service' AND vertical IS NULL
  LIMIT 1;

  SELECT id INTO v_generic
  FROM data.sector_profiles
  WHERE archetype = 'generic' AND vertical IS NULL
  LIMIT 1;

  IF v_fsm IS NULL OR v_generic IS NULL THEN
    RAISE EXCEPTION 'missing sector profiles for terminology tests';
  END IF;

  BEGIN
    IF data.sanitize_terminology_value('Pressupost') IS NOT NULL THEN
      RAISE EXCEPTION 'denylist missed Pressupost';
    END IF;
    IF data.sanitize_terminology_value('Albarà') IS NOT NULL THEN
      RAISE EXCEPTION 'denylist missed Albarà';
    END IF;
    IF data.sanitize_terminology_value('Factura') IS NOT NULL THEN
      RAISE EXCEPTION 'denylist missed Factura';
    END IF;
    IF data.sanitize_terminology_value('Què es cobra') IS DISTINCT FROM 'Què es cobra' THEN
      RAISE EXCEPTION 'Què es cobra should be allowed';
    END IF;
    IF data.sanitize_terminology_value('Imports') IS DISTINCT FROM 'Imports' THEN
      RAISE EXCEPTION 'Imports should be allowed';
    END IF;

    v_map := data.sanitize_terminology_map(
      '{"visit":"Sortida","quote":"Oferta","project":"Obres","price_sheet":"Pressupost"}'::jsonb
    );
    IF v_map <> '{"project":"Obres"}'::jsonb THEN
      RAISE EXCEPTION 'sanitize map dropped expected keys only: %', v_map;
    END IF;

    IF COALESCE((SELECT labels->>'project_plural' FROM data.sector_profiles WHERE id = v_fsm), '') = '' THEN
      RAISE EXCEPTION 'field_service missing project_plural seed';
    END IF;
    IF COALESCE((SELECT labels->>'contacts' FROM data.sector_profiles WHERE id = v_fsm), '') = '' THEN
      RAISE EXCEPTION 'field_service missing contacts seed';
    END IF;

    PERFORM api.update_tenant_settings(
      '{"terminology":{"project":"Obres","price_sheet":"Pressupost","visit":"Sortida"}}'::jsonb,
      v_tenant
    );
    SELECT settings->'terminology' INTO v_after FROM data.tenants WHERE id = v_tenant;
    IF v_after <> '{"project":"Obres"}'::jsonb THEN
      RAISE EXCEPTION 'update_tenant_settings overlay mismatch: %', v_after;
    END IF;

    PERFORM api.update_tenant_settings('{"terminology":{}}'::jsonb, v_tenant);
    SELECT settings->'terminology' INTO v_after FROM data.tenants WHERE id = v_tenant;
    IF v_after <> '{}'::jsonb THEN
      RAISE EXCEPTION 'revert {} did not replace terminology: %', v_after;
    END IF;

    PERFORM api.update_tenant_settings(
      '{"terminology":{"project":"Obres","price_sheet":"Imports"}}'::jsonb,
      v_tenant
    );

    PERFORM api.apply_sector_recipe(v_fsm, NULL, v_tenant);
    SELECT settings->'terminology' INTO v_after FROM data.tenants WHERE id = v_tenant;
    IF v_after <> '{"project":"Obres","price_sheet":"Imports"}'::jsonb THEN
      RAISE EXCEPTION 'same-profile recipe wiped terminology: %', v_after;
    END IF;

    PERFORM api.apply_sector_recipe(v_generic, NULL, v_tenant);
    SELECT settings->'terminology' INTO v_after FROM data.tenants WHERE id = v_tenant;
    IF v_after IS NOT NULL THEN
      RAISE EXCEPTION 'profile change did not wipe terminology: %', v_after;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    UPDATE data.tenants
    SET settings = v_old_settings,
        sector_profile_id = v_old_profile
    WHERE id = v_tenant;
    RAISE;
  END;

  UPDATE data.tenants
  SET settings = v_old_settings,
      sector_profile_id = v_old_profile
  WHERE id = v_tenant;
END;
$$;
