-- CF-24 V2 orphan hotfix:
-- - restore immutable fields (formalization_mode, full_body_template_id) + orphan link exception
-- - work_gate blocks require_signed_agreement without project link (incl. status active)
-- - ensure OS membership when auth.uid() is null
-- - mark project_created_from_quote on existing accepted event (no duplicate accept)
-- - restore finalize_commercial_agreement_version to pre-00002 body (trigger try_ensure remains)

-- =============================================================================
-- 1. Immutable: 61186 fields + one-time orphan project_id NULL→uuid
-- =============================================================================
CREATE OR REPLACE FUNCTION data.trg_commercial_documents_immutable()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF OLD.status <> 'draft' THEN
    IF NEW.doc_type IS DISTINCT FROM OLD.doc_type
       OR NEW.doc_number IS DISTINCT FROM OLD.doc_number
       OR NEW.client_id IS DISTINCT FROM OLD.client_id
       OR (
         NEW.project_id IS DISTINCT FROM OLD.project_id
         AND NOT (
           OLD.project_id IS NULL
           AND NEW.project_id IS NOT NULL
           AND COALESCE(current_setting('app.orphan_project_link', true), '') = 'on'
         )
       )
       OR NEW.parent_document_id IS DISTINCT FROM OLD.parent_document_id
       OR NEW.supersedes_id IS DISTINCT FROM OLD.supersedes_id
       OR NEW.seller_snapshot IS DISTINCT FROM OLD.seller_snapshot
       OR NEW.buyer_snapshot IS DISTINCT FROM OLD.buyer_snapshot
       OR NEW.service_address_snapshot IS DISTINCT FROM OLD.service_address_snapshot
       OR NEW.terms_text IS DISTINCT FROM OLD.terms_text
       OR NEW.locale IS DISTINCT FROM OLD.locale
       OR NEW.currency IS DISTINCT FROM OLD.currency
       OR NEW.subtotal IS DISTINCT FROM OLD.subtotal
       OR NEW.tax_breakdown IS DISTINCT FROM OLD.tax_breakdown
       OR NEW.total IS DISTINCT FROM OLD.total
       OR NEW.valid_until IS DISTINCT FROM OLD.valid_until
       OR NEW.show_prices IS DISTINCT FROM OLD.show_prices
       OR NEW.content_hash IS DISTINCT FROM OLD.content_hash
       OR NEW.full_body_template_id IS DISTINCT FROM OLD.full_body_template_id
       OR NEW.formalization_mode IS DISTINCT FROM OLD.formalization_mode
    THEN
      RAISE EXCEPTION 'commercial_document_immutable'
        USING ERRCODE = 'P0001';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

-- =============================================================================
-- 2. work_gate: orphan source_quote without link blocks even when agreement is active
-- =============================================================================
CREATE OR REPLACE FUNCTION data.project_requires_active_agreement(p_project_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM data.commercial_agreement_projects cap
    JOIN data.commercial_agreements a ON a.id = cap.agreement_id
    WHERE cap.project_id = p_project_id
      AND a.work_gate = 'require_signed_agreement'
      AND a.status NOT IN ('cancelled', 'finished')
      AND a.status IS DISTINCT FROM 'active'
  )
  OR EXISTS (
    -- Orphan path: agreement prepared from quote before project link (incl. active)
    SELECT 1
    FROM data.commercial_documents d
    JOIN data.commercial_agreements a ON a.source_quote_id = d.id
    WHERE d.project_id = p_project_id
      AND d.doc_type IN ('quote', 'quote_amendment')
      AND a.work_gate = 'require_signed_agreement'
      AND a.status NOT IN ('cancelled', 'finished')
      AND NOT EXISTS (
        SELECT 1
        FROM data.commercial_agreement_projects cap2
        WHERE cap2.agreement_id = a.id
          AND cap2.project_id = p_project_id
      )
  );
$$;

COMMENT ON FUNCTION data.project_requires_active_agreement(uuid) IS
  'True when a linked agreement demands active contract, or an unlinked source-quote agreement with require_signed_agreement (any non-terminal status including active).';

-- =============================================================================
-- 3. ensure OS: membership fallback + payload on existing accepted event
-- =============================================================================
CREATE OR REPLACE FUNCTION api.ensure_project_from_orphan_quote(p_document_id uuid)
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
    client_id, contact_site_id, created_by,
    commercial_stage, service_mode
  ) VALUES (
    v_doc.tenant_id, 'work_order', v_name, 'active', 'company',
    v_doc.client_id, v_doc.contact_site_id, v_member,
    'execute', 'execute'
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
  SET project_id = v_project_id, updated_at = now()
  WHERE id = p_document_id;
  PERFORM set_config('app.orphan_project_link', 'off', true);

  PERFORM api.recompute_project_authorized_total(v_project_id);

  -- Prefer tagging the latest accepted event; avoid a second accepted row.
  UPDATE data.commercial_document_events e
  SET payload = COALESCE(e.payload, '{}'::jsonb) || jsonb_build_object(
    'project_created_from_quote', true,
    'project_id', v_project_id,
    'office_ack', false
  )
  WHERE e.id = (
    SELECT e2.id
    FROM data.commercial_document_events e2
    WHERE e2.document_id = p_document_id
      AND e2.event_type = 'accepted'
    ORDER BY e2.occurred_at DESC NULLS LAST, e2.id DESC
    LIMIT 1
  );

  IF NOT FOUND THEN
    INSERT INTO data.commercial_document_events (
      tenant_id, document_id, event_type, actor_id, client_op_id, payload
    ) VALUES (
      v_doc.tenant_id, p_document_id, 'accepted', v_member,
      extensions.gen_random_uuid(),
      jsonb_build_object(
        'project_created_from_quote', true,
        'project_id', v_project_id,
        'office_ack', false
      )
    );
  END IF;

  BEGIN
    PERFORM api.link_agreement_project_from_quote(p_document_id);
  EXCEPTION WHEN OTHERS THEN
    NULL; -- repair via retry RPC
  END;

  RETURN v_project_id;
END;
$$;

REVOKE ALL ON FUNCTION api.ensure_project_from_orphan_quote(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.ensure_project_from_orphan_quote(uuid)
  TO authenticated, service_role;

-- =============================================================================
-- 4. Restore finalize to pre-00002 body (CF-28 intact); orphan ensure stays on trigger
-- =============================================================================
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
      -- still accept issued source quote if needed (CF-28)
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

  -- CF-28: agreement signed ⇒ accept issued separate_agreement quote (idempotent).
  -- Orphan OS ensure runs via trg_commercial_document_orphan_ensure on status→accepted.
  UPDATE data.commercial_documents d
  SET status = 'accepted', updated_at = now()
  WHERE d.id = v_version.source_quote_id
    AND d.status = 'issued'
    AND d.formalization_mode = 'separate_agreement';
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
    IF (SELECT project_id FROM data.commercial_documents WHERE id = v_version.source_quote_id) IS NOT NULL THEN
      PERFORM api.recompute_project_authorized_total(
        (SELECT project_id FROM data.commercial_documents WHERE id = v_version.source_quote_id)
      );
    END IF;
  END IF;

  RETURN v_agreement.id;
END;
$$;

COMMENT ON FUNCTION data.finalize_commercial_agreement_version(uuid, uuid, uuid, date) IS
  'CF-21-h3 + CF-28: finalize signed version / activate cycle; accept issued separate_agreement quote. Orphan OS via accept trigger.';

REVOKE ALL ON FUNCTION data.finalize_commercial_agreement_version(uuid, uuid, uuid, date)
  FROM PUBLIC, anon, authenticated;
