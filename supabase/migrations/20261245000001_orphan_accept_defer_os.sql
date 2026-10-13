-- CF-24 1A: defer orphan OS (no auto-create on accept); notify outcomes;
-- ensure with type+intent; project_not_needed; list unscheduled filter.

-- =============================================================================
-- 1. Notification catalog
-- =============================================================================
INSERT INTO data.notification_event_catalog (
  event_code, category, entity_type, deep_link_template,
  default_channels, requires_legal, digest_eligible, description
) VALUES
  (
    'QUOTE_ACCEPTED', 'billing', 'quote', '/sales/quotes/{entity_id}',
    '{in_app,email}', false, false,
    'Pressupost acceptat (owners/managers globals)'
  ),
  (
    'QUOTE_REJECTED', 'billing', 'quote', '/sales/quotes/{entity_id}',
    '{in_app,email}', false, false,
    'Pressupost refusat (owners/managers globals)'
  ),
  (
    'ORPHAN_OS_CREATED', 'operations', 'project', '/field/orders/{entity_id}',
    '{in_app,email}', false, false,
    'Ordre creada des d’un pressupost orfe'
  )
ON CONFLICT (event_code) DO UPDATE SET
  deep_link_template = EXCLUDED.deep_link_template,
  default_channels = EXCLUDED.default_channels,
  description = EXCLUDED.description;

-- =============================================================================
-- 2. Fan-out quote outcome (accept / reject / signed-as-accept)
-- =============================================================================
CREATE OR REPLACE FUNCTION data.enqueue_quote_outcome_notifications(
  p_document_id uuid,
  p_event_code text,
  p_actor_id uuid DEFAULT NULL
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, pgmq, public
AS $$
DECLARE
  v_doc data.commercial_documents%ROWTYPE;
  v_member record;
  v_count integer := 0;
  v_label text;
  v_summary text;
BEGIN
  IF p_event_code NOT IN ('QUOTE_ACCEPTED', 'QUOTE_REJECTED') THEN
    RETURN 0;
  END IF;

  SELECT * INTO v_doc FROM data.commercial_documents WHERE id = p_document_id;
  IF NOT FOUND THEN
    RETURN 0;
  END IF;
  IF v_doc.doc_type NOT IN ('quote', 'quote_amendment') THEN
    RETURN 0;
  END IF;

  v_label := COALESCE(NULLIF(btrim(v_doc.doc_number), ''), NULLIF(btrim(v_doc.title), ''), 'Pressupost');
  v_summary := CASE
    WHEN p_event_code = 'QUOTE_ACCEPTED' THEN 'Pressupost acceptat: ' || v_label
    ELSE 'Pressupost refusat: ' || v_label
  END;

  FOR v_member IN
    SELECT tm.user_id
    FROM data.tenant_members tm
    WHERE tm.tenant_id = v_doc.tenant_id
      AND tm.role IN ('owner', 'manager')
      AND tm.site_id IS NULL
      AND tm.is_active IS TRUE
  LOOP
    IF p_actor_id IS NOT NULL AND v_member.user_id = p_actor_id THEN
      CONTINUE;
    END IF;
    BEGIN
      PERFORM data.enqueue_notification_dispatch(jsonb_build_object(
        'tenantId',       v_doc.tenant_id,
        'eventType',      p_event_code,
        'correlationId',  'quote:' || v_doc.id::text || ':' || lower(p_event_code) || ':' || v_member.user_id::text,
        'recipient',      jsonb_build_object('kind', 'tenant_member', 'userId', v_member.user_id),
        'entityType',     'quote',
        'entityId',       v_doc.id,
        'actorUserId',    p_actor_id,
        'payload',        jsonb_build_object(
          'summary',     v_summary,
          'doc_number',  v_doc.doc_number,
          'title',       v_doc.title,
          'status',      v_doc.status,
          'project_id',  v_doc.project_id,
          'client_id',   v_doc.client_id
        )
      ));
      v_count := v_count + 1;
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'enqueue_quote_outcome_notifications: %', SQLERRM;
    END;
  END LOOP;

  RETURN v_count;
END;
$$;

REVOKE ALL ON FUNCTION data.enqueue_quote_outcome_notifications(uuid, text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.enqueue_quote_outcome_notifications(uuid, text, uuid)
  TO service_role;

CREATE OR REPLACE FUNCTION data.enqueue_orphan_os_created_notifications(
  p_tenant_id uuid,
  p_project_id uuid,
  p_document_id uuid,
  p_actor_id uuid DEFAULT NULL,
  p_project_type text DEFAULT 'work_order',
  p_visit_intent text DEFAULT 'generic'
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, pgmq, public
AS $$
DECLARE
  v_member record;
  v_count integer := 0;
  v_name text;
BEGIN
  SELECT name INTO v_name FROM data.projects WHERE id = p_project_id;
  v_name := COALESCE(NULLIF(btrim(v_name), ''), 'Ordre');

  FOR v_member IN
    SELECT tm.user_id
    FROM data.tenant_members tm
    WHERE tm.tenant_id = p_tenant_id
      AND tm.role IN ('owner', 'manager')
      AND tm.site_id IS NULL
      AND tm.is_active IS TRUE
  LOOP
    IF p_actor_id IS NOT NULL AND v_member.user_id = p_actor_id THEN
      CONTINUE;
    END IF;
    BEGIN
      PERFORM data.enqueue_notification_dispatch(jsonb_build_object(
        'tenantId',       p_tenant_id,
        'eventType',      'ORPHAN_OS_CREATED',
        'correlationId',  'orphan-os:' || p_project_id::text || ':' || v_member.user_id::text,
        'recipient',      jsonb_build_object('kind', 'tenant_member', 'userId', v_member.user_id),
        'entityType',     'project',
        'entityId',       p_project_id,
        'actorUserId',    p_actor_id,
        'payload',        jsonb_build_object(
          'summary',       'Nova ordre des de pressupost: ' || v_name,
          'project_id',    p_project_id,
          'document_id',   p_document_id,
          'project_type',  p_project_type,
          'visit_intent',  p_visit_intent
        )
      ));
      v_count := v_count + 1;
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'enqueue_orphan_os_created_notifications: %', SQLERRM;
    END;
  END LOOP;

  RETURN v_count;
END;
$$;

REVOKE ALL ON FUNCTION data.enqueue_orphan_os_created_notifications(uuid, uuid, uuid, uuid, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.enqueue_orphan_os_created_notifications(uuid, uuid, uuid, uuid, text, text)
  TO service_role;

-- =============================================================================
-- 3. Stop auto-OS: try_ensure no-op; trigger notifies outcome instead
-- =============================================================================
CREATE OR REPLACE FUNCTION data.try_ensure_orphan_project_after_accept(p_document_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
BEGIN
  -- CF-24 1A: OS is created manually via api.ensure_project_from_orphan_quote.
  RETURN;
END;
$$;

COMMENT ON FUNCTION data.try_ensure_orphan_project_after_accept(uuid) IS
  'CF-24 1A no-op: orphan OS is deferred until office creates it.';

CREATE OR REPLACE FUNCTION data.trg_commercial_document_orphan_ensure()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_code text;
BEGIN
  IF TG_OP = 'UPDATE'
     AND NEW.doc_type IN ('quote', 'quote_amendment')
     AND OLD.status IS DISTINCT FROM NEW.status
  THEN
    IF NEW.status IN ('accepted', 'signed') THEN
      v_code := 'QUOTE_ACCEPTED';
    ELSIF NEW.status = 'rejected' THEN
      v_code := 'QUOTE_REJECTED';
    ELSE
      v_code := NULL;
    END IF;

    IF v_code IS NOT NULL THEN
      BEGIN
        PERFORM data.enqueue_quote_outcome_notifications(NEW.id, v_code, auth.uid());
      EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'trg quote outcome notify: %', SQLERRM;
      END;
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION data.trg_commercial_document_orphan_ensure() IS
  'CF-24 1A: on quote accept/reject/signed, notify managers (no auto OS).';

-- finalize: remove try_ensure; only recompute when project exists; link agreement if linked
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
  v_doc_id uuid;
  v_doc_tenant uuid;
  v_as_of date := COALESCE(p_as_of, CURRENT_DATE);
  v_activate boolean;
  v_quote_id uuid;
  v_quote_project uuid;
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

  IF v_version.status = 'signed' THEN
    IF p_signed_document_id IS NOT NULL
       AND v_version.signed_document_id IS DISTINCT FROM p_signed_document_id THEN
      RAISE EXCEPTION 'signed_document_conflict' USING ERRCODE = 'P0001';
    END IF;
    IF v_agreement.status IN ('active', 'finished', 'cancelled') THEN
      IF v_agreement.status = 'active' THEN
        PERFORM data.commercial_agreement_ensure_cycle(v_agreement.id);
      END IF;
    END IF;
  ELSIF v_version.status = 'pending_signature' THEN
    v_doc_id := COALESCE(p_signed_document_id, v_version.signed_document_id);
    IF v_doc_id IS NULL THEN
      RAISE EXCEPTION 'signed_document_required' USING ERRCODE = 'P0001';
    END IF;

    SELECT d.tenant_id INTO v_doc_tenant
    FROM data.documents d
    WHERE d.id = v_doc_id;
    IF NOT FOUND OR v_doc_tenant IS DISTINCT FROM v_version.tenant_id THEN
      RAISE EXCEPTION 'signed_document_invalid' USING ERRCODE = 'P0001';
    END IF;

    PERFORM set_config('app.commercial_agreement_signing_unlocked', 'on', true);
    UPDATE data.commercial_agreement_versions
    SET status = 'signed',
        signed_document_id = v_doc_id,
        updated_at = now()
    WHERE id = v_version.id;
    PERFORM set_config('app.commercial_agreement_signing_unlocked', 'off', true);

    INSERT INTO data.commercial_agreement_events (
      tenant_id, agreement_id, event_type, actor_id, payload
    ) VALUES (
      v_version.tenant_id, v_version.agreement_id, 'signed', p_actor_id,
      jsonb_build_object(
        'version_id', v_version.id,
        'signed_document_id', v_doc_id
      )
    );
  ELSE
    RAISE EXCEPTION 'agreement_version_not_sent' USING ERRCODE = 'P0001';
  END IF;

  IF v_agreement.status NOT IN ('cancelled', 'finished') THEN
    v_activate := (v_version.starts_on IS NULL OR v_version.starts_on <= v_as_of);

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
          'as_of', v_as_of
        )
      );
    ELSIF NOT v_activate AND v_agreement.status = 'active' THEN
      UPDATE data.commercial_agreements
      SET status = 'pending_start'
      WHERE id = v_agreement.id;
    END IF;

    PERFORM data.commercial_agreement_ensure_cycle(v_agreement.id);
  END IF;

  UPDATE data.commercial_documents d
  SET status = 'accepted', updated_at = now()
  WHERE d.id = v_version.source_quote_id
    AND d.status = 'issued'
    AND d.formalization_mode = 'separate_agreement'
  RETURNING d.id INTO v_quote_id;

  IF FOUND THEN
    INSERT INTO data.commercial_document_events (
      tenant_id, document_id, event_type, actor_id, content_hash, client_op_id, payload
    )
    SELECT
      d.tenant_id, d.id, 'accepted', p_actor_id, d.content_hash, gen_random_uuid(),
      jsonb_build_object(
        'accepted_content_hash', d.content_hash,
        'via_agreement_version', v_version.id
      )
    FROM data.commercial_documents d
    WHERE d.id = v_version.source_quote_id;

    SELECT project_id INTO v_quote_project
    FROM data.commercial_documents WHERE id = v_version.source_quote_id;
    IF v_quote_project IS NOT NULL THEN
      PERFORM api.recompute_project_authorized_total(v_quote_project);
      BEGIN
        PERFORM api.link_agreement_project_from_quote(v_version.source_quote_id);
      EXCEPTION WHEN OTHERS THEN
        NULL;
      END;
    END IF;
  ELSIF v_version.source_quote_id IS NOT NULL THEN
    SELECT project_id INTO v_quote_project
    FROM data.commercial_documents WHERE id = v_version.source_quote_id;
    IF v_quote_project IS NOT NULL THEN
      BEGIN
        PERFORM api.link_agreement_project_from_quote(v_version.source_quote_id);
      EXCEPTION WHEN OTHERS THEN
        NULL;
      END;
    END IF;
  END IF;

  RETURN v_agreement.id;
END;
$$;

-- apply_commercial_decision: drop try_ensure calls (notify via trigger on status)
CREATE OR REPLACE FUNCTION data.apply_commercial_decision(
  p_document_id uuid,
  p_action text,
  p_signature jsonb,
  p_client_op_id uuid,
  p_actor_id uuid
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_doc data.commercial_documents%ROWTYPE;
  v_event_id uuid;
  v_status text;
  v_event_type text;
  v_payload jsonb;
BEGIN
  IF p_client_op_id IS NULL THEN
    RAISE EXCEPTION 'client_op_id_required' USING ERRCODE = 'P0001';
  END IF;
  IF p_action NOT IN ('accept', 'reject', 'delivery') THEN
    RAISE EXCEPTION 'invalid_commercial_signing_action' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_doc FROM data.commercial_documents WHERE id = p_document_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'document_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  SELECT id INTO v_event_id
  FROM data.commercial_document_events
  WHERE tenant_id = v_doc.tenant_id AND client_op_id = p_client_op_id;
  IF v_event_id IS NOT NULL THEN
    RETURN p_document_id;
  END IF;

  IF v_doc.status <> 'issued' THEN
    IF p_action = 'reject' THEN
      RAISE EXCEPTION 'document_not_rejectable_state:%', v_doc.status USING ERRCODE = 'P0001';
    END IF;
    RAISE EXCEPTION 'document_not_issuable_state:%', v_doc.status USING ERRCODE = 'P0001';
  END IF;

  IF p_action = 'delivery' THEN
    IF v_doc.doc_type <> 'delivery_note' THEN
      RAISE EXCEPTION 'document_not_delivery_note' USING ERRCODE = 'P0001';
    END IF;
    v_status := 'signed';
    v_event_type := 'signed';
    v_payload := data.commercial_event_payload_with_signing(
      jsonb_build_object('signed_content_hash', v_doc.content_hash),
      p_signature
    );
  ELSIF p_action = 'reject' THEN
    IF v_doc.doc_type NOT IN ('quote', 'quote_amendment', 'delivery_note') THEN
      RAISE EXCEPTION 'document_not_rejectable_type:%', v_doc.doc_type USING ERRCODE = 'P0001';
    END IF;
    v_status := 'rejected';
    v_event_type := 'rejected';
    v_payload := data.commercial_event_payload_with_signing(
      jsonb_build_object(
        'rejected_content_hash', v_doc.content_hash,
        'disputed', v_doc.doc_type = 'delivery_note'
      ),
      p_signature
    );
  ELSE
    IF v_doc.doc_type NOT IN ('quote', 'quote_amendment') THEN
      RAISE EXCEPTION 'document_not_acceptable_type:%', v_doc.doc_type USING ERRCODE = 'P0001';
    END IF;
    v_status := 'accepted';
    v_event_type := 'accepted';
    v_payload := data.commercial_event_payload_with_signing(
      jsonb_build_object('accepted_content_hash', v_doc.content_hash),
      p_signature
    );
  END IF;

  UPDATE data.commercial_documents
  SET status = v_status, updated_at = now()
  WHERE id = p_document_id;

  INSERT INTO data.commercial_document_events (
    tenant_id, document_id, event_type, actor_id, signature, content_hash, client_op_id, payload
  ) VALUES (
    v_doc.tenant_id, p_document_id, v_event_type, p_actor_id, p_signature, v_doc.content_hash,
    p_client_op_id, v_payload
  );

  IF v_doc.doc_type IN ('quote', 'quote_amendment') AND v_doc.project_id IS NOT NULL THEN
    PERFORM api.recompute_project_authorized_total(v_doc.project_id);
  END IF;

  RETURN p_document_id;
END;
$$;

-- =============================================================================
-- 4. ensure_project_from_orphan_quote with type + visit_intent
-- =============================================================================
DROP FUNCTION IF EXISTS api.ensure_project_from_orphan_quote(uuid, uuid);
DROP FUNCTION IF EXISTS api.ensure_project_from_orphan_quote(uuid);

CREATE FUNCTION api.ensure_project_from_orphan_quote(
  p_document_id uuid,
  p_site_id uuid DEFAULT NULL,
  p_project_type text DEFAULT 'work_order',
  p_visit_intent text DEFAULT 'generic'
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_doc data.commercial_documents%ROWTYPE;
  v_project_id uuid;
  v_uid uuid := auth.uid();
  v_member uuid;
  v_name text;
  v_line record;
  v_pos int := 0;
  v_site_id uuid;
  v_type text := COALESCE(NULLIF(btrim(p_project_type), ''), 'work_order');
  v_intent text := COALESCE(NULLIF(btrim(p_visit_intent), ''), 'generic');
BEGIN
  SELECT * INTO v_doc FROM data.commercial_documents WHERE id = p_document_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'document_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  IF v_doc.project_id IS NOT NULL THEN
    PERFORM api.link_agreement_project_from_quote(p_document_id);
    RETURN v_doc.project_id;
  END IF;

  IF v_doc.doc_type NOT IN ('quote', 'quote_amendment') THEN
    RAISE EXCEPTION 'not_quote' USING ERRCODE = 'P0001';
  END IF;
  IF v_doc.status NOT IN ('accepted', 'signed') THEN
    RAISE EXCEPTION 'orphan_os_requires_accepted' USING ERRCODE = 'P0001';
  END IF;

  IF EXISTS (
    SELECT 1 FROM data.commercial_document_events e
    WHERE e.document_id = p_document_id AND e.event_type = 'project_not_needed'
  ) THEN
    RAISE EXCEPTION 'orphan_os_declined' USING ERRCODE = 'P0001';
  END IF;

  IF v_type NOT IN ('work_order', 'maintenance') THEN
    RAISE EXCEPTION 'invalid_project_type' USING ERRCODE = 'P0001';
  END IF;
  IF v_intent NOT IN ('generic', 'inspection', 'corrective') THEN
    RAISE EXCEPTION 'invalid_visit_intent' USING ERRCODE = 'P0001';
  END IF;

  v_site_id := COALESCE(p_site_id, v_doc.site_id);
  IF v_site_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM data.sites s
      WHERE s.id = v_site_id AND s.tenant_id = v_doc.tenant_id
    ) THEN
      RAISE EXCEPTION 'site_invalid' USING ERRCODE = 'P0001';
    END IF;
  END IF;

  v_name := COALESCE(
    NULLIF(btrim(v_doc.doc_number), ''),
    NULLIF(btrim(v_doc.buyer_snapshot->>'display_name'), ''),
    'Ordre'
  );
  v_name := 'OS — ' || v_name;

  v_member := COALESCE(v_uid, v_doc.created_by);
  IF v_member IS NULL THEN
    SELECT tm.user_id INTO v_member
    FROM data.tenant_members tm
    WHERE tm.tenant_id = v_doc.tenant_id
      AND tm.is_active IS TRUE
      AND tm.role IN ('owner', 'manager')
    ORDER BY CASE tm.role WHEN 'owner' THEN 0 ELSE 1 END, tm.joined_at
    LIMIT 1;
  END IF;

  INSERT INTO data.projects (
    tenant_id, type, name, status, visibility,
    site_id, client_id, contact_site_id, created_by,
    commercial_stage, service_mode, visit_intent
  ) VALUES (
    v_doc.tenant_id, v_type::data.project_type, v_name, 'active', 'company',
    v_site_id, v_doc.client_id, v_doc.contact_site_id, v_member,
    'execute', 'execute', v_intent
  )
  RETURNING id INTO v_project_id;

  IF v_member IS NOT NULL THEN
    INSERT INTO data.project_members (project_id, user_id, role)
    VALUES (v_project_id, v_member, 'manager')
    ON CONFLICT (project_id, user_id) DO NOTHING;
  END IF;

  FOR v_line IN
    SELECT * FROM data.commercial_document_lines
    WHERE document_id = p_document_id
    ORDER BY position, created_at
  LOOP
    INSERT INTO data.project_lines (
      tenant_id, project_id, catalog_item_id, kind, name, description,
      unit, quantity, unit_price, discount_pct, tax_rate, position,
      source_quote_line_id
    ) VALUES (
      v_doc.tenant_id, v_project_id, v_line.catalog_item_id, v_line.kind,
      v_line.name, v_line.description, v_line.unit, v_line.quantity,
      v_line.unit_price, v_line.discount_pct, v_line.tax_rate, v_pos,
      v_line.id
    );
    v_pos := v_pos + 1;
  END LOOP;

  PERFORM set_config('app.orphan_project_link', 'on', true);
  UPDATE data.commercial_documents
  SET
    project_id = v_project_id,
    site_id = COALESCE(site_id, v_site_id),
    updated_at = now()
  WHERE id = p_document_id;
  PERFORM set_config('app.orphan_project_link', 'off', true);

  PERFORM api.recompute_project_authorized_total(v_project_id);

  IF NOT EXISTS (
    SELECT 1
    FROM data.commercial_document_events e
    WHERE e.document_id = p_document_id
      AND (
        e.event_type = 'project_linked'
        OR COALESCE((e.payload->>'project_created_from_quote')::boolean, false)
      )
  ) THEN
    INSERT INTO data.commercial_document_events (
      tenant_id, document_id, event_type, actor_id, client_op_id, payload
    ) VALUES (
      v_doc.tenant_id, p_document_id, 'project_linked', v_member,
      extensions.gen_random_uuid(),
      jsonb_build_object(
        'project_created_from_quote', true,
        'project_id', v_project_id,
        'project_type', v_type,
        'visit_intent', v_intent,
        'office_ack', false
      )
    );
  END IF;

  BEGIN
    PERFORM api.link_agreement_project_from_quote(p_document_id);
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  PERFORM data.enqueue_orphan_os_created_notifications(
    v_doc.tenant_id, v_project_id, p_document_id, v_uid, v_type, v_intent
  );

  RETURN v_project_id;
END;
$$;

REVOKE ALL ON FUNCTION api.ensure_project_from_orphan_quote(uuid, uuid, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.ensure_project_from_orphan_quote(uuid, uuid, text, text)
  TO authenticated, service_role;

-- =============================================================================
-- 5. Mark project not needed
-- =============================================================================
CREATE OR REPLACE FUNCTION api.mark_orphan_quote_project_not_needed(p_document_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_doc data.commercial_documents%ROWTYPE;
  v_uid uuid := auth.uid();
BEGIN
  SELECT * INTO v_doc FROM data.commercial_documents WHERE id = p_document_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'document_not_found' USING ERRCODE = 'no_data_found';
  END IF;
  IF v_doc.doc_type NOT IN ('quote', 'quote_amendment') THEN
    RAISE EXCEPTION 'not_quote' USING ERRCODE = 'P0001';
  END IF;
  IF v_doc.project_id IS NOT NULL THEN
    RAISE EXCEPTION 'already_has_project' USING ERRCODE = 'P0001';
  END IF;
  IF v_doc.status NOT IN ('accepted', 'signed') THEN
    RAISE EXCEPTION 'orphan_os_requires_accepted' USING ERRCODE = 'P0001';
  END IF;
  IF EXISTS (
    SELECT 1 FROM data.commercial_document_events e
    WHERE e.document_id = p_document_id AND e.event_type = 'project_not_needed'
  ) THEN
    RETURN;
  END IF;

  INSERT INTO data.commercial_document_events (
    tenant_id, document_id, event_type, actor_id, client_op_id, payload
  ) VALUES (
    v_doc.tenant_id, p_document_id, 'project_not_needed', v_uid,
    extensions.gen_random_uuid(),
    jsonb_build_object('reason', 'no_field_work')
  );
END;
$$;

REVOKE ALL ON FUNCTION api.mark_orphan_quote_project_not_needed(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.mark_orphan_quote_project_not_needed(uuid)
  TO authenticated, service_role;

-- =============================================================================
-- 6. list_projects_paginated: p_unscheduled
-- =============================================================================
DROP FUNCTION IF EXISTS api.list_projects_paginated(
  uuid, integer, integer, text, text, text, uuid, uuid, timestamptz, timestamptz, text, text, uuid, boolean, uuid, boolean
);

CREATE FUNCTION api.list_projects_paginated(
  p_tenant_id uuid,
  p_page integer DEFAULT 1,
  p_page_size integer DEFAULT 20,
  p_query text DEFAULT NULL,
  p_status text DEFAULT NULL,
  p_type text DEFAULT NULL,
  p_site_id uuid DEFAULT NULL,
  p_department_id uuid DEFAULT NULL,
  p_planned_start_from timestamptz DEFAULT NULL,
  p_planned_start_to timestamptz DEFAULT NULL,
  p_sort_field text DEFAULT 'created_at',
  p_sort_direction text DEFAULT 'desc',
  p_created_by uuid DEFAULT NULL,
  p_open_only boolean DEFAULT false,
  p_client_id uuid DEFAULT NULL,
  p_include_prospect boolean DEFAULT false,
  p_unscheduled boolean DEFAULT false
)
RETURNS TABLE (
  items jsonb,
  total_count bigint,
  page integer,
  page_size integer
)
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = data, public
AS $$
DECLARE
  v_page integer := GREATEST(COALESCE(p_page, 1), 1);
  v_page_size integer := LEAST(GREATEST(COALESCE(p_page_size, 20), 1), 100);
  v_query text := NULLIF(btrim(p_query), '');
  v_status text := NULLIF(btrim(p_status), '');
  v_type text := NULLIF(btrim(p_type), '');
  v_sort_field text := lower(COALESCE(NULLIF(btrim(p_sort_field), ''), 'created_at'));
  v_sort_direction text := CASE WHEN lower(COALESCE(NULLIF(btrim(p_sort_direction), ''), 'desc')) = 'asc' THEN 'asc' ELSE 'desc' END;
BEGIN
  RETURN QUERY
  WITH filtered AS (
    SELECT
      p.*,
      c.display_name AS client_display_name,
      cs.name AS contact_site_name,
      cs.address AS contact_site_address,
      cs.city AS contact_site_city,
      cs.postal_code AS contact_site_postal_code
    FROM data.projects p
    LEFT JOIN data.contacts c ON c.id = p.client_id
    LEFT JOIN data.contact_sites cs ON cs.id = p.contact_site_id
    WHERE p.tenant_id = p_tenant_id
      AND (p_client_id IS NULL OR p.client_id = p_client_id)
      AND (
        COALESCE(p_include_prospect, false)
        OR COALESCE(p.commercial_stage, 'execute') = 'execute'
        OR p_client_id IS NOT NULL
      )
      AND (
        v_query IS NULL
        OR p.name ILIKE '%' || v_query || '%'
        OR COALESCE(p.description, '') ILIKE '%' || v_query || '%'
        OR COALESCE(c.display_name, '') ILIKE '%' || v_query || '%'
        OR COALESCE(cs.name, '') ILIKE '%' || v_query || '%'
        OR COALESCE(cs.city, '') ILIKE '%' || v_query || '%'
      )
      AND (v_status IS NULL OR p.status = v_status)
      AND (
        NOT COALESCE(p_open_only, false)
        OR p.status NOT IN ('completed', 'cancelled')
      )
      AND (v_type IS NULL OR p.type = v_type::data.project_type)
      AND (p_site_id IS NULL OR p.site_id = p_site_id)
      AND (p_department_id IS NULL OR p.department_id = p_department_id)
      AND (p_created_by IS NULL OR p.created_by = p_created_by)
      AND (
        NOT COALESCE(p_unscheduled, false)
        OR (
          p.planned_start IS NULL
          AND p.type IN ('work_order', 'maintenance')
          AND COALESCE(p.commercial_stage, 'execute') = 'execute'
        )
      )
      AND (p_planned_start_from IS NULL OR p.planned_start >= p_planned_start_from)
      AND (p_planned_start_to IS NULL OR p.planned_start <= p_planned_start_to)
  ),
  total AS (
    SELECT COUNT(*)::bigint AS total_count
    FROM filtered
  ),
  ranked AS (
    SELECT
      f.*,
      row_number() OVER (
        ORDER BY
          CASE WHEN v_sort_field = 'name' AND v_sort_direction = 'asc' THEN f.name END ASC,
          CASE WHEN v_sort_field = 'name' AND v_sort_direction = 'desc' THEN f.name END DESC,
          CASE WHEN v_sort_field = 'type' AND v_sort_direction = 'asc' THEN f.type END ASC,
          CASE WHEN v_sort_field = 'type' AND v_sort_direction = 'desc' THEN f.type END DESC,
          CASE WHEN v_sort_field = 'status' AND v_sort_direction = 'asc' THEN f.status END ASC,
          CASE WHEN v_sort_field = 'status' AND v_sort_direction = 'desc' THEN f.status END DESC,
          CASE WHEN v_sort_field = 'planned_start' AND v_sort_direction = 'asc' THEN f.planned_start END ASC NULLS LAST,
          CASE WHEN v_sort_field = 'planned_start' AND v_sort_direction = 'desc' THEN f.planned_start END DESC NULLS LAST,
          f.created_at DESC,
          f.id DESC
      ) AS rn
    FROM filtered f
  ),
  paged AS (
    SELECT *
    FROM ranked
    WHERE rn > (v_page - 1) * v_page_size
      AND rn <= v_page * v_page_size
  )
  SELECT
    COALESCE((
      SELECT jsonb_agg(
        jsonb_build_object(
          'id', p.id,
          'tenant_id', p.tenant_id,
          'type', p.type,
          'name', p.name,
          'description', p.description,
          'status', p.status,
          'visibility', p.visibility,
          'department_id', p.department_id,
          'site_id', p.site_id,
          'location_id', p.location_id,
          'client_id', p.client_id,
          'contact_site_id', p.contact_site_id,
          'client_display_name', p.client_display_name,
          'contact_site_name', p.contact_site_name,
          'contact_site_address', p.contact_site_address,
          'contact_site_city', p.contact_site_city,
          'contact_site_postal_code', p.contact_site_postal_code,
          'planned_start', p.planned_start,
          'planned_end', p.planned_end,
          'created_by', p.created_by,
          'created_at', p.created_at,
          'updated_at', p.updated_at,
          'commercial_stage', p.commercial_stage,
          'service_mode', p.service_mode,
          'task_count', (
            SELECT COUNT(*)::int FROM data.tasks t WHERE t.project_id = p.id
          ),
          'pending_task_count', (
            SELECT COUNT(*)::int FROM data.tasks t WHERE t.project_id = p.id AND t.status <> 'done'
          ),
          'member_count', (
            SELECT COUNT(*)::int FROM data.project_members pm WHERE pm.project_id = p.id
          ),
          'asset_id', p.asset_id
        )
        ORDER BY p.rn
      )
      FROM paged p
    ), '[]'::jsonb) AS items,
    total.total_count,
    v_page,
    v_page_size
  FROM total;
END;
$$;

GRANT EXECUTE ON FUNCTION api.list_projects_paginated(
  uuid, integer, integer, text, text, text, uuid, uuid, timestamptz, timestamptz, text, text, uuid, boolean, uuid, boolean, boolean
) TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
