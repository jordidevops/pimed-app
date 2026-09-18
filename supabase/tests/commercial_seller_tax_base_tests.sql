-- Seller NIF/address from tenant_legal_profiles + tax_base at issue.
-- Snapshot-first restore of the legal profile. No backfill of issued docs.
DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000003';
  v_owner uuid := '20000000-0000-0000-0000-000000000002';
  v_client uuid := '80000000-0000-0000-0000-000000000101';
  v_site uuid := '30000000-0000-0000-0000-000000000004';
  v_project uuid := gen_random_uuid();
  v_project_empty uuid := gen_random_uuid();
  v_quote uuid;
  v_quote_empty uuid;
  v_seller jsonb;
  v_tax jsonb;
  v_had_profile boolean := false;
  v_old data.tenant_legal_profiles%ROWTYPE;
  v_err text;
  v_tenant_name text;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', v_owner::text, true);
  PERFORM set_config(
    'request.jwt.claim',
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
  PERFORM set_config(
    'request.headers',
    json_build_object('x-tenant-id', v_tenant)::text,
    true
  );

  SELECT name INTO v_tenant_name FROM data.tenants WHERE id = v_tenant;

  SELECT * INTO v_old
  FROM data.tenant_legal_profiles
  WHERE tenant_id = v_tenant;
  v_had_profile := FOUND;

  INSERT INTO data.tenant_legal_profiles (
    tenant_id, legal_name, trade_name, nif, postal_address
  ) VALUES (
    v_tenant, 'Volt Serveis SL', 'Volt', 'B00000003', 'Carrer Test 1, Vic'
  )
  ON CONFLICT (tenant_id) DO UPDATE
    SET legal_name = EXCLUDED.legal_name,
        trade_name = EXCLUDED.trade_name,
        nif = EXCLUDED.nif,
        postal_address = EXCLUDED.postal_address;

  BEGIN
    INSERT INTO data.projects (
      id, tenant_id, type, name, description, status, visibility,
      site_id, client_id, created_by
    ) VALUES (
      v_project, v_tenant, 'work_order', 'Seller tax_base', 'Disposable',
      'active', 'company', v_site, v_client, v_owner
    );

    PERFORM api.upsert_project_line(
      v_project, NULL, NULL, 'service', 'Linia IVA 21', NULL, 'u',
      2, 50, 0, 21, 0, NULL, gen_random_uuid()
    );

    v_quote := api.issue_commercial_document(
      v_project, 'quote', true, gen_random_uuid(), NULL
    );

    SELECT seller_snapshot, tax_breakdown
    INTO v_seller, v_tax
    FROM data.commercial_documents
    WHERE id = v_quote;

    IF v_seller->>'tax_id' IS DISTINCT FROM 'B00000003' THEN
      RAISE EXCEPTION 'seller tax_id missing: %', v_seller;
    END IF;
    IF v_seller->>'address_line1' IS DISTINCT FROM 'Carrer Test 1, Vic' THEN
      RAISE EXCEPTION 'seller address missing: %', v_seller;
    END IF;
    IF v_seller->>'display_name' IS DISTINCT FROM 'Volt Serveis SL' THEN
      RAISE EXCEPTION 'seller display_name missing: %', v_seller;
    END IF;
    IF v_tax->0->>'tax_base' IS DISTINCT FROM '100.00'
       AND v_tax->0->>'tax_base' IS DISTINCT FROM '100' THEN
      RAISE EXCEPTION 'tax_base expected 100, got %', v_tax;
    END IF;

    BEGIN
      UPDATE data.commercial_documents
      SET seller_snapshot = v_seller || '{"tax_id":"X"}'::jsonb
      WHERE id = v_quote;
      RAISE EXCEPTION 'issued seller_snapshot was mutable';
    EXCEPTION
      WHEN OTHERS THEN
        IF SQLERRM NOT LIKE '%commercial_document_immutable%' THEN
          RAISE;
        END IF;
    END;

    UPDATE data.tenant_legal_profiles
    SET legal_name = NULL, trade_name = NULL, nif = NULL, postal_address = NULL
    WHERE tenant_id = v_tenant;

    INSERT INTO data.projects (
      id, tenant_id, type, name, description, status, visibility,
      site_id, client_id, created_by
    ) VALUES (
      v_project_empty, v_tenant, 'work_order', 'Seller empty profile', 'Disposable',
      'active', 'company', v_site, v_client, v_owner
    );

    PERFORM api.upsert_project_line(
      v_project_empty, NULL, NULL, 'service', 'Linia buida', NULL, 'u',
      1, 10, 0, 21, 0, NULL, gen_random_uuid()
    );

    v_quote_empty := api.issue_commercial_document(
      v_project_empty, 'quote', true, gen_random_uuid(), NULL
    );

    SELECT seller_snapshot, tax_breakdown
    INTO v_seller, v_tax
    FROM data.commercial_documents
    WHERE id = v_quote_empty;

    IF v_seller->>'tax_id' IS NOT NULL THEN
      RAISE EXCEPTION 'empty profile leaked tax_id: %', v_seller;
    END IF;
    IF v_seller->>'address_line1' IS NOT NULL THEN
      RAISE EXCEPTION 'empty profile leaked address: %', v_seller;
    END IF;
    IF v_seller->>'display_name' IS DISTINCT FROM v_tenant_name THEN
      RAISE EXCEPTION 'empty profile display_name expected %, got %', v_tenant_name, v_seller;
    END IF;
    IF v_tax->0->>'tax_base' IS DISTINCT FROM '10.00'
       AND v_tax->0->>'tax_base' IS DISTINCT FROM '10' THEN
      RAISE EXCEPTION 'empty profile tax_base expected 10, got %', v_tax;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_err := SQLERRM;
  END;

  IF v_had_profile THEN
    UPDATE data.tenant_legal_profiles
    SET legal_name = v_old.legal_name,
        trade_name = v_old.trade_name,
        nif = v_old.nif,
        postal_address = v_old.postal_address
    WHERE tenant_id = v_tenant;
  ELSE
    DELETE FROM data.tenant_legal_profiles WHERE tenant_id = v_tenant;
  END IF;

  IF v_err IS NOT NULL THEN
    RAISE EXCEPTION '%', v_err;
  END IF;
END $$;
