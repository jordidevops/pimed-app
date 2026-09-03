-- =============================================================================
-- Automation Engine V1.5 — Tancament de gaps (sense V2 API/webhooks)
-- RPCs de suport, events de document/signatura, WAIT timer, columnes DMS.
-- Depèn de: 20260712000004_automation_v1_blueprints.sql
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Columnes opcionals a documents (§16.4 — estructura reservada)
-- -----------------------------------------------------------------------------
DO $$ BEGIN
  CREATE TYPE data.document_approval_status AS ENUM (
    'none', 'pending', 'approved', 'rejected'
  );
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

ALTER TABLE data.documents
  ADD COLUMN IF NOT EXISTS approval_status data.document_approval_status NOT NULL DEFAULT 'none',
  ADD COLUMN IF NOT EXISTS approved_by     uuid REFERENCES data.profiles(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS approved_at     timestamptz;

-- -----------------------------------------------------------------------------
-- 2. wait_until a automation_runs (handler WAIT)
-- -----------------------------------------------------------------------------
ALTER TABLE data.automation_runs
  ADD COLUMN IF NOT EXISTS wait_until timestamptz;

CREATE INDEX IF NOT EXISTS automation_runs_wait_until_idx
  ON data.automation_runs (wait_until)
  WHERE status = 'WAITING_TIMER' AND wait_until IS NOT NULL;

-- -----------------------------------------------------------------------------
-- 3. Helper: projecte intern "Automatitzacions" per CREATE_TASK
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.ensure_automation_project(p_tenant_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_project_id uuid;
  v_owner_id   uuid;
BEGIN
  SELECT id INTO v_project_id
  FROM data.projects
  WHERE tenant_id = p_tenant_id
    AND type = 'internal'
    AND name = 'Automatitzacions'
  LIMIT 1;

  IF v_project_id IS NOT NULL THEN
    RETURN v_project_id;
  END IF;

  SELECT user_id INTO v_owner_id
  FROM data.tenant_members
  WHERE tenant_id = p_tenant_id
    AND role = 'owner'
    AND is_active = true
  ORDER BY created_at
  LIMIT 1;

  IF v_owner_id IS NULL THEN
    SELECT user_id INTO v_owner_id
    FROM data.tenant_members
    WHERE tenant_id = p_tenant_id AND is_active = true
    ORDER BY CASE role WHEN 'owner' THEN 0 WHEN 'manager' THEN 1 ELSE 2 END, created_at
    LIMIT 1;
  END IF;

  IF v_owner_id IS NULL THEN
    RAISE EXCEPTION 'no_active_member_for_tenant';
  END IF;

  INSERT INTO data.projects (tenant_id, type, name, description, status, visibility, created_by)
  VALUES (
    p_tenant_id, 'internal', 'Automatitzacions',
    'Projecte intern per tasques creades per workflows d''automatització',
    'draft', 'company', v_owner_id
  )
  RETURNING id INTO v_project_id;

  RETURN v_project_id;
END;
$$;

-- -----------------------------------------------------------------------------
-- 4. api.create_automation_task_service
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.create_automation_task_service(
  p_tenant_id            uuid,
  p_title                text,
  p_site_id              uuid    DEFAULT NULL,
  p_description          text    DEFAULT '',
  p_assignee_role        text    DEFAULT NULL,
  p_assignee_user_id     uuid    DEFAULT NULL,
  p_project_id           uuid    DEFAULT NULL,
  p_due_date_offset_days integer DEFAULT NULL,
  p_entity_type          text    DEFAULT NULL,
  p_entity_id            uuid    DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_project_id  uuid;
  v_assignee_id uuid;
  v_task_id     uuid;
  v_due_date    timestamptz;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  v_project_id := COALESCE(p_project_id, data.ensure_automation_project(p_tenant_id));

  v_assignee_id := p_assignee_user_id;
  IF v_assignee_id IS NULL AND p_assignee_role IS NOT NULL THEN
    SELECT tm.user_id INTO v_assignee_id
    FROM data.tenant_members tm
    WHERE tm.tenant_id = p_tenant_id
      AND tm.is_active = true
      AND tm.role::text = p_assignee_role
    ORDER BY tm.created_at
    LIMIT 1;
  END IF;

  IF p_due_date_offset_days IS NOT NULL THEN
    v_due_date := now() + (p_due_date_offset_days || ' days')::interval;
  END IF;

  INSERT INTO data.tasks (tenant_id, project_id, title, status, assignee_id, due_date)
  VALUES (p_tenant_id, v_project_id, p_title, 'todo', v_assignee_id, v_due_date)
  RETURNING id INTO v_task_id;

  RETURN jsonb_build_object('task_id', v_task_id, 'project_id', v_project_id);
END;
$$;

REVOKE ALL ON FUNCTION api.create_automation_task_service(uuid, text, uuid, text, text, uuid, uuid, integer, text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.create_automation_task_service(uuid, text, uuid, text, text, uuid, uuid, integer, text, uuid) TO service_role;

-- -----------------------------------------------------------------------------
-- 5. api.update_entity_field_service (whitelist)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.update_entity_field_service(
  p_tenant_id   uuid,
  p_entity_type text,
  p_entity_id   uuid,
  p_field       text,
  p_value       text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  IF p_entity_type = 'contact' AND p_field IN ('display_name', 'email', 'phone', 'source') THEN
    UPDATE data.contacts
    SET
      display_name = CASE WHEN p_field = 'display_name' THEN p_value ELSE display_name END,
      email        = CASE WHEN p_field = 'email'        THEN p_value ELSE email END,
      phone        = CASE WHEN p_field = 'phone'        THEN p_value ELSE phone END,
      source       = CASE WHEN p_field = 'source'       THEN p_value ELSE source END,
      updated_at   = now()
    WHERE id = p_entity_id AND tenant_id = p_tenant_id;

  ELSIF p_entity_type = 'employee' AND p_field IN ('status', 'full_name', 'email', 'job_title') THEN
    UPDATE data.employees
    SET
      status     = CASE WHEN p_field = 'status'     THEN p_value ELSE status END,
      full_name  = CASE WHEN p_field = 'full_name' THEN p_value ELSE full_name END,
      email      = CASE WHEN p_field = 'email'     THEN p_value ELSE email END,
      job_title  = CASE WHEN p_field = 'job_title' THEN p_value ELSE job_title END,
      updated_at = now()
    WHERE id = p_entity_id AND tenant_id = p_tenant_id;

  ELSIF p_entity_type = 'document' AND p_field IN ('title', 'approval_status') THEN
    UPDATE data.documents
    SET
      title            = CASE WHEN p_field = 'title'            THEN p_value ELSE title END,
      approval_status  = CASE WHEN p_field = 'approval_status'  THEN p_value::data.document_approval_status ELSE approval_status END,
      updated_at       = now()
    WHERE id = p_entity_id AND tenant_id = p_tenant_id;

  ELSE
    RAISE EXCEPTION 'field_not_allowed: % on %', p_field, p_entity_type;
  END IF;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'entity_not_found';
  END IF;

  RETURN jsonb_build_object('updated', true, 'entity_type', p_entity_type, 'field', p_field);
END;
$$;

REVOKE ALL ON FUNCTION api.update_entity_field_service(uuid, text, uuid, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.update_entity_field_service(uuid, text, uuid, text, text) TO service_role;

-- -----------------------------------------------------------------------------
-- 6. api.create_calendar_event_service (wrapper service_role)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.create_calendar_event_service(
  p_tenant_id       uuid,
  p_title           text,
  p_start_at        timestamptz,
  p_site_id         uuid        DEFAULT NULL,
  p_end_at          timestamptz DEFAULT NULL,
  p_description     text        DEFAULT NULL,
  p_all_day         boolean     DEFAULT false,
  p_entity_type     text        DEFAULT NULL,
  p_entity_id       uuid        DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, pgmq, public
AS $$
DECLARE
  v_event_id    uuid;
  v_entity_type text := COALESCE(NULLIF(p_entity_type, ''), 'automation');
  v_entity_id   uuid := COALESCE(p_entity_id, p_tenant_id);
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  INSERT INTO data.calendar_events (
    tenant_id, site_id, title, description,
    start_at, end_at, all_day,
    entity_type, entity_id, required_permissions, owner_id
  ) VALUES (
    p_tenant_id, p_site_id, p_title, p_description,
    p_start_at, COALESCE(p_end_at, p_start_at + interval '1 hour'),
    p_all_day, v_entity_type, v_entity_id, ARRAY['calendar.view'], NULL
  )
  RETURNING id INTO v_event_id;

  RETURN jsonb_build_object('event_id', v_event_id);
END;
$$;

REVOKE ALL ON FUNCTION api.create_calendar_event_service(uuid, text, timestamptz, uuid, timestamptz, text, boolean, text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.create_calendar_event_service(uuid, text, timestamptz, uuid, timestamptz, text, boolean, text, uuid) TO service_role;

-- -----------------------------------------------------------------------------
-- 7. api.get_template_locale_for_automation
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.get_template_locale_for_automation(
  p_tenant_id   uuid,
  p_template_id uuid,
  p_locale      text DEFAULT 'ca'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_row record;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  SELECT tl.id AS locale_id, tl.template_id, tl.locale, t.name AS template_name
  INTO v_row
  FROM data.document_template_locales tl
  JOIN data.document_templates t ON t.id = tl.template_id
  WHERE tl.template_id = p_template_id
    AND t.tenant_id = p_tenant_id
    AND tl.locale = COALESCE(NULLIF(p_locale, ''), 'ca')
  LIMIT 1;

  IF NOT FOUND THEN
    SELECT tl.id AS locale_id, tl.template_id, tl.locale, t.name AS template_name
    INTO v_row
    FROM data.document_template_locales tl
    JOIN data.document_templates t ON t.id = tl.template_id
    WHERE tl.template_id = p_template_id
      AND t.tenant_id = p_tenant_id
    ORDER BY tl.locale
    LIMIT 1;
  END IF;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'template_locale_not_found';
  END IF;

  RETURN jsonb_build_object(
    'locale_id',    v_row.locale_id,
    'template_id',  v_row.template_id,
    'locale',       v_row.locale,
    'template_name', v_row.template_name
  );
END;
$$;

REVOKE ALL ON FUNCTION api.get_template_locale_for_automation(uuid, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.get_template_locale_for_automation(uuid, uuid, text) TO service_role;

-- -----------------------------------------------------------------------------
-- 8. api.automation_start_generate_document — encua PDF job amb metadata automation
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.automation_start_generate_document(
  p_tenant_id        uuid,
  p_template_id      uuid,
  p_workflow_run_id  uuid,
  p_step_run_id      uuid,
  p_locale           text    DEFAULT 'ca',
  p_folder_id        uuid    DEFAULT NULL,
  p_entity_type      text    DEFAULT NULL,
  p_entity_id        uuid    DEFAULT NULL,
  p_variables        jsonb   DEFAULT '{}'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_locale      jsonb;
  v_locale_id   uuid;
  v_title       text;
  v_job         jsonb;
  v_idem        text;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  v_locale := api.get_template_locale_for_automation(p_tenant_id, p_template_id, p_locale);
  v_locale_id := (v_locale->>'locale_id')::uuid;
  v_title     := COALESCE(v_locale->>'template_name', 'Document generat');
  v_idem      := 'auto-gen:' || p_step_run_id::text;

  v_job := api.create_pdf_job(
    p_tenant_id,
    'template_locale',
    v_locale_id,
    'html',
    v_title,
    'pdf',
    p_folder_id,
    v_idem,
    0,
    jsonb_build_object(
      'automation', jsonb_build_object(
        'workflow_run_id', p_workflow_run_id,
        'step_run_id',     p_step_run_id,
        'entity_type',     p_entity_type,
        'entity_id',       p_entity_id,
        'template_id',     p_template_id,
        'variables',       COALESCE(p_variables, '{}')
      )
    ),
    NULL,
    NULL
  );

  RETURN jsonb_build_object(
    'job_id',      v_job->>'job_id',
    'locale_id',   v_locale_id,
    'template_id', p_template_id,
    'status',      'queued'
  );
END;
$$;

REVOKE ALL ON FUNCTION api.automation_start_generate_document(uuid, uuid, uuid, uuid, text, uuid, text, uuid, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.automation_start_generate_document(uuid, uuid, uuid, uuid, text, uuid, text, uuid, jsonb) TO service_role;

-- -----------------------------------------------------------------------------
-- 9. api.automation_resume_step_service — completa step async i encua el següent
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.automation_resume_step_service(
  p_step_run_id uuid,
  p_output      jsonb DEFAULT '{}',
  p_error       text  DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, pgmq, public
AS $$
DECLARE
  v_step        data.automation_step_runs%ROWTYPE;
  v_run         data.automation_runs%ROWTYPE;
  v_workflow    data.automation_workflows%ROWTYPE;
  v_step_def    jsonb;
  v_next_id     text;
  v_next_run    data.automation_step_runs%ROWTYPE;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  SELECT * INTO v_step FROM data.automation_step_runs WHERE id = p_step_run_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'step_run_not_found'; END IF;

  SELECT * INTO v_run FROM data.automation_runs WHERE id = v_step.workflow_run_id;
  SELECT * INTO v_workflow FROM data.automation_workflows WHERE id = v_run.workflow_id;

  IF p_error IS NOT NULL THEN
    UPDATE data.automation_step_runs
    SET status = 'FAILED', error = p_error, completed_at = now()
    WHERE id = p_step_run_id;

    UPDATE data.automation_runs
    SET status = 'FAILED', error = p_error, completed_at = now()
    WHERE id = v_run.id;
    RETURN;
  END IF;

  UPDATE data.automation_step_runs
  SET status = 'COMPLETED', output = COALESCE(p_output, '{}'), completed_at = now()
  WHERE id = p_step_run_id;

  SELECT elem INTO v_step_def
  FROM jsonb_array_elements(COALESCE(v_workflow.steps, '[]'::jsonb)) elem
  WHERE elem->>'id' = v_step.step_id
  LIMIT 1;

  v_next_id := v_step_def->>'on_success';

  IF v_next_id IS NULL OR v_next_id = 'END_OK' THEN
    UPDATE data.automation_runs SET status = 'COMPLETED', completed_at = now(), wait_until = NULL
    WHERE id = v_run.id;
    RETURN;
  END IF;

  IF v_next_id = 'END_FAIL' THEN
    UPDATE data.automation_runs SET status = 'FAILED', error = 'on_success=END_FAIL', completed_at = now()
    WHERE id = v_run.id;
    RETURN;
  END IF;

  SELECT * INTO v_next_run
  FROM data.automation_step_runs
  WHERE workflow_run_id = v_run.id AND step_id = v_next_id
  LIMIT 1;

  IF NOT FOUND THEN
    UPDATE data.automation_runs SET status = 'FAILED', error = 'next_step_not_found: ' || v_next_id
    WHERE id = v_run.id;
    RETURN;
  END IF;

  UPDATE data.automation_runs
  SET status = 'RUNNING', current_step_id = v_next_id, wait_until = NULL
  WHERE id = v_run.id;

  PERFORM api.enqueue_automation_step(
    v_run.tenant_id, v_run.id, v_next_run.id,
    v_next_run.step_id, v_next_run.step_type, 1
  );
END;
$$;

REVOKE ALL ON FUNCTION api.automation_resume_step_service(uuid, jsonb, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.automation_resume_step_service(uuid, jsonb, text) TO service_role;

-- -----------------------------------------------------------------------------
-- 10. Trigger: PDF job completat → DOCUMENT_GENERATED + resume automation step
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.trg_pdf_job_automation_complete()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_auto        jsonb;
  v_step_run_id uuid;
  v_doc_id      uuid;
  v_ver_id      uuid;
  v_storage     text;
BEGIN
  IF NEW.status <> 'completed' OR OLD.status = 'completed' THEN
    RETURN NEW;
  END IF;

  v_auto := NEW.metadata -> 'automation';
  IF v_auto IS NULL OR v_auto = 'null'::jsonb THEN
    RETURN NEW;
  END IF;

  v_step_run_id := (v_auto->>'step_run_id')::uuid;
  v_doc_id      := NEW.result_document_id;
  v_ver_id      := NEW.result_version_id;

  SELECT dv.file_path_or_url INTO v_storage
  FROM data.document_versions dv
  WHERE dv.id = v_ver_id;

  PERFORM data.log_audit_event(
    NEW.tenant_id, NULL, NULL,
    'DOCUMENT_GENERATED', 'document', v_doc_id,
    jsonb_build_object(
      'document_id',       v_doc_id,
      'version_id',        v_ver_id,
      'template_id',       v_auto->>'template_id',
      'storage_path',      v_storage,
      'workflow_run_id',   v_auto->>'workflow_run_id',
      'entity_type',       v_auto->>'entity_type',
      'entity_id',         v_auto->>'entity_id',
      'variables',         COALESCE(v_auto->'variables', '{}')
    )
  );

  PERFORM api.automation_resume_step_service(
    v_step_run_id,
    jsonb_build_object(
      'document_id',       v_doc_id,
      'version_id',        v_ver_id,
      'storage_path',      v_storage,
      'template_id',       v_auto->>'template_id',
      'job_id',            NEW.id
    ),
    NULL
  );

  RETURN NEW;
EXCEPTION WHEN others THEN
  RAISE WARNING '[automation] trg_pdf_job_automation_complete: %', SQLERRM;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_pdf_job_automation_complete ON data.document_pdf_jobs;
CREATE TRIGGER trg_pdf_job_automation_complete
  AFTER UPDATE OF status ON data.document_pdf_jobs
  FOR EACH ROW EXECUTE FUNCTION data.trg_pdf_job_automation_complete();

-- -----------------------------------------------------------------------------
-- 11. api.automation_send_for_signing_service (firma nativa — primer signant)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.automation_send_for_signing_service(
  p_tenant_id       uuid,
  p_document_id     uuid,
  p_signers         jsonb,
  p_workflow_run_id uuid DEFAULT NULL,
  p_step_run_id     uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, extensions, public
AS $$
DECLARE
  v_doc         data.documents%ROWTYPE;
  v_version_id  uuid;
  v_signer      jsonb;
  v_name        text;
  v_email       text;
  v_role        text;
  v_group_id    uuid := gen_random_uuid();
  v_session     jsonb;
  v_sub_id      uuid;
  v_ext_id      text;
  v_token       text;
  v_signing_url text;
  v_portal_base text;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  SELECT * INTO v_doc FROM data.documents WHERE id = p_document_id AND tenant_id = p_tenant_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'document_not_found'; END IF;

  SELECT dv.id INTO v_version_id
  FROM data.document_versions dv
  WHERE dv.document_id = p_document_id
  ORDER BY dv.version_number DESC
  LIMIT 1;

  IF v_version_id IS NULL THEN
    RAISE EXCEPTION 'document_has_no_version';
  END IF;

  v_signer := COALESCE(p_signers->0, p_signers);
  v_name  := COALESCE(v_signer->>'name', v_signer->>'full_name', '');
  v_email := COALESCE(v_signer->>'email', '');
  v_role  := COALESCE(v_signer->>'role', 'signer');

  IF v_email = '' THEN
    RAISE EXCEPTION 'signer_email_required';
  END IF;

  v_ext_id := 'auto-sign:' || COALESCE(p_step_run_id::text, gen_random_uuid()::text);

  v_sub_id := api.create_signing_submission(
    p_tenant_id, 'document_existing', p_document_id, v_version_id, NULL,
    v_doc.title, v_ext_id,
    jsonb_build_array(jsonb_build_object(
      'email', v_email, 'name', v_name, 'role', v_role, 'order', 0, 'status', 'pending'
    )),
    NULL, now(),
    jsonb_build_object(
      'automation', jsonb_build_object(
        'workflow_run_id', p_workflow_run_id,
        'step_run_id',     p_step_run_id
      )
    ),
    'native', v_group_id, 'email'
  );

  v_session := api.create_signing_session(
    p_tenant_id, v_version_id, 'remote',
    v_name, v_email, v_role, NULL, NULL,
    v_group_id, 0, 1
  );

  v_token := v_session->>'token';
  v_portal_base := COALESCE(
    NULLIF(current_setting('app.tenant_portal_url', true), ''),
    NULLIF(current_setting('app.supabase_url', true), ''),
    ''
  );
  v_signing_url := v_portal_base || '/sign/' || v_token;

  INSERT INTO data.signing_submitters (
    submission_id, tenant_id, signer_order, role, email, name, signing_url, status
  ) VALUES (
    v_sub_id, p_tenant_id, 0, v_role, v_email, COALESCE(NULLIF(v_name, ''), v_email),
    v_signing_url, 'pending'
  )
  ON CONFLICT (submission_id, signer_order) DO UPDATE
  SET signing_url = EXCLUDED.signing_url, email = EXCLUDED.email, name = EXCLUDED.name;

  BEGIN
    PERFORM api.enqueue_signing_notification(v_sub_id, 0, 'automation');
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING '[automation] enqueue_signing_notification: %', SQLERRM;
  END;

  RETURN jsonb_build_object(
    'submission_id', v_sub_id,
    'session_id',    v_session->>'session_id',
    'document_id',   p_document_id,
    'version_id',    v_version_id
  );
END;
$$;

REVOKE ALL ON FUNCTION api.automation_send_for_signing_service(uuid, uuid, jsonb, uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.automation_send_for_signing_service(uuid, uuid, jsonb, uuid, uuid) TO service_role;

-- -----------------------------------------------------------------------------
-- 12. Trigger: signing_submissions → events d'automatització
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.trg_signing_submission_automation_audit()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_action text;
  v_auto   jsonb;
BEGIN
  IF NEW.status IS NOT DISTINCT FROM OLD.status THEN
    RETURN NEW;
  END IF;

  IF NEW.status = 'completed' THEN
    v_action := 'DOCUMENT_SIGNATURE_ACCEPTED';
  ELSIF NEW.status = 'declined' THEN
    v_action := 'DOCUMENT_SIGNATURE_REJECTED';
  ELSE
    RETURN NEW;
  END IF;

  v_auto := COALESCE(NEW.metadata, '{}'::jsonb) -> 'automation';

  PERFORM data.log_audit_event(
    NEW.tenant_id, NULL, NULL,
    v_action, 'document', NEW.source_document_id,
    jsonb_build_object(
      'submission_id',   NEW.id,
      'document_id',     NEW.source_document_id,
      'document_title',  NEW.document_title,
      'template_id',     NEW.source_template_locale_id,
      'workflow_run_id', v_auto->>'workflow_run_id',
      'step_run_id',     v_auto->>'step_run_id'
    )
  );

  -- Reprendre step WAITING_TIMER si hi ha metadata automation
  IF v_auto IS NOT NULL AND v_auto ? 'step_run_id' THEN
  BEGIN
    PERFORM api.automation_resume_step_service(
      (v_auto->>'step_run_id')::uuid,
      jsonb_build_object(
        'submission_id', NEW.id,
        'status',        NEW.status::text,
        'document_id',   NEW.source_document_id
      ),
      CASE WHEN v_action = 'DOCUMENT_SIGNATURE_REJECTED' THEN 'signature_rejected' ELSE NULL END
    );
  EXCEPTION WHEN others THEN
    RAISE WARNING '[automation] resume after signing: %', SQLERRM;
  END;
  END IF;

  RETURN NEW;
EXCEPTION WHEN others THEN
  RAISE WARNING '[automation] trg_signing_submission_automation_audit: %', SQLERRM;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_signing_submission_automation_audit ON data.signing_submissions;
CREATE TRIGGER trg_signing_submission_automation_audit
  AFTER UPDATE OF status ON data.signing_submissions
  FOR EACH ROW EXECUTE FUNCTION data.trg_signing_submission_automation_audit();

-- -----------------------------------------------------------------------------
-- 13. api.schedule_automation_wait + resume de timers (WAIT handler / pg_cron)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.schedule_automation_wait(
  p_run_id          uuid,
  p_step_run_id     uuid,
  p_wait_until      timestamptz DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  UPDATE data.automation_step_runs
  SET status = 'WAITING_TIMER', completed_at = NULL, output = COALESCE(output, '{}')
  WHERE id = p_step_run_id;

  UPDATE data.automation_runs
  SET status = 'WAITING_TIMER', wait_until = p_wait_until, current_step_id = (
    SELECT step_id FROM data.automation_step_runs WHERE id = p_step_run_id
  )
  WHERE id = p_run_id;
END;
$$;

REVOKE ALL ON FUNCTION api.schedule_automation_wait(uuid, uuid, timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.schedule_automation_wait(uuid, uuid, timestamptz) TO service_role;

CREATE OR REPLACE FUNCTION api.process_automation_wait_timers()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_run   record;
  v_count int := 0;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  FOR v_run IN
    SELECT r.id AS run_id, sr.id AS step_run_id, sr.step_id, sr.step_type
    FROM data.automation_runs r
    JOIN data.automation_step_runs sr ON sr.workflow_run_id = r.id AND sr.status = 'WAITING_TIMER'
    WHERE r.status = 'WAITING_TIMER'
      AND r.wait_until IS NOT NULL
      AND r.wait_until <= now()
    LIMIT 100
  LOOP
    PERFORM api.automation_resume_step_service(
      v_run.step_run_id,
      jsonb_build_object('wait_completed', true),
      NULL
    );
    v_count := v_count + 1;
  END LOOP;

  RETURN jsonb_build_object('resumed', v_count);
END;
$$;

REVOKE ALL ON FUNCTION api.process_automation_wait_timers() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.process_automation_wait_timers() TO service_role;

-- -----------------------------------------------------------------------------
-- 14. api.emit_scheduled_automation_trigger — per SCHEDULED_DAILY
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.emit_scheduled_automation_trigger(
  p_tenant_id   uuid,
  p_event_type  text DEFAULT 'SCHEDULED_DAILY'
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  PERFORM data.log_audit_event(
    p_tenant_id, NULL, NULL,
    p_event_type, 'scheduled', NULL,
    jsonb_build_object('scheduled_at', now(), 'source', 'process-date-triggers')
  );
END;
$$;

REVOKE ALL ON FUNCTION api.emit_scheduled_automation_trigger(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.emit_scheduled_automation_trigger(uuid, text) TO service_role;

-- -----------------------------------------------------------------------------
-- 14b. Snapshot d'entitat per al context-builder
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.get_entity_snapshot_for_automation(
  p_tenant_id   uuid,
  p_entity_type text,
  p_entity_id   uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_row jsonb;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  IF p_entity_type = 'contact' THEN
    SELECT to_jsonb(c) INTO v_row
    FROM (
      SELECT id, tenant_id, site_id, kind, display_name, given_name, family_name,
             email, phone, tags, metadata, owner_user_id
      FROM data.contacts
      WHERE id = p_entity_id AND tenant_id = p_tenant_id
    ) c;

  ELSIF p_entity_type = 'employee' THEN
    SELECT to_jsonb(e) INTO v_row
    FROM (
      SELECT id, tenant_id, site_id, user_id, full_name, email, phone,
             job_title, status, starts_on, ends_on, metadata
      FROM data.employees
      WHERE id = p_entity_id AND tenant_id = p_tenant_id
    ) e;

  ELSIF p_entity_type = 'document' THEN
    SELECT to_jsonb(d) INTO v_row
    FROM (
      SELECT id, tenant_id, site_id, folder_id, title, entity_type, entity_id,
             approval_status, approved_by, approved_at
      FROM data.documents
      WHERE id = p_entity_id AND tenant_id = p_tenant_id
    ) d;

  ELSE
    RETURN '{}'::jsonb;
  END IF;

  RETURN COALESCE(v_row, '{}'::jsonb);
END;
$$;

REVOKE ALL ON FUNCTION api.get_entity_snapshot_for_automation(uuid, text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.get_entity_snapshot_for_automation(uuid, text, uuid) TO service_role;

-- -----------------------------------------------------------------------------
-- 14c. DATE_FIELD_REACHED — employees.ends_on (cas comú)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.emit_date_field_triggers_for_tenant(
  p_tenant_id   uuid,
  p_field_key   text,
  p_days_ahead  integer DEFAULT 0
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_target date := (CURRENT_DATE + COALESCE(p_days_ahead, 0));
  v_emp    record;
  v_count  integer := 0;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  IF p_field_key = 'employees.ends_on' THEN
    FOR v_emp IN
      SELECT id, full_name, email, ends_on
      FROM data.employees
      WHERE tenant_id = p_tenant_id
        AND status = 'active'
        AND ends_on = v_target
    LOOP
      PERFORM data.log_audit_event(
        p_tenant_id, NULL, NULL,
        'DATE_FIELD_REACHED', 'employee', v_emp.id,
        jsonb_build_object(
          'field_key', p_field_key,
          'target_date', v_target,
          'full_name', v_emp.full_name,
          'email', v_emp.email,
          'ends_on', v_emp.ends_on
        )
      );
      v_count := v_count + 1;
    END LOOP;
  END IF;

  RETURN v_count;
END;
$$;

REVOKE ALL ON FUNCTION api.emit_date_field_triggers_for_tenant(uuid, text, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.emit_date_field_triggers_for_tenant(uuid, text, integer) TO service_role;

-- pg_cron: reprendre timers WAIT caducats (cada 5 min si disponible)
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule(jobid)
    FROM cron.job
    WHERE jobname = 'automation_wait_timers';

    PERFORM cron.schedule(
      'automation_wait_timers',
      '*/5 * * * *',
      $cron$SELECT api.process_automation_wait_timers();$cron$
    );
  END IF;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING '[automation] pg_cron wait timers: %', SQLERRM;
END $$;

-- -----------------------------------------------------------------------------
-- 15. HUMAN_APPROVAL → actualitza approval_status del document (si aplica)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.create_automation_pending_approval_service(
  p_step_run_id          uuid,
  p_workflow_run_id      uuid,
  p_tenant_id            uuid,
  p_site_id              uuid     DEFAULT NULL,
  p_assigned_to_role     text     DEFAULT NULL,
  p_assigned_to_user_id  uuid     DEFAULT NULL,
  p_due_hours            integer  DEFAULT 24,
  p_context_preview      jsonb    DEFAULT '{}',
  p_title                text     DEFAULT 'Aprovació requerida'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_approval_id uuid;
  v_entity_id   uuid;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  INSERT INTO data.automation_pending_approvals (
    step_run_id, workflow_run_id, tenant_id,
    assigned_to_user_id, assigned_to_role,
    context_preview, title, status, due_at
  ) VALUES (
    p_step_run_id, p_workflow_run_id, p_tenant_id,
    p_assigned_to_user_id, p_assigned_to_role,
    COALESCE(p_context_preview, '{}'), COALESCE(p_title, 'Aprovació requerida'),
    'PENDING', now() + (p_due_hours || ' hours')::interval
  )
  RETURNING id INTO v_approval_id;

  v_entity_id := (p_context_preview->>'document_id')::uuid;
  IF v_entity_id IS NOT NULL THEN
    UPDATE data.documents
    SET approval_status = 'pending', updated_at = now()
    WHERE id = v_entity_id AND tenant_id = p_tenant_id;
  END IF;

  RETURN jsonb_build_object('approval_id', v_approval_id);
END;
$$;

REVOKE ALL ON FUNCTION api.create_automation_pending_approval_service(uuid, uuid, uuid, uuid, text, uuid, integer, jsonb, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.create_automation_pending_approval_service(uuid, uuid, uuid, uuid, text, uuid, integer, jsonb, text) TO service_role;

-- Actualitzar resolve_automation_approval per sincronitzar document.approval_status
CREATE OR REPLACE FUNCTION api.resolve_automation_approval(
  p_approval_id          uuid,
  p_resolution           text,
  p_comment              text DEFAULT NULL,
  p_reassign_to_user_id  uuid DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, pgmq, public
AS $$
DECLARE
  v_tenant_id   uuid := data.active_tenant_id();
  v_user_id     uuid := auth.uid();
  v_approval    data.automation_pending_approvals%ROWTYPE;
  v_step_run    data.automation_step_runs%ROWTYPE;
  v_run         data.automation_runs%ROWTYPE;
  v_workflow    data.automation_workflows%ROWTYPE;
  v_step_def    jsonb;
  v_next_step_id text;
  v_next_step_run data.automation_step_runs%ROWTYPE;
  v_doc_id      uuid;
BEGIN
  IF v_tenant_id IS NULL OR v_user_id IS NULL THEN
    RAISE EXCEPTION 'unauthenticated';
  END IF;

  SELECT * INTO v_approval
  FROM data.automation_pending_approvals
  WHERE id = p_approval_id AND tenant_id = v_tenant_id AND status = 'PENDING';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'approval_not_found_or_not_pending';
  END IF;

  IF p_resolution NOT IN ('approved', 'rejected', 'reassigned') THEN
    RAISE EXCEPTION 'invalid_resolution: %', p_resolution;
  END IF;

  v_doc_id := (v_approval.context_preview->>'document_id')::uuid;

  IF p_resolution = 'reassigned' THEN
    IF p_reassign_to_user_id IS NULL THEN RAISE EXCEPTION 'reassign_requires_user_id'; END IF;
    UPDATE data.automation_pending_approvals
    SET assigned_to_user_id = p_reassign_to_user_id, status = 'PENDING', resolution_comment = p_comment
    WHERE id = p_approval_id;
    RETURN;
  END IF;

  UPDATE data.automation_pending_approvals
  SET
    status             = CASE WHEN p_resolution = 'approved' THEN 'APPROVED' ELSE 'REJECTED' END,
    resolved_by        = v_user_id,
    resolved_at        = now(),
    resolution_comment = p_comment
  WHERE id = p_approval_id;

  IF v_doc_id IS NOT NULL THEN
    UPDATE data.documents
    SET
      approval_status = CASE WHEN p_resolution = 'approved' THEN 'approved' ELSE 'rejected' END,
      approved_by     = v_user_id,
      approved_at     = now(),
      updated_at      = now()
    WHERE id = v_doc_id AND tenant_id = v_tenant_id;
  END IF;

  SELECT * INTO v_step_run FROM data.automation_step_runs WHERE id = v_approval.step_run_id;
  SELECT * INTO v_run      FROM data.automation_runs       WHERE id = v_approval.workflow_run_id;

  UPDATE data.automation_step_runs
  SET
    status           = CASE WHEN p_resolution = 'approved' THEN 'COMPLETED' ELSE 'FAILED' END::data.automation_step_status,
    approved_by      = v_user_id,
    approved_at        = now(),
    approval_comment = p_comment,
    completed_at     = now()
  WHERE id = v_approval.step_run_id;

  IF p_resolution = 'rejected' THEN
    UPDATE data.automation_runs
    SET status = 'FAILED', error = 'Human approval rejected', completed_at = now()
    WHERE id = v_approval.workflow_run_id;
    RETURN;
  END IF;

  SELECT * INTO v_workflow FROM data.automation_workflows WHERE id = v_run.workflow_id;
  SELECT elem INTO v_step_def
  FROM jsonb_array_elements(COALESCE(v_workflow.steps, '[]'::jsonb)) AS elem
  WHERE elem->>'id' = v_step_run.step_id LIMIT 1;

  v_next_step_id := v_step_def->>'on_success';

  IF v_next_step_id IS NULL OR v_next_step_id = 'END_OK' THEN
    UPDATE data.automation_runs SET status = 'COMPLETED', completed_at = now() WHERE id = v_approval.workflow_run_id;
    RETURN;
  END IF;

  IF v_next_step_id = 'END_FAIL' THEN
    UPDATE data.automation_runs SET status = 'FAILED', error = 'on_success=END_FAIL', completed_at = now() WHERE id = v_approval.workflow_run_id;
    RETURN;
  END IF;

  SELECT * INTO v_next_step_run
  FROM data.automation_step_runs
  WHERE workflow_run_id = v_approval.workflow_run_id AND step_id = v_next_step_id LIMIT 1;

  IF NOT FOUND THEN
    UPDATE data.automation_runs SET status = 'FAILED', error = 'next_step_run_not_found: ' || v_next_step_id WHERE id = v_approval.workflow_run_id;
    RETURN;
  END IF;

  UPDATE data.automation_runs SET status = 'RUNNING', current_step_id = v_next_step_id WHERE id = v_approval.workflow_run_id;

  PERFORM pgmq.send('automation_queue', jsonb_build_object(
    'task', 'execute_step', 'tenant_id', v_tenant_id,
    'idempotency_key', 'step:' || v_next_step_run.id::text || ':1',
    'workflow_run_id', v_approval.workflow_run_id,
    'step_run_id', v_next_step_run.id, 'step_id', v_next_step_id,
    'step_type', v_next_step_run.step_type, 'attempt_number', 1,
    'enqueued_at', now()
  ));
END;
$$;

NOTIFY pgrst, 'reload schema';
