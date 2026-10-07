-- CF-28 F8 DocuSeal bridge + review fixes (SQL-level).
-- Run: psql ... -f supabase/tests/commercial_docuseal_bridge_f8_tests.sql

BEGIN;

DO $$
DECLARE
  v_fn regprocedure;
  v_tenant uuid;
  v_req uuid := gen_random_uuid();
  v_sub uuid;
  v_apply jsonb;
  v_rec jsonb;
  v_view_def text;
BEGIN
  v_fn := 'api.bind_commercial_decision_docuseal_submission(uuid, uuid, uuid)'::regprocedure;
  ASSERT v_fn IS NOT NULL;

  v_fn := 'api.resolve_commercial_docuseal_continue(text)'::regprocedure;
  ASSERT v_fn IS NOT NULL;

  v_fn := 'api.apply_commercial_decision_from_docuseal_submission(uuid, text)'::regprocedure;
  ASSERT v_fn IS NOT NULL;

  ASSERT (
    pg_get_functiondef('api.resolve_commercial_decision_token(text, boolean)'::regprocedure)
    LIKE '%provider_continue_available%'
  );

  ASSERT (
    pg_get_functiondef('data.apply_commercial_decision_from_docuseal_submission(uuid, text)'::regprocedure)
    LIKE '%submission_superseded%'
  );

  v_fn := 'api.continue_customer_portal_pending_docuseal(bytea, uuid, inet, text, text)'::regprocedure;
  ASSERT v_fn IS NOT NULL;

  ASSERT (
    api.continue_customer_portal_pending_docuseal(NULL, NULL)->>'code' = 'invalid'
  );

  v_fn := 'api.prepare_commercial_decision_signing_attempt(uuid, text, uuid)'::regprocedure;
  ASSERT v_fn IS NOT NULL;
  v_fn := 'api.abort_commercial_decision_signing_prepare(uuid, uuid)'::regprocedure;
  ASSERT v_fn IS NOT NULL;
  v_fn := 'api.record_signing_submission_artifact_status(uuid, text, text, text)'::regprocedure;
  ASSERT v_fn IS NOT NULL;
  v_fn := 'api.list_signing_submissions_needing_artifact_reconcile(integer)'::regprocedure;
  ASSERT v_fn IS NOT NULL;
  v_fn := 'api.record_signing_ops_job_run(text, boolean, integer, integer, integer, integer, text, timestamptz)'::regprocedure;
  ASSERT v_fn IS NOT NULL;

  -- CS-D58: internal retry URL column + tenant view redacts artifact_signed_url
  ASSERT (
    EXISTS (
      SELECT 1 FROM information_schema.columns
      WHERE table_schema = 'data'
        AND table_name = 'signing_submissions'
        AND column_name = 'artifact_retry_url'
    )
  );
  SELECT pg_get_viewdef('api.signing_submissions'::regclass, true) INTO v_view_def;
  ASSERT v_view_def LIKE '%artifact_signed_url%';
  ASSERT v_view_def LIKE '%- %' OR v_view_def LIKE '%artifact_signed_url%';

  ASSERT (
    EXISTS (
      SELECT 1 FROM pg_indexes
      WHERE schemaname = 'data'
        AND indexname = 'uq_signing_submissions_one_active_commercial_bridge'
    )
  );

  -- Continue without token → not_found
  ASSERT (
    api.resolve_commercial_docuseal_continue(NULL)->>'code' = 'not_found'
  );
  ASSERT (
    api.resolve_commercial_docuseal_continue('short')->>'code' = 'not_found'
  );

  -- Behavior: supersede → apply returns submission_superseded
  SELECT id INTO v_tenant FROM data.tenants ORDER BY created_at ASC NULLS LAST LIMIT 1;
  IF v_tenant IS NOT NULL THEN
    INSERT INTO data.signing_submissions (
      tenant_id,
      source_type,
      external_id,
      status,
      signing_provider,
      metadata
    ) VALUES (
      v_tenant,
      'document_existing',
      'f8-test-' || gen_random_uuid()::text,
      'pending',
      'docuseal',
      jsonb_build_object(
        'commercial_bridge', true,
        'decision_request_id', v_req::text
      )
    )
    RETURNING id INTO v_sub;

    PERFORM data.supersede_commercial_bridge_submissions(v_tenant, v_req, NULL);

    ASSERT EXISTS (
      SELECT 1 FROM data.signing_submissions
      WHERE id = v_sub
        AND COALESCE((metadata->>'superseded_by_switch')::boolean, false)
    );

    v_apply := data.apply_commercial_decision_from_docuseal_submission(v_sub, 'accepted');
    ASSERT v_apply->>'code' = 'submission_superseded';

    -- Artifact status writes column, not metadata URL
    v_rec := api.record_signing_submission_artifact_status(
      v_sub, 'failed', 'download_failed', 'https://example.test/signed.pdf'
    );
    ASSERT v_rec->>'ok' = 'true';
    ASSERT EXISTS (
      SELECT 1 FROM data.signing_submissions
      WHERE id = v_sub
        AND artifact_retry_url = 'https://example.test/signed.pdf'
        AND NOT (metadata ? 'artifact_signed_url')
    );

    -- Idempotent artifact event: same status again does not fail
    v_rec := api.record_signing_submission_artifact_status(
      v_sub, 'failed', 'download_failed', 'https://example.test/signed.pdf'
    );
    ASSERT v_rec->>'ok' = 'true';
  END IF;

  RAISE NOTICE 'commercial_docuseal_bridge_f8_tests OK';
END $$;

ROLLBACK;
