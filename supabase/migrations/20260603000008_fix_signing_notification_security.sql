-- =============================================================================
-- Migration: 20260603000008_fix_signing_notification_security.sql
--
-- Propòsit: Pegat de seguretat i correcció semàntica
--
-- Fix 1 (SEGURETAT — IDOR):
--   api.enqueue_signing_notification era accessible per qualsevol usuari
--   autenticat que conegués el submission UUID d'un altre tenant.
--   Afegim validació de pertinença al tenant per a crides authenticated.
--   Les crides de service_role (webhook, router) no tenen context d'usuari
--   (auth.uid() = NULL) i continuen sense restricció.
--
-- Fix 2 (SEMÀNTICA):
--   next_signer_index s'emmagatzemava amb p_signer_order (signant actual
--   notificat), quan el nom del camp indica el PRÒXIM signant a notificar.
--   Canviat a p_signer_order + 1.
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
  v_submitter  data.signing_submitters%ROWTYPE;
  v_submission data.signing_submissions%ROWTYPE;
  v_total      bigint;
  v_log_id     uuid;
  v_event_type text;
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

  -- Encuar via infraestructura d'email
  SELECT api.enqueue_email(jsonb_build_object(
    'tenant_id',    v_submission.tenant_id,
    'event_type',   v_event_type,
    'to_email',     v_submitter.email,
    'to_name',      v_submitter.name,
    'variables',    jsonb_build_object(
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

  -- ── FIX 2 (SEMÀNTICA) ─────────────────────────────────────────────────────
  -- next_signer_index = índex del PRÒXIM signant a notificar (p_signer_order + 1).
  -- Anteriorment s'emmagatzemava p_signer_order (el signant actual), incorrecte.
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

-- GRANTs explícits (sense canvi)
GRANT EXECUTE ON FUNCTION api.enqueue_signing_notification(uuid, integer, text)
  TO authenticated, service_role;
