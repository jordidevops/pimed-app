-- =============================================================================
-- Migration: 20260603000010_fix_enqueue_signing_notification_email_fields.sql
--
-- Propòsit: Corregir els camps de la crida a api.enqueue_email dins de
--           api.enqueue_signing_notification.
--
-- Errors corregits de la migració 20260603000008:
--   1. 'to_email' / 'to_name' → camp 'to' ha de ser jsonb array
--      (api.enqueue_email espera: 'to': jsonb array of email strings)
--   2. 'variables' → ha de ser 'template_variables'
--   3. Faltava 'idempotency_key' (OBLIGATORI — api.enqueue_email fa
--      RAISE EXCEPTION si és NULL o buit)
--
-- Convencions d'idempotency_key:
--   - Notificació automàtica ('initial'): clau determinista →
--       'signing-notif-{submitter_id}-auto'
--     Permet re-execució idempotent sense duplicar l'email si el router
--     es crida dues vegades per la mateixa submissió.
--   - Re-enviament manual ('manual'): clau amb timestamp →
--       'signing-notif-{submitter_id}-manual-{epoch_seconds}'
--     Cada clic del botó "Tornar a enviar" genera un email nou.
-- =============================================================================

CREATE OR REPLACE FUNCTION api.enqueue_signing_notification(
  p_submission_id  uuid,
  p_signer_order   integer,
  p_reason         text  DEFAULT 'manual'
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_submitter       data.signing_submitters%ROWTYPE;
  v_submission      data.signing_submissions%ROWTYPE;
  v_total           bigint;
  v_log_id          uuid;
  v_event_type      text;
  v_idempotency_key text;
BEGIN
  -- Validació: submitter existeix
  SELECT * INTO v_submitter
  FROM data.signing_submitters
  WHERE submission_id = p_submission_id
    AND signer_order  = p_signer_order;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'submitter_not_found: submission=%, order=%',
      p_submission_id, p_signer_order
      USING ERRCODE = 'no_data_found';
  END IF;

  -- Validació: submission existeix
  SELECT * INTO v_submission
  FROM data.signing_submissions
  WHERE id = p_submission_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'submission_not_found: %', p_submission_id
      USING ERRCODE = 'no_data_found';
  END IF;

  -- ── FIX 1 (SEGURETAT — IDOR) ──────────────────────────────────────────────
  -- Si la crida ve d'un usuari autenticat (auth.uid() != NULL), validar que
  -- pertany al tenant de la submission. Les crides de service_role (webhook,
  -- router intern) no estableixen context d'usuari → auth.uid() = NULL → bypass.
  IF auth.uid() IS NOT NULL THEN
    IF NOT (data.jwt_user_tenants() ? v_submission.tenant_id::text) THEN
      RAISE EXCEPTION 'Access denied: not a member of tenant %', v_submission.tenant_id
        USING ERRCODE = 'insufficient_privilege';
    END IF;
  END IF;

  -- Validació: ha d'haver URL per enviar
  IF v_submitter.signing_url IS NULL THEN
    RAISE EXCEPTION 'no_signing_url: submitter signer_order=% no té signing_url', p_signer_order
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  -- Nombre total de signants
  SELECT COUNT(*) INTO v_total
  FROM data.signing_submitters
  WHERE submission_id = p_submission_id;

  -- Event type de l'email
  v_event_type := CASE WHEN p_signer_order = 0
    THEN 'signing.request.initial'
    ELSE 'signing.request.next_signer'
  END;

  -- ── FIX 2 (IDEMPOTENCY KEY) ───────────────────────────────────────────────
  -- 'manual' → timestamp per permetre múltiples enviaments
  -- qualsevol altre motiu ('initial', webhook, etc.) → clau determinista
  v_idempotency_key := CASE
    WHEN p_reason = 'manual'
      THEN 'signing-notif-' || v_submitter.id::text
           || '-manual-' || extract(epoch from now())::bigint::text
    ELSE
      'signing-notif-' || v_submitter.id::text || '-auto'
  END;

  -- ── FIX 3 (CAMPS CORRECTES DE enqueue_email) ─────────────────────────────
  -- 'to'               → jsonb array de strings (no 'to_email' / 'to_name')
  -- 'idempotency_key'  → obligatori
  -- 'template_variables' → nom correcte (no 'variables')
  SELECT api.enqueue_email(jsonb_build_object(
    'tenant_id',          v_submission.tenant_id,
    'event_type',         v_event_type,
    'to',                 jsonb_build_array(v_submitter.email),
    'idempotency_key',    v_idempotency_key,
    'template_variables', jsonb_build_object(
      'signer_name',    v_submitter.name,
      'signer_email',   v_submitter.email,
      'signer_role',    COALESCE(v_submitter.role, ''),
      'document_title', COALESCE(v_submission.document_title, ''),
      'signing_url',    v_submitter.signing_url,
      'current_order',  p_signer_order + 1,
      'total_signers',  v_total
    )
  )) INTO v_log_id;

  -- Actualitzar notified_at i email_log_id al submitter
  UPDATE data.signing_submitters
  SET
    notified_at  = now(),
    email_log_id = v_log_id,
    status       = CASE WHEN status = 'pending' THEN 'sent' ELSE status END,
    updated_at   = now()
  WHERE id = v_submitter.id;

  -- ── FIX 2 (SEMÀNTICA — de migració 20260603000008) ────────────────────────
  -- next_signer_index = índex del PRÒXIM signant a notificar (p_signer_order + 1).
  UPDATE data.signing_submissions
  SET
    last_notification_at = now(),
    next_signer_index    = p_signer_order + 1,
    first_email_sent_at  = COALESCE(first_email_sent_at, now()),
    updated_at           = now()
  WHERE id = p_submission_id;

  -- Audit log
  PERFORM data.log_audit_event(
    v_submission.tenant_id,
    COALESCE(auth.uid(), NULL),
    NULL,
    'SIGNING_NOTIFICATION_SENT',
    'signing_submitter',
    v_submitter.id,
    jsonb_build_object(
      'submission_id',  p_submission_id,
      'signer_order',   p_signer_order,
      'email',          v_submitter.email,
      'event_type',     v_event_type,
      'reason',         p_reason,
      'email_log_id',   v_log_id
    )
  );

  RETURN v_log_id;
END;
$$;

-- GRANTs sense canvi
GRANT EXECUTE ON FUNCTION api.enqueue_signing_notification(uuid, integer, text)
  TO authenticated, service_role;
