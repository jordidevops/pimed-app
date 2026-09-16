-- Tall 1 quote reissue: trace, idempotency, tenant boundary and immutability.
-- Kept as one statement so `supabase db query --file` can execute it.
DO $$
DECLARE
  v_previous uuid;
  v_new uuid;
  v_retry uuid;
  v_link uuid;
  v_events integer;
BEGIN
  BEGIN
    PERFORM set_config(
      'request.jwt.claim.sub',
      '20000000-0000-0000-0000-000000000002',
      true
    );
    PERFORM set_config(
      'request.jwt.claim',
      '{"sub":"20000000-0000-0000-0000-000000000002","role":"authenticated","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000003":{"global_role":"owner","sites":{}}},"user_permissions":{"10000000-0000-0000-0000-000000000003":{"global_permissions":["*"],"sites":{}}}}}',
      true
    );
    PERFORM set_config(
      'request.headers',
      '{"x-tenant-id":"10000000-0000-0000-0000-000000000003"}',
      true
    );

    v_previous := api.issue_commercial_document(
      '51000000-0000-0000-0000-000000000101'::uuid,
      'quote',
      true,
      '91000000-0000-0000-0000-000000000001'::uuid,
      NULL
    );
    PERFORM api.reject_commercial_document(
      v_previous,
      '{"method":"sql_test"}'::jsonb,
      '91000000-0000-0000-0000-000000000002'::uuid
    );

    v_new := api.reissue_commercial_quote(
      v_previous,
      '91000000-0000-0000-0000-000000000003'::uuid
    );
    v_retry := api.reissue_commercial_quote(
      v_previous,
      '91000000-0000-0000-0000-000000000003'::uuid
    );

    SELECT supersedes_id INTO v_link
    FROM data.commercial_documents
    WHERE id = v_new;

    SELECT count(*) INTO v_events
    FROM data.commercial_document_events
    WHERE document_id = v_previous
      AND event_type = 'superseded'
      AND payload->>'superseded_by_id' = v_new::text;

    IF v_new <> v_retry OR v_link <> v_previous OR v_events <> 1 THEN
      RAISE EXCEPTION
        'T1 trace/idempotency failed: new=% retry=% link=% events=%',
        v_new, v_retry, v_link, v_events;
    END IF;

    BEGIN
      UPDATE data.commercial_documents
      SET supersedes_id = NULL
      WHERE id = v_new;
      RAISE EXCEPTION 'T2 supersedes update was allowed';
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%commercial_document_immutable%' THEN
        RAISE;
      END IF;
    END;

    PERFORM set_config(
      'request.jwt.claim.sub',
      '20000000-0000-0000-0000-000000000001',
      true
    );
    PERFORM set_config(
      'request.jwt.claim',
      '{"sub":"20000000-0000-0000-0000-000000000001","role":"authenticated","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"owner","sites":{}}}}}',
      true
    );
    PERFORM set_config(
      'request.headers',
      '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}',
      true
    );

    BEGIN
      PERFORM api.reissue_commercial_quote(
        v_previous,
        '91000000-0000-0000-0000-000000000004'::uuid
      );
      RAISE EXCEPTION 'T3 cross-tenant reissue was allowed';
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%access_denied%'
         AND SQLERRM NOT LIKE '%not_found%' THEN
        RAISE;
      END IF;
    END;

    -- Roll the fixture writes back while keeping a successful command exit.
    RAISE EXCEPTION USING
      ERRCODE = 'ZZ001',
      MESSAGE = 'quote reissue tests passed';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN
    RAISE NOTICE 'PASS: trace, idempotency, immutability and tenant isolation';
  END;
END;
$$;
