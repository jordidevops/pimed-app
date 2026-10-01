-- CF-21-e: operational validity — finalize on signature, activate by starts_on,
-- expire/renew by ends_on + auto_renew. SLA / billing / legal template → CF-21-f+.

-- ---------------------------------------------------------------------------
-- Event: renewed
-- ---------------------------------------------------------------------------
ALTER TABLE data.commercial_agreement_events
  DROP CONSTRAINT IF EXISTS commercial_agreement_events_event_type_check;

ALTER TABLE data.commercial_agreement_events
  ADD CONSTRAINT commercial_agreement_events_event_type_check
  CHECK (event_type IN (
    'created', 'prepared', 'sent', 'signed', 'activated',
    'cancelled', 'project_linked', 'project_unlinked',
    'suspended', 'finished', 'renewed',
    'coverage_linked', 'coverage_unlinked',
    'maintenance_plan_linked', 'maintenance_plan_unlinked'
  ));

CREATE INDEX IF NOT EXISTS idx_commercial_agreement_versions_tenant_starts_on
  ON data.commercial_agreement_versions (tenant_id, starts_on)
  WHERE starts_on IS NOT NULL;

-- Allow signed_document_id after send/sign; allow date roll on renew unlock.
CREATE OR REPLACE FUNCTION data.trg_commercial_agreement_versions_immutable()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_renew_ok boolean :=
    current_setting('app.commercial_agreement_renew_unlocked', true) = 'on';
BEGIN
  IF OLD.status IN ('pending_signature', 'signed') THEN
    IF NEW.tenant_id IS DISTINCT FROM OLD.tenant_id
       OR NEW.agreement_id IS DISTINCT FROM OLD.agreement_id
       OR NEW.version_no IS DISTINCT FROM OLD.version_no
       OR NEW.source_quote_id IS DISTINCT FROM OLD.source_quote_id
       OR NEW.source_quote_content_hash IS DISTINCT FROM OLD.source_quote_content_hash
       OR NEW.source_quote_document_id IS DISTINCT FROM OLD.source_quote_document_id
       OR NEW.full_body_template_id IS DISTINCT FROM OLD.full_body_template_id
       OR NEW.rendered_document_id IS DISTINCT FROM OLD.rendered_document_id
       OR NEW.content_hash IS DISTINCT FROM OLD.content_hash
       OR NEW.notice_days IS DISTINCT FROM OLD.notice_days
       OR NEW.auto_renew IS DISTINCT FROM OLD.auto_renew
       OR NEW.terms_snapshot IS DISTINCT FROM OLD.terms_snapshot
       OR (
         NOT v_renew_ok
         AND (
           NEW.starts_on IS DISTINCT FROM OLD.starts_on
           OR NEW.ends_on IS DISTINCT FROM OLD.ends_on
         )
       )
       OR (
         NEW.status IS DISTINCT FROM OLD.status
         AND NOT (OLD.status = 'pending_signature' AND NEW.status = 'signed')
       )
    THEN
      RAISE EXCEPTION 'agreement_version_immutable'
        USING ERRCODE = 'P0001';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

-- ---------------------------------------------------------------------------
-- Finalize a signed version → agreement active or still pending_start
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.finalize_commercial_agreement_version(
  p_version_id uuid,
  p_signed_document_id uuid DEFAULT NULL,
  p_actor_id uuid DEFAULT NULL,
  p_as_of date DEFAULT CURRENT_DATE
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_version data.commercial_agreement_versions%ROWTYPE;
  v_agreement data.commercial_agreements%ROWTYPE;
  v_activate boolean;
BEGIN
  SELECT * INTO v_version
  FROM data.commercial_agreement_versions
  WHERE id = p_version_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'agreement_version_not_found' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_agreement
  FROM data.commercial_agreements
  WHERE id = v_version.agreement_id
  FOR UPDATE;

  IF v_version.status = 'signed'
     AND v_agreement.status IN ('active', 'finished', 'cancelled') THEN
    RETURN v_agreement.id;
  END IF;

  IF v_version.status NOT IN ('draft', 'pending_signature', 'signed') THEN
    RAISE EXCEPTION 'agreement_version_immutable' USING ERRCODE = 'P0001';
  END IF;

  IF v_version.status IS DISTINCT FROM 'signed' THEN
    UPDATE data.commercial_agreement_versions
    SET status = 'signed',
        signed_document_id = COALESCE(p_signed_document_id, signed_document_id),
        updated_at = now()
    WHERE id = v_version.id;

    INSERT INTO data.commercial_agreement_events (
      tenant_id, agreement_id, event_type, actor_id, payload
    ) VALUES (
      v_version.tenant_id, v_version.agreement_id, 'signed', p_actor_id,
      jsonb_build_object(
        'version_id', v_version.id,
        'signed_document_id', COALESCE(p_signed_document_id, v_version.signed_document_id)
      )
    );
  ELSIF p_signed_document_id IS NOT NULL
        AND v_version.signed_document_id IS DISTINCT FROM p_signed_document_id THEN
    UPDATE data.commercial_agreement_versions
    SET signed_document_id = p_signed_document_id,
        updated_at = now()
    WHERE id = v_version.id;
  END IF;

  IF v_agreement.status IN ('cancelled', 'finished') THEN
    RETURN v_agreement.id;
  END IF;

  v_activate := (v_version.starts_on IS NULL OR v_version.starts_on <= p_as_of);

  IF v_activate AND v_agreement.status IS DISTINCT FROM 'active' THEN
    UPDATE data.commercial_agreements
    SET status = 'active'
    WHERE id = v_agreement.id;

    INSERT INTO data.commercial_agreement_events (
      tenant_id, agreement_id, event_type, actor_id, payload
    ) VALUES (
      v_version.tenant_id, v_version.agreement_id, 'activated', p_actor_id,
      jsonb_build_object(
        'version_id', v_version.id,
        'starts_on', v_version.starts_on,
        'as_of', p_as_of
      )
    );
  ELSIF NOT v_activate AND v_agreement.status = 'active' THEN
    -- Signed for a future start: keep pending_start until cron/activate_due
    UPDATE data.commercial_agreements
    SET status = 'pending_start'
    WHERE id = v_agreement.id;
  END IF;

  RETURN v_agreement.id;
END;
$$;

COMMENT ON FUNCTION data.finalize_commercial_agreement_version(uuid, uuid, uuid, date) IS
  'CF-21-e: marca la versió com a signed i activa l''acord si starts_on és null o ≤ as_of.';

REVOKE ALL ON FUNCTION data.finalize_commercial_agreement_version(uuid, uuid, uuid, date) FROM PUBLIC;

CREATE OR REPLACE FUNCTION api.finalize_commercial_agreement_version(
  p_version_id uuid,
  p_signed_document_id uuid DEFAULT NULL,
  p_as_of date DEFAULT CURRENT_DATE
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_version data.commercial_agreement_versions%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO v_version FROM data.commercial_agreement_versions WHERE id = p_version_id;
  IF NOT FOUND OR NOT (data.jwt_user_tenants() ? v_version.tenant_id::text) THEN
    RAISE EXCEPTION 'agreement_version_not_found' USING ERRCODE = 'P0001';
  END IF;
  IF COALESCE((
    SELECT tm.role FROM data.tenant_members tm
    WHERE tm.tenant_id = v_version.tenant_id
      AND tm.user_id = v_uid AND tm.site_id IS NULL
    LIMIT 1
  ), '') NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'permission_denied:agreement_prepare' USING ERRCODE = 'P0001';
  END IF;
  RETURN data.finalize_commercial_agreement_version(
    p_version_id, p_signed_document_id, v_uid, COALESCE(p_as_of, CURRENT_DATE)
  );
END;
$$;

REVOKE ALL ON FUNCTION api.finalize_commercial_agreement_version(uuid, uuid, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.finalize_commercial_agreement_version(uuid, uuid, date)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Hook: when a native signing session completes for an agreement PDF
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.apply_commercial_agreement_signing_for_session(
  p_session_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_session data.document_signing_sessions%ROWTYPE;
  v_document_id uuid;
  v_version_id uuid;
  v_signed_doc uuid;
BEGIN
  SELECT * INTO v_session
  FROM data.document_signing_sessions
  WHERE id = p_session_id;
  IF NOT FOUND OR v_session.status IS DISTINCT FROM 'signed' THEN
    RETURN;
  END IF;

  SELECT dv.document_id INTO v_document_id
  FROM data.document_versions dv
  WHERE dv.id = v_session.document_version_id;
  IF v_document_id IS NULL THEN
    RETURN;
  END IF;

  SELECT cav.id INTO v_version_id
  FROM data.commercial_agreement_versions cav
  WHERE cav.rendered_document_id = v_document_id
  ORDER BY cav.version_no DESC
  LIMIT 1;
  IF v_version_id IS NULL THEN
    RETURN;
  END IF;

  IF v_session.result_version_id IS NOT NULL THEN
    SELECT dv.document_id INTO v_signed_doc
    FROM data.document_versions dv
    WHERE dv.id = v_session.result_version_id;
  END IF;

  PERFORM data.finalize_commercial_agreement_version(
    v_version_id,
    v_signed_doc,
    v_session.operator_user_id,
    CURRENT_DATE
  );
END;
$$;

REVOKE ALL ON FUNCTION data.apply_commercial_agreement_signing_for_session(uuid) FROM PUBLIC;

CREATE OR REPLACE FUNCTION data.trg_apply_commercial_agreement_signing()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NEW.status = 'signed' AND OLD.status IS DISTINCT FROM 'signed' THEN
    BEGIN
      PERFORM data.apply_commercial_agreement_signing_for_session(NEW.id);
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'CF-21-e agreement signing finalize failed: %', SQLERRM;
    END;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_apply_commercial_agreement_signing ON data.document_signing_sessions;
CREATE TRIGGER trg_apply_commercial_agreement_signing
  AFTER UPDATE OF status ON data.document_signing_sessions
  FOR EACH ROW
  EXECUTE FUNCTION data.trg_apply_commercial_agreement_signing();

-- ---------------------------------------------------------------------------
-- Activate agreements whose starts_on has arrived
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.activate_due_commercial_agreements(
  p_as_of date DEFAULT CURRENT_DATE,
  p_limit int DEFAULT 200
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  r record;
  v_activated int := 0;
  v_as_of date := COALESCE(p_as_of, CURRENT_DATE);
BEGIN
  FOR r IN
    SELECT a.id AS agreement_id, v.id AS version_id, a.tenant_id
    FROM data.commercial_agreements a
    JOIN data.commercial_agreement_versions v ON v.id = a.active_version_id
    WHERE a.status = 'pending_start'
      AND v.status = 'signed'
      AND (v.starts_on IS NULL OR v.starts_on <= v_as_of)
    ORDER BY COALESCE(v.starts_on, v_as_of), a.created_at
    LIMIT GREATEST(COALESCE(p_limit, 200), 1)
    FOR UPDATE OF a SKIP LOCKED
  LOOP
    UPDATE data.commercial_agreements
    SET status = 'active'
    WHERE id = r.agreement_id;

    INSERT INTO data.commercial_agreement_events (
      tenant_id, agreement_id, event_type, payload
    ) VALUES (
      r.tenant_id, r.agreement_id, 'activated',
      jsonb_build_object('version_id', r.version_id, 'as_of', v_as_of, 'source', 'activate_due')
    );
    v_activated := v_activated + 1;
  END LOOP;

  RETURN jsonb_build_object('activated', v_activated, 'as_of', v_as_of);
END;
$$;

COMMENT ON FUNCTION api.activate_due_commercial_agreements(date, int) IS
  'CF-21-e: activa acords firmat amb starts_on ≤ as_of (o sense starts_on).';

REVOKE ALL ON FUNCTION api.activate_due_commercial_agreements(date, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.activate_due_commercial_agreements(date, int) TO service_role;

-- ---------------------------------------------------------------------------
-- Expire or auto-renew when ends_on has passed
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.expire_or_renew_commercial_agreements(
  p_as_of date DEFAULT CURRENT_DATE,
  p_limit int DEFAULT 200
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  r record;
  v_finished int := 0;
  v_renewed int := 0;
  v_as_of date := COALESCE(p_as_of, CURRENT_DATE);
  v_span int;
  v_new_end date;
BEGIN
  FOR r IN
    SELECT
      a.id AS agreement_id,
      a.tenant_id,
      v.id AS version_id,
      v.starts_on,
      v.ends_on,
      v.auto_renew,
      v.notice_days
    FROM data.commercial_agreements a
    JOIN data.commercial_agreement_versions v ON v.id = a.active_version_id
    WHERE a.status = 'active'
      AND v.status = 'signed'
      AND v.ends_on IS NOT NULL
      AND v.ends_on < v_as_of
    ORDER BY v.ends_on, a.created_at
    LIMIT GREATEST(COALESCE(p_limit, 200), 1)
    FOR UPDATE OF a, v SKIP LOCKED
  LOOP
    IF COALESCE(r.auto_renew, false) THEN
      v_span := GREATEST(
        COALESCE(r.ends_on - COALESCE(r.starts_on, r.ends_on - 365), 365),
        1
      );
      v_new_end := r.ends_on + v_span;

      PERFORM set_config('app.commercial_agreement_renew_unlocked', 'on', true);
      UPDATE data.commercial_agreement_versions
      SET starts_on = r.ends_on + 1,
          ends_on = v_new_end,
          updated_at = now()
      WHERE id = r.version_id;
      PERFORM set_config('app.commercial_agreement_renew_unlocked', 'off', true);

      INSERT INTO data.commercial_agreement_events (
        tenant_id, agreement_id, event_type, payload
      ) VALUES (
        r.tenant_id, r.agreement_id, 'renewed',
        jsonb_build_object(
          'version_id', r.version_id,
          'previous_ends_on', r.ends_on,
          'new_starts_on', r.ends_on + 1,
          'new_ends_on', v_new_end,
          'as_of', v_as_of
        )
      );
      v_renewed := v_renewed + 1;
    ELSE
      UPDATE data.commercial_agreements
      SET status = 'finished'
      WHERE id = r.agreement_id;

      INSERT INTO data.commercial_agreement_events (
        tenant_id, agreement_id, event_type, payload
      ) VALUES (
        r.tenant_id, r.agreement_id, 'finished',
        jsonb_build_object(
          'version_id', r.version_id,
          'ends_on', r.ends_on,
          'as_of', v_as_of,
          'source', 'expire'
        )
      );
      v_finished := v_finished + 1;
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'finished', v_finished,
    'renewed', v_renewed,
    'as_of', v_as_of
  );
END;
$$;

COMMENT ON FUNCTION api.expire_or_renew_commercial_agreements(date, int) IS
  'CF-21-e: si ends_on ha passat, auto_renew amplia vigència; altrament finished.';

REVOKE ALL ON FUNCTION api.expire_or_renew_commercial_agreements(date, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.expire_or_renew_commercial_agreements(date, int) TO service_role;

-- ---------------------------------------------------------------------------
-- Daily cron (best-effort if pg_cron present)
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    BEGIN
      PERFORM cron.unschedule('activate-due-commercial-agreements');
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;
    BEGIN
      PERFORM cron.unschedule('expire-or-renew-commercial-agreements');
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;
    PERFORM cron.schedule(
      'activate-due-commercial-agreements',
      '20 5 * * *',
      $cron$SELECT api.activate_due_commercial_agreements(CURRENT_DATE, 500)$cron$
    );
    PERFORM cron.schedule(
      'expire-or-renew-commercial-agreements',
      '25 5 * * *',
      $cron$SELECT api.expire_or_renew_commercial_agreements(CURRENT_DATE, 500)$cron$
    );
  END IF;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'CF-21-e: could not schedule agreement lifecycle cron: %', SQLERRM;
END;
$$;

-- ---------------------------------------------------------------------------
-- prepare + create_framework: persist auto_renew (new trailing default arg)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.prepare_agreement_from_quote(
  p_document_id uuid,
  p_template_id uuid,
  p_work_gate text,
  p_client_op_id uuid,
  p_kind text DEFAULT 'specific',
  p_starts_on date DEFAULT NULL,
  p_ends_on date DEFAULT NULL,
  p_notice_days int DEFAULT NULL,
  p_auto_renew boolean DEFAULT false
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_doc data.commercial_documents%ROWTYPE;
  v_project data.projects%ROWTYPE;
  v_agreement data.commercial_agreements%ROWTYPE;
  v_version data.commercial_agreement_versions%ROWTYPE;
  v_existing_agreement uuid;
  v_html text;
  v_missing text[];
  v_hash text;
  v_annex uuid;
  v_kind text := COALESCE(NULLIF(btrim(p_kind), ''), 'specific');
  v_auto_renew boolean := COALESCE(p_auto_renew, false);
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;
  IF p_client_op_id IS NULL THEN
    RAISE EXCEPTION 'client_op_id_required' USING ERRCODE = 'P0001';
  END IF;
  IF p_work_gate IS NULL OR p_work_gate NOT IN ('none', 'require_signed_agreement') THEN
    RAISE EXCEPTION 'invalid_work_gate' USING ERRCODE = 'P0001';
  END IF;
  IF v_kind NOT IN ('specific', 'recurring', 'framework') THEN
    RAISE EXCEPTION 'invalid_agreement_kind' USING ERRCODE = 'P0001';
  END IF;
  IF v_kind IN ('recurring', 'framework') AND p_ends_on IS NULL THEN
    RAISE EXCEPTION 'recurring_ends_on_required' USING ERRCODE = 'P0001';
  END IF;
  IF p_starts_on IS NOT NULL AND p_ends_on IS NOT NULL AND p_ends_on < p_starts_on THEN
    RAISE EXCEPTION 'invalid_agreement_dates' USING ERRCODE = 'P0001';
  END IF;
  IF p_notice_days IS NOT NULL AND p_notice_days <= 0 THEN
    RAISE EXCEPTION 'invalid_notice_days' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_doc FROM data.commercial_documents WHERE id = p_document_id;
  IF NOT FOUND OR NOT (data.jwt_user_tenants() ? v_doc.tenant_id::text) THEN
    RAISE EXCEPTION 'quote_not_found_or_access_denied' USING ERRCODE = 'P0001';
  END IF;
  IF COALESCE((
    SELECT tm.role FROM data.tenant_members tm
    WHERE tm.tenant_id = v_doc.tenant_id AND tm.user_id = v_uid AND tm.site_id IS NULL
    LIMIT 1
  ), '') NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'permission_denied:agreement_prepare' USING ERRCODE = 'P0001';
  END IF;
  IF v_doc.doc_type NOT IN ('quote', 'quote_amendment') THEN
    RAISE EXCEPTION 'invalid_doc_type' USING ERRCODE = 'P0001';
  END IF;
  IF v_doc.status <> 'accepted' THEN
    RAISE EXCEPTION 'quote_not_accepted' USING ERRCODE = 'P0001';
  END IF;
  IF v_doc.formalization_mode IS DISTINCT FROM 'separate_agreement' THEN
    RAISE EXCEPTION 'quote_not_separate_agreement' USING ERRCODE = 'P0001';
  END IF;
  IF v_doc.content_hash IS NULL OR btrim(v_doc.content_hash) = '' THEN
    RAISE EXCEPTION 'quote_content_hash_missing' USING ERRCODE = 'P0001';
  END IF;

  SELECT e.agreement_id INTO v_existing_agreement
  FROM data.commercial_agreement_events e
  WHERE e.tenant_id = v_doc.tenant_id AND e.client_op_id = p_client_op_id
  LIMIT 1;
  IF v_existing_agreement IS NOT NULL THEN
    RETURN v_existing_agreement;
  END IF;

  IF p_template_id IS NULL THEN
    RAISE EXCEPTION 'agreement_template_required' USING ERRCODE = 'P0001';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM data.document_templates t
    WHERE t.id = p_template_id
      AND t.is_active AND t.template_type = 'html'
      AND lower(COALESCE(t.category, '')) = 'commercial_agreement'
      AND (t.tenant_id = v_doc.tenant_id OR (t.tenant_id IS NULL AND t.is_platform_default))
  ) THEN
    RAISE EXCEPTION 'agreement_template_invalid' USING ERRCODE = 'P0001';
  END IF;

  SELECT l.html_content INTO v_html
  FROM data.document_template_locales l
  WHERE l.template_id = p_template_id
    AND l.locale = COALESCE(NULLIF(btrim(v_doc.locale), ''), 'ca')
    AND l.is_active AND l.mime_type = 'text/html';
  IF v_html IS NULL THEN
    SELECT l.html_content INTO v_html
    FROM data.document_template_locales l
    WHERE l.template_id = p_template_id AND l.locale = 'ca'
      AND l.is_active AND l.mime_type = 'text/html';
  END IF;
  v_missing := data.validate_commercial_agreement_template_locale(v_html, 'text/html');
  IF v_html IS NULL OR COALESCE(array_length(v_missing, 1), 0) > 0 THEN
    RAISE EXCEPTION 'agreement_template_invalid'
      USING ERRCODE = 'P0001', DETAIL = array_to_string(v_missing, ', ');
  END IF;

  v_hash := encode(
    extensions.digest(
      convert_to(
        v_doc.content_hash || '|' || COALESCE(v_doc.doc_number, '') || '|' || p_template_id::text,
        'UTF8'
      ),
      'sha256'
    ),
    'hex'
  );
  v_annex := v_doc.rendered_document_id;

  SELECT a.* INTO v_agreement
  FROM data.commercial_agreements a
  WHERE a.tenant_id = v_doc.tenant_id
    AND a.source_quote_id = v_doc.id
    AND a.status <> 'cancelled'
  ORDER BY a.created_at DESC
  LIMIT 1;

  IF FOUND THEN
    SELECT * INTO v_version
    FROM data.commercial_agreement_versions
    WHERE agreement_id = v_agreement.id
    ORDER BY version_no DESC
    LIMIT 1;
    IF v_version.status IN ('pending_signature', 'signed') THEN
      RETURN v_agreement.id;
    END IF;

    UPDATE data.commercial_agreements
    SET work_gate = p_work_gate, kind = v_kind
    WHERE id = v_agreement.id;

    UPDATE data.commercial_agreement_versions
    SET source_quote_content_hash = v_doc.content_hash,
        source_quote_document_id = v_annex,
        full_body_template_id = p_template_id,
        content_hash = v_hash,
        rendered_document_id = NULL,
        starts_on = p_starts_on,
        ends_on = p_ends_on,
        notice_days = p_notice_days,
        auto_renew = v_auto_renew
    WHERE id = v_version.id;

    INSERT INTO data.commercial_agreement_events (
      tenant_id, agreement_id, event_type, actor_id, client_op_id, payload
    ) VALUES (
      v_doc.tenant_id, v_agreement.id, 'prepared', v_uid, p_client_op_id,
      jsonb_build_object(
        'source_quote_id', v_doc.id,
        'full_body_template_id', p_template_id,
        'kind', v_kind,
        'auto_renew', v_auto_renew
      )
    );
    RETURN v_agreement.id;
  END IF;

  INSERT INTO data.commercial_agreements (
    tenant_id, client_id, kind, status, source_quote_id, work_gate, created_by
  ) VALUES (
    v_doc.tenant_id, v_doc.client_id, v_kind, 'pending_start',
    v_doc.id, p_work_gate, v_uid
  ) RETURNING * INTO v_agreement;

  INSERT INTO data.commercial_agreement_versions (
    tenant_id, agreement_id, version_no, status,
    source_quote_id, source_quote_content_hash, source_quote_document_id,
    full_body_template_id, content_hash,
    starts_on, ends_on, notice_days, auto_renew
  ) VALUES (
    v_doc.tenant_id, v_agreement.id, 1, 'draft',
    v_doc.id, v_doc.content_hash, v_annex,
    p_template_id, v_hash,
    p_starts_on, p_ends_on, p_notice_days, v_auto_renew
  ) RETURNING * INTO v_version;

  UPDATE data.commercial_agreements
  SET active_version_id = v_version.id
  WHERE id = v_agreement.id;

  INSERT INTO data.commercial_agreement_events (
    tenant_id, agreement_id, event_type, actor_id, client_op_id, payload
  ) VALUES (
    v_doc.tenant_id, v_agreement.id, 'prepared', v_uid, p_client_op_id,
    jsonb_build_object(
      'source_quote_id', v_doc.id,
      'full_body_template_id', p_template_id,
      'kind', v_kind,
      'auto_renew', v_auto_renew
    )
  );

  IF v_doc.project_id IS NOT NULL THEN
    SELECT * INTO v_project FROM data.projects WHERE id = v_doc.project_id;
    INSERT INTO data.commercial_agreement_projects (tenant_id, agreement_id, project_id)
    VALUES (v_doc.tenant_id, v_agreement.id, v_doc.project_id)
    ON CONFLICT (agreement_id, project_id) DO NOTHING;
    INSERT INTO data.commercial_agreement_events (
      tenant_id, agreement_id, event_type, actor_id, payload
    ) VALUES (
      v_doc.tenant_id, v_agreement.id, 'project_linked', v_uid,
      jsonb_build_object('project_id', v_doc.project_id)
    );
  END IF;

  RETURN v_agreement.id;
END;
$$;

REVOKE ALL ON FUNCTION api.prepare_agreement_from_quote(uuid, uuid, text, uuid, text, date, date, int, boolean)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.prepare_agreement_from_quote(uuid, uuid, text, uuid, text, date, date, int, boolean)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION api.create_framework_agreement(
  p_tenant_id uuid,
  p_client_id uuid,
  p_template_id uuid,
  p_work_gate text,
  p_client_op_id uuid,
  p_starts_on date DEFAULT NULL,
  p_ends_on date DEFAULT NULL,
  p_notice_days int DEFAULT NULL,
  p_locale text DEFAULT NULL,
  p_auto_renew boolean DEFAULT false
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_contact data.contacts%ROWTYPE;
  v_agreement data.commercial_agreements%ROWTYPE;
  v_version data.commercial_agreement_versions%ROWTYPE;
  v_existing uuid;
  v_html text;
  v_missing text[];
  v_hash text;
  v_locale text;
  v_auto_renew boolean := COALESCE(p_auto_renew, false);
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;
  IF p_client_op_id IS NULL THEN
    RAISE EXCEPTION 'client_op_id_required' USING ERRCODE = 'P0001';
  END IF;
  IF p_tenant_id IS NULL OR NOT (data.jwt_user_tenants() ? p_tenant_id::text) THEN
    RAISE EXCEPTION 'tenant_access_denied' USING ERRCODE = 'P0001';
  END IF;
  IF p_work_gate IS NULL OR p_work_gate NOT IN ('none', 'require_signed_agreement') THEN
    RAISE EXCEPTION 'invalid_work_gate' USING ERRCODE = 'P0001';
  END IF;
  IF p_ends_on IS NULL THEN
    RAISE EXCEPTION 'recurring_ends_on_required' USING ERRCODE = 'P0001';
  END IF;
  IF p_starts_on IS NOT NULL AND p_ends_on < p_starts_on THEN
    RAISE EXCEPTION 'invalid_agreement_dates' USING ERRCODE = 'P0001';
  END IF;
  IF p_notice_days IS NOT NULL AND p_notice_days <= 0 THEN
    RAISE EXCEPTION 'invalid_notice_days' USING ERRCODE = 'P0001';
  END IF;

  SELECT e.agreement_id INTO v_existing
  FROM data.commercial_agreement_events e
  WHERE e.tenant_id = p_tenant_id AND e.client_op_id = p_client_op_id
  LIMIT 1;
  IF v_existing IS NOT NULL THEN
    RETURN v_existing;
  END IF;

  IF COALESCE((
    SELECT tm.role FROM data.tenant_members tm
    WHERE tm.tenant_id = p_tenant_id AND tm.user_id = v_uid AND tm.site_id IS NULL
    LIMIT 1
  ), '') NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'permission_denied:agreement_prepare' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_contact FROM data.contacts WHERE id = p_client_id;
  IF NOT FOUND OR v_contact.tenant_id IS DISTINCT FROM p_tenant_id THEN
    RAISE EXCEPTION 'client_not_found' USING ERRCODE = 'P0001';
  END IF;

  IF p_template_id IS NULL THEN
    RAISE EXCEPTION 'agreement_template_required' USING ERRCODE = 'P0001';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM data.document_templates t
    WHERE t.id = p_template_id AND t.is_active AND t.template_type = 'html'
      AND lower(COALESCE(t.category, '')) = 'commercial_agreement'
      AND (t.tenant_id = p_tenant_id OR (t.tenant_id IS NULL AND t.is_platform_default))
  ) THEN
    RAISE EXCEPTION 'agreement_template_invalid' USING ERRCODE = 'P0001';
  END IF;

  v_locale := COALESCE(
    NULLIF(btrim(p_locale), ''),
    NULLIF(btrim(v_contact.preferred_locale), ''),
    'ca'
  );

  SELECT l.html_content INTO v_html
  FROM data.document_template_locales l
  WHERE l.template_id = p_template_id AND l.locale = v_locale
    AND l.is_active AND l.mime_type = 'text/html';
  IF v_html IS NULL THEN
    SELECT l.html_content INTO v_html
    FROM data.document_template_locales l
    WHERE l.template_id = p_template_id AND l.locale = 'ca'
      AND l.is_active AND l.mime_type = 'text/html';
  END IF;
  v_missing := data.validate_commercial_agreement_template_locale(v_html, 'text/html');
  IF v_html IS NULL OR COALESCE(array_length(v_missing, 1), 0) > 0 THEN
    RAISE EXCEPTION 'agreement_template_invalid'
      USING ERRCODE = 'P0001', DETAIL = array_to_string(v_missing, ', ');
  END IF;

  v_hash := encode(
    extensions.digest(
      convert_to(
        'framework|' || p_client_id::text || '|' || p_template_id::text
        || '|' || COALESCE(p_starts_on::text, '') || '|' || p_ends_on::text,
        'UTF8'
      ),
      'sha256'
    ),
    'hex'
  );

  INSERT INTO data.commercial_agreements (
    tenant_id, client_id, kind, status, source_quote_id, work_gate, created_by
  ) VALUES (
    p_tenant_id, p_client_id, 'framework', 'pending_start',
    NULL, p_work_gate, v_uid
  ) RETURNING * INTO v_agreement;

  INSERT INTO data.commercial_agreement_versions (
    tenant_id, agreement_id, version_no, status,
    source_quote_id, source_quote_content_hash, source_quote_document_id,
    full_body_template_id, content_hash, starts_on, ends_on, notice_days, auto_renew,
    terms_snapshot
  ) VALUES (
    p_tenant_id, v_agreement.id, 1, 'draft',
    NULL, NULL, NULL,
    p_template_id, v_hash, p_starts_on, p_ends_on, p_notice_days, v_auto_renew,
    jsonb_build_object('locale', v_locale, 'kind', 'framework')
  ) RETURNING * INTO v_version;

  UPDATE data.commercial_agreements
  SET active_version_id = v_version.id
  WHERE id = v_agreement.id;

  INSERT INTO data.commercial_agreement_events (
    tenant_id, agreement_id, event_type, actor_id, client_op_id, payload
  ) VALUES (
    p_tenant_id, v_agreement.id, 'prepared', v_uid, p_client_op_id,
    jsonb_build_object(
      'kind', 'framework',
      'full_body_template_id', p_template_id,
      'client_id', p_client_id,
      'auto_renew', v_auto_renew
    )
  );

  RETURN v_agreement.id;
END;
$$;

REVOKE ALL ON FUNCTION api.create_framework_agreement(uuid, uuid, uuid, text, uuid, date, date, int, text, boolean)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.create_framework_agreement(uuid, uuid, uuid, text, uuid, date, date, int, text, boolean)
  TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
