-- =============================================================================
-- M-EC-OPS2 — Items 3-5 residual EC/ELM
--   3) CONTRACT_FULLY_SIGNED event on signature completion + 'Contracte — signat' blueprint
--   4) 'Offboarding d'empleats' blueprint on EMPLOYEE_LIFECYCLE_CHANGED to=offboarding
--   +) api.verify_employee_domain_crons() — runbook helper per staging/prod
-- Nota: el "WAIT fins a fully signed" segueix diferit (WAIT és només per temporitzador);
--       aquí només emetem l'esdeveniment perquè un blueprint hi pugui reaccionar.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. notice_log accepta el nou tipus 'fully_signed' (dedupe idempotent)
-- ---------------------------------------------------------------------------
ALTER TABLE data.employment_contract_notice_log
  DROP CONSTRAINT IF EXISTS employment_contract_notice_log_notice_kind_check;

ALTER TABLE data.employment_contract_notice_log
  ADD CONSTRAINT employment_contract_notice_log_notice_kind_check
  CHECK (notice_kind IN (
    'expiring',
    'activation_blocked',
    'activated',
    'ended',
    'fully_signed'
  ));

-- ---------------------------------------------------------------------------
-- 2. Helper: emet CONTRACT_FULLY_SIGNED (idempotent via notice_log)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.emit_employment_contract_fully_signed(
  p_contract_id uuid
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_c data.employment_contracts%ROWTYPE;
  v_site uuid;
BEGIN
  SELECT * INTO v_c FROM data.employment_contracts WHERE id = p_contract_id;
  IF NOT FOUND THEN
    RETURN false;
  END IF;

  SELECT coalesce(v_c.site_id, e.site_id) INTO v_site
  FROM data.employees e WHERE e.id = v_c.employee_id;

  RETURN data.try_employment_contract_notice(
    v_c.tenant_id,
    v_c.id,
    v_site,
    'fully_signed',
    0,
    'CONTRACT_FULLY_SIGNED',
    jsonb_build_object(
      'employee_id', v_c.employee_id,
      'contract_number', v_c.contract_number,
      'starts_on', v_c.starts_on,
      'fully_signed_at', coalesce(v_c.fully_signed_at, now())
    )
  );
END;
$$;

COMMENT ON FUNCTION data.emit_employment_contract_fully_signed(uuid) IS
  'Item 3: emet CONTRACT_FULLY_SIGNED al bus workflow quan un contracte queda plenament signat.';

REVOKE ALL ON FUNCTION data.emit_employment_contract_fully_signed(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.emit_employment_contract_fully_signed(uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 3. Trigger de firma: afegeix emissió FULLY_SIGNED en completar
--    (idèntic a EC-5 + emissió a la branca 'completed')
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.trg_sync_employment_contract_signing()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_doc_id uuid;
  v_cid uuid;
BEGIN
  IF NEW.status IS NOT DISTINCT FROM OLD.status THEN
    RETURN NEW;
  END IF;

  IF NEW.status = 'completed' THEN
    IF NEW.result_document_version_id IS NOT NULL THEN
      SELECT document_id INTO v_doc_id
      FROM data.document_versions
      WHERE id = NEW.result_document_version_id;
    END IF;

    UPDATE data.employment_contracts c
    SET
      signature_status = 'completed',
      fully_signed_at = coalesce(c.fully_signed_at, now()),
      final_document_version_id = coalesce(NEW.result_document_version_id, c.final_document_version_id),
      generated_document_id = coalesce(v_doc_id, c.generated_document_id),
      updated_at = now()
    WHERE c.signing_submission_id = NEW.id;

    -- Item 3: emet CONTRACT_FULLY_SIGNED per cada contracte afectat
    FOR v_cid IN
      SELECT id FROM data.employment_contracts WHERE signing_submission_id = NEW.id
    LOOP
      PERFORM data.emit_employment_contract_fully_signed(v_cid);
    END LOOP;

  ELSIF NEW.status = 'declined' THEN
    UPDATE data.employment_contracts c
    SET signature_status = 'rejected', updated_at = now()
    WHERE c.signing_submission_id = NEW.id
      AND c.signature_status IS DISTINCT FROM 'completed';

  ELSIF NEW.status = 'expired' THEN
    UPDATE data.employment_contracts c
    SET signature_status = 'expired', updated_at = now()
    WHERE c.signing_submission_id = NEW.id
      AND c.signature_status IS DISTINCT FROM 'completed';

  ELSIF NEW.status IN ('cancelled', 'error') THEN
    UPDATE data.employment_contracts c
    SET
      signing_submission_id = NULL,
      signature_status = CASE
        WHEN c.signature_requirement = 'none' THEN 'not_required'
        ELSE 'pending'
      END,
      updated_at = now()
    WHERE c.signing_submission_id = NEW.id
      AND c.signature_status IS DISTINCT FROM 'completed';

  ELSIF NEW.status IN ('pending', 'in_progress') THEN
    UPDATE data.employment_contracts c
    SET signature_status = 'pending', updated_at = now()
    WHERE c.signing_submission_id = NEW.id
      AND c.signature_status IS DISTINCT FROM 'completed';
  END IF;

  RETURN NEW;
END;
$$;

-- ---------------------------------------------------------------------------
-- 4. Temporary upsert helper per blueprints de plataforma
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.upsert_platform_blueprint(
  p_name         text,
  p_description  text,
  p_trigger_event text,
  p_trigger_filters jsonb,
  p_steps        jsonb
)
RETURNS uuid
LANGUAGE plpgsql
AS $$
DECLARE
  v_id uuid;
BEGIN
  SELECT id INTO v_id
  FROM data.automation_workflows
  WHERE is_blueprint = true AND name = p_name AND tenant_id IS NULL;

  IF FOUND THEN
    UPDATE data.automation_workflows
    SET description     = p_description,
        trigger_event   = p_trigger_event,
        trigger_filters = p_trigger_filters,
        steps           = p_steps,
        is_active       = true,
        version         = version + 1,
        updated_at      = now()
    WHERE id = v_id;
  ELSE
    INSERT INTO data.automation_workflows (
      name, description, trigger_event, trigger_filters, steps,
      is_blueprint, is_active, tenant_id
    ) VALUES (
      p_name, p_description, p_trigger_event, p_trigger_filters, p_steps,
      true, true, NULL
    )
    RETURNING id INTO v_id;
  END IF;

  RETURN v_id;
END;
$$;

-- ---------------------------------------------------------------------------
-- 5A. Blueprint: Contracte — signat (CONTRACT_FULLY_SIGNED)
-- ---------------------------------------------------------------------------
SELECT data.upsert_platform_blueprint(
  'Contracte — signat',
  'Quan un contracte queda plenament signat (CONTRACT_FULLY_SIGNED), notifica el manager i crea una tasca per programar-ne l''activació. No activa automàticament.',
  'CONTRACT_FULLY_SIGNED',
  '{}'::jsonb,
  '[
    {
      "id": "step_1",
      "name": "Notificar manager",
      "type": "SEND_NOTIFICATION",
      "config": {
        "event_type": "CONTRACT_FULLY_SIGNED",
        "recipient_role": "manager"
      },
      "on_success": "step_2",
      "on_failure": "step_2"
    },
    {
      "id": "step_2",
      "name": "Tasca programar activació",
      "type": "CREATE_TASK",
      "config": {
        "title": "Contracte signat — programar activació ({{ entity.contract_number }})",
        "description": "El contracte {{ entity.contract_number }} de {{ entity.full_name }} ja està signat. Programar/activar segons starts_on ({{ entity.starts_on }}).",
        "assignee_role": "manager"
      },
      "on_success": "END_OK",
      "on_failure": "END_OK"
    }
  ]'::jsonb
);

-- ---------------------------------------------------------------------------
-- 5B. Blueprint: Offboarding d'empleats (EMPLOYEE_LIFECYCLE_CHANGED to=offboarding)
-- ---------------------------------------------------------------------------
SELECT data.upsert_platform_blueprint(
  'Offboarding d''empleats',
  'Quan el lifecycle de l''empleat passa a offboarding, notifica el manager i crea tasques de devolució d''actius i revocació d''accessos. La devolució física es gestiona a EA-4.',
  'EMPLOYEE_LIFECYCLE_CHANGED',
  '{"to": "offboarding"}'::jsonb,
  '[
    {
      "id": "step_1",
      "name": "Notificar manager offboarding",
      "type": "SEND_NOTIFICATION",
      "config": {
        "event_type": "EMPLOYEE_OFFBOARDING_STARTED",
        "recipient_role": "manager"
      },
      "on_success": "step_2",
      "on_failure": "step_2"
    },
    {
      "id": "step_2",
      "name": "Tasca devolució d''actius",
      "type": "CREATE_TASK",
      "config": {
        "title": "Offboarding — devolució d''actius de {{ entity.full_name }}",
        "description": "Recollir EPIs, vehicles i eines assignades (checklist EA-4) de {{ entity.full_name }}.",
        "assignee_role": "manager"
      },
      "on_success": "step_3",
      "on_failure": "step_3"
    },
    {
      "id": "step_3",
      "name": "Tasca revocació d''accessos",
      "type": "CREATE_TASK",
      "config": {
        "title": "Offboarding — revocar accessos de {{ entity.full_name }}",
        "description": "Revocar accessos, portal i credencials de {{ entity.full_name }}.",
        "assignee_role": "manager"
      },
      "on_success": "END_OK",
      "on_failure": "END_OK"
    }
  ]'::jsonb
);

-- ---------------------------------------------------------------------------
-- 6. Install helper: inclou els nous blueprints (idempotent)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.install_ec_platform_blueprints_for_tenant(
  p_tenant_id  uuid,
  p_created_by uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_bp record;
  v_new_id uuid;
  v_installed int := 0;
  v_skipped int := 0;
  v_names text[] := ARRAY[]::text[];
BEGIN
  IF p_tenant_id IS NULL THEN
    RAISE EXCEPTION 'tenant_required' USING ERRCODE = 'invalid_parameter_value';
  END IF;

  FOR v_bp IN
    SELECT w.*
    FROM data.automation_workflows w
    WHERE w.is_blueprint = true
      AND w.tenant_id IS NULL
      AND w.is_active = true
      AND (
        w.trigger_event IN (
          'CONTRACT_ACTIVATION_BLOCKED',
          'CONTRACT_ACTIVATED',
          'CONTRACT_EXPIRING',
          'CONTRACT_ENDED',
          'CONTRACT_FULLY_SIGNED'
        )
        OR w.name IN ('Onboarding d''empleats', 'Offboarding d''empleats')
      )
    ORDER BY w.trigger_event NULLS LAST, w.name
  LOOP
    IF EXISTS (
      SELECT 1
      FROM data.automation_workflows t
      WHERE t.tenant_id = p_tenant_id
        AND t.is_blueprint = false
        AND (
          t.source_blueprint_id = v_bp.id
          OR (t.name = v_bp.name AND t.trigger_event = v_bp.trigger_event)
        )
    ) THEN
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;

    INSERT INTO data.automation_workflows (
      tenant_id, site_id, name, description,
      trigger_event, trigger_filters, steps,
      is_active, is_blueprint, source_blueprint_id,
      version, created_by
    ) VALUES (
      p_tenant_id, NULL, v_bp.name, v_bp.description,
      v_bp.trigger_event, v_bp.trigger_filters, v_bp.steps,
      true, false, v_bp.id,
      1, p_created_by
    )
    RETURNING id INTO v_new_id;

    v_installed := v_installed + 1;
    v_names := array_append(v_names, v_bp.name);
  END LOOP;

  RETURN jsonb_build_object(
    'tenant_id', p_tenant_id,
    'installed', v_installed,
    'skipped', v_skipped,
    'names', to_jsonb(v_names)
  );
END;
$$;

REVOKE ALL ON FUNCTION data.install_ec_platform_blueprints_for_tenant(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.install_ec_platform_blueprints_for_tenant(uuid, uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 7. Runbook helper: verifica crons del domini employees/HR
--    Retorna esperats vs presents; pg_cron pot no estar instal·lat.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.verify_employee_domain_crons()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = api, data
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_has_cron boolean := EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron');
  v_jobs jsonb;
  v_missing int := 0;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'auth_required' USING ERRCODE = 'invalid_authorization_specification';
  END IF;

  IF v_tenant_id IS NOT NULL AND NOT (
    data.jwt_user_tenants() ? v_tenant_id::text
    AND (data.jwt_user_tenants() -> v_tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  ) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF v_has_cron THEN
    EXECUTE $q$
      SELECT jsonb_agg(jsonb_build_object(
        'job_name', e.job_name,
        'required_for', e.required_for,
        'present', (j.jobname IS NOT NULL),
        'active', COALESCE(j.active, false),
        'schedule', j.schedule
      ) ORDER BY e.job_name)
      FROM (VALUES
        ('employment-contracts-reconcile',            'EC-8: activa/finalitza contractes + ELM'),
        ('employment-contract-expiry-notices',        'EC-8: avisos venciment 90/30/7'),
        ('employee-lifecycle-scheduled-reconcile',    'ES-2b: transicions de lifecycle programades'),
        ('employee-readiness-projection-refresh',     'CR-2c: refresc projecció readiness'),
        ('compliance-certification-expiry-notices',   'CR-3: avisos caducitat certificacions'),
        ('asset-calibration-expiry-notices',          'EA-3: avisos calibratge actius'),
        ('automation_wait_timers',                    'Automation: passos WAIT dels blueprints'),
        ('automation_date_triggers',                  'Automation: triggers per data (SCHEDULED_*)')
      ) AS e(job_name, required_for)
      LEFT JOIN cron.job j ON j.jobname = e.job_name
    $q$ INTO v_jobs;
  ELSE
    SELECT jsonb_agg(jsonb_build_object(
      'job_name', e.job_name,
      'required_for', e.required_for,
      'present', false,
      'active', false,
      'schedule', NULL
    ) ORDER BY e.job_name)
    INTO v_jobs
    FROM (VALUES
      ('employment-contracts-reconcile',            'EC-8: activa/finalitza contractes + ELM'),
      ('employment-contract-expiry-notices',        'EC-8: avisos venciment 90/30/7'),
      ('employee-lifecycle-scheduled-reconcile',    'ES-2b: transicions de lifecycle programades'),
      ('employee-readiness-projection-refresh',     'CR-2c: refresc projecció readiness'),
      ('compliance-certification-expiry-notices',   'CR-3: avisos caducitat certificacions'),
      ('asset-calibration-expiry-notices',          'EA-3: avisos calibratge actius'),
      ('automation_wait_timers',                    'Automation: passos WAIT dels blueprints'),
      ('automation_date_triggers',                  'Automation: triggers per data (SCHEDULED_*)')
    ) AS e(job_name, required_for);
  END IF;

  SELECT count(*) INTO v_missing
  FROM jsonb_array_elements(coalesce(v_jobs, '[]'::jsonb)) x
  WHERE (x ->> 'present')::boolean = false;

  RETURN jsonb_build_object(
    'pg_cron_installed', v_has_cron,
    'expected_total', jsonb_array_length(coalesce(v_jobs, '[]'::jsonb)),
    'missing_total', v_missing,
    'all_scheduled', (v_has_cron AND v_missing = 0),
    'jobs', coalesce(v_jobs, '[]'::jsonb)
  );
END;
$$;

COMMENT ON FUNCTION api.verify_employee_domain_crons() IS
  'Runbook: llista crons esperats del domini employees/HR i si estan programats (staging/prod).';

REVOKE ALL ON FUNCTION api.verify_employee_domain_crons() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.verify_employee_domain_crons() TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 8. Drop temporary helper
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS data.upsert_platform_blueprint(text, text, text, jsonb, jsonb);

NOTIFY pgrst, 'reload schema';
