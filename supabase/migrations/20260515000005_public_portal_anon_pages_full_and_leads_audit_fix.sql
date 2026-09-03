-- =============================================================================
-- Migration: 20260515000005_public_portal_anon_pages_full_and_leads_audit_fix.sql
-- Propòsit:
--   1) Permetre lectura anon de api.public_pages_full (inclou content JSONB)
--      perquè el portal SSR pugui respectar flags com show_lead_form.
--   2) Corregir api.submit_public_lead per usar la signatura vigent de
--      data.log_audit_event(tenant_id, user_id, site_id, action, entity_type, entity_id, payload).
-- =============================================================================

-- =============================================================================
-- 1) api.public_pages_full: accessible per anon + filtre compatible amb anon
-- =============================================================================

CREATE OR REPLACE VIEW api.public_pages_full
  WITH (security_invoker = true)
AS
SELECT
  pp.id,
  pp.public_site_id,
  pp.tenant_id,
  pp.slug,
  pp.title,
  pp.status,
  pp.content,
  pp.seo_title,
  pp.seo_description,
  pp.sort_order,
  pp.created_at,
  pp.updated_at
FROM data.public_pages pp
WHERE (data.active_tenant_id() IS NULL OR pp.tenant_id = data.active_tenant_id());

GRANT SELECT ON api.public_pages_full TO authenticated, anon;


-- =============================================================================
-- 2) api.submit_public_lead: fix signatura d'auditoria
-- =============================================================================

CREATE OR REPLACE FUNCTION api.submit_public_lead(
  p_public_site_id  uuid,
  p_idempotency_key text,
  p_name            text    DEFAULT NULL,
  p_email           text    DEFAULT NULL,
  p_phone           text    DEFAULT NULL,
  p_message         text    DEFAULT NULL,
  p_source_url      text    DEFAULT NULL,
  p_source_page_slug text   DEFAULT NULL,
  p_metadata        jsonb   DEFAULT '{}'
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_id          uuid;
  v_tenant_id   uuid;
  v_site_status text;
  v_enabled     bool;
  v_lock_key    bigint;
BEGIN
  -- 1. Obté el tenant i valida que el site és públic i el mòdul actiu
  SELECT ps.tenant_id, ps.status, t.public_portal_enabled
  INTO v_tenant_id, v_site_status, v_enabled
  FROM data.public_sites ps
  JOIN data.tenants t ON t.id = ps.tenant_id
  WHERE ps.id = p_public_site_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'not_found'
      USING HINT = 'El portal públic no existeix.';
  END IF;

  IF v_site_status <> 'published' THEN
    RAISE EXCEPTION 'site_not_published'
      USING HINT = 'El portal públic no accepta submissions en aquest moment.';
  END IF;

  IF NOT COALESCE(v_enabled, false) THEN
    RAISE EXCEPTION 'module_not_enabled'
      USING HINT = 'El portal públic no accepta submissions en aquest moment.';
  END IF;

  -- 2. Valida que hi ha almenys un camp de contacte
  IF COALESCE(trim(p_name), '') = ''
    AND COALESCE(trim(p_email), '') = ''
    AND COALESCE(trim(p_phone), '') = ''
    AND COALESCE(trim(p_message), '') = ''
  THEN
    RAISE EXCEPTION 'empty_lead'
      USING HINT = 'Cal proporcionar almenys nom, email, telèfon o missatge.';
  END IF;

  -- 3. Serialitza només per clau d'idempotència per evitar carreres amb DO NOTHING
  v_lock_key := hashtextextended(v_tenant_id::text || ':' || p_idempotency_key, 0);
  PERFORM pg_advisory_xact_lock(v_lock_key);

  INSERT INTO data.public_leads (
    public_site_id,
    tenant_id,
    idempotency_key,
    name,
    email,
    phone,
    message,
    source_url,
    source_page_slug,
    metadata,
    status
  ) VALUES (
    p_public_site_id,
    v_tenant_id,
    p_idempotency_key,
    nullif(trim(p_name), ''),
    nullif(lower(trim(p_email)), ''),
    nullif(trim(p_phone), ''),
    nullif(trim(p_message), ''),
    p_source_url,
    p_source_page_slug,
    COALESCE(p_metadata, '{}'),
    'new'
  )
  ON CONFLICT (tenant_id, idempotency_key) DO NOTHING
  RETURNING id INTO v_id;

  -- Duplicat: la fila ja existeix i, amb el lock, és visible en aquest punt.
  IF v_id IS NULL THEN
    SELECT id INTO v_id
    FROM data.public_leads
    WHERE tenant_id = v_tenant_id
      AND idempotency_key = p_idempotency_key;

    IF v_id IS NULL THEN
      RAISE EXCEPTION 'idempotency_lookup_failed'
        USING HINT = 'No s''ha pogut resoldre la clau d''idempotència.';
    END IF;

    RETURN v_id;
  END IF;

  -- 4. Audit log: LEAD_SUBMITTED (payload sense PII)
  PERFORM data.log_audit_event(
    v_tenant_id,
    NULL,
    NULL,
    'LEAD_SUBMITTED',
    'public_lead',
    v_id,
    jsonb_build_object(
      'public_site_id',   p_public_site_id,
      'tenant_id',        v_tenant_id,
      'has_name',         (COALESCE(trim(p_name), '') <> ''),
      'has_email',        (COALESCE(trim(p_email), '') <> ''),
      'has_phone',        (COALESCE(trim(p_phone), '') <> ''),
      'has_message',      (COALESCE(trim(p_message), '') <> ''),
      'source_page_slug', p_source_page_slug,
      'idempotency_key',  p_idempotency_key
    )
  );

  -- 5. Encua notificació asíncrona (fire-and-forget)
  BEGIN
    PERFORM pgmq.send(
      'leads_notification_queue',
      jsonb_build_object(
        'task',             'lead_submitted',
        'tenant_id',        v_tenant_id,
        'idempotency_key',  'lead-notify-' || v_id,
        'enqueued_at',      now(),
        'payload', jsonb_build_object(
          'lead_id',          v_id,
          'public_site_id',   p_public_site_id,
          'source_page_slug', p_source_page_slug,
          'has_email',        (COALESCE(trim(p_email), '') <> ''),
          'has_phone',        (COALESCE(trim(p_phone), '') <> ''),
          'has_message',      (COALESCE(trim(p_message), '') <> '')
        )
      )
    );
  EXCEPTION
    WHEN OTHERS THEN
      RAISE WARNING 'submit_public_lead: pgmq.send failed (leads_notification_queue): %', SQLERRM;
  END;

  RETURN v_id;
END;
$$;

GRANT EXECUTE ON FUNCTION api.submit_public_lead(uuid, text, text, text, text, text, text, text, jsonb) TO anon, authenticated;
