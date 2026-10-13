-- Quote origin in search + append-only «Ordre creada» (never fabricate a second accepted).

-- =============================================================================
-- ensure_project_from_orphan_quote: emit project_linked (events are append-only)
-- =============================================================================
CREATE OR REPLACE FUNCTION api.ensure_project_from_orphan_quote(
  p_document_id uuid,
  p_site_id uuid DEFAULT NULL
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
    commercial_stage, service_mode
  ) VALUES (
    v_doc.tenant_id, 'work_order', v_name, 'active', 'company',
    v_site_id, v_doc.client_id, v_doc.contact_site_id, v_member,
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
  SET
    project_id = v_project_id,
    site_id = COALESCE(site_id, v_site_id),
    updated_at = now()
  WHERE id = p_document_id;
  PERFORM set_config('app.orphan_project_link', 'off', true);

  PERFORM api.recompute_project_authorized_total(v_project_id);

  -- Append-only: never UPDATE accepted (immutable) and never invent a second accepted.
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
        'office_ack', false
      )
    );
  END IF;

  BEGIN
    PERFORM api.link_agreement_project_from_quote(p_document_id);
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  RETURN v_project_id;
END;
$$;

REVOKE ALL ON FUNCTION api.ensure_project_from_orphan_quote(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.ensure_project_from_orphan_quote(uuid, uuid)
  TO authenticated, service_role;

-- =============================================================================
-- search_commercial_documents: issued_as_orphan (Només pressupost vs Feina)
-- =============================================================================
DROP FUNCTION IF EXISTS api.search_commercial_documents(
  text, text[], text[], timestamptz, timestamptz, boolean, numeric, numeric, int, uuid, uuid
);

CREATE FUNCTION api.search_commercial_documents(
  p_q text DEFAULT NULL,
  p_doc_types text[] DEFAULT NULL,
  p_statuses text[] DEFAULT NULL,
  p_issued_from timestamptz DEFAULT NULL,
  p_issued_to timestamptz DEFAULT NULL,
  p_expired_only boolean DEFAULT false,
  p_total_min numeric DEFAULT NULL,
  p_total_max numeric DEFAULT NULL,
  p_limit int DEFAULT 100,
  p_client_id uuid DEFAULT NULL,
  p_site_id uuid DEFAULT NULL
)
RETURNS TABLE (
  id uuid,
  tenant_id uuid,
  doc_type text,
  doc_number text,
  title text,
  client_id uuid,
  project_id uuid,
  site_id uuid,
  status text,
  subtotal numeric,
  total numeric,
  show_prices boolean,
  issued_at timestamptz,
  valid_until timestamptz,
  parent_document_id uuid,
  supersedes_id uuid,
  created_at timestamptz,
  client_display_name text,
  project_name text,
  formalization_mode text,
  full_body_template_id uuid,
  issued_as_orphan boolean
)
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = data, public
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_q text := NULLIF(trim(COALESCE(p_q, '')), '');
  v_limit int := LEAST(GREATEST(COALESCE(p_limit, 100), 1), 200);
BEGIN
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'active_tenant_required' USING ERRCODE = 'P0001';
  END IF;

  RETURN QUERY
  SELECT
    d.id,
    d.tenant_id,
    d.doc_type,
    d.doc_number,
    d.title,
    d.client_id,
    d.project_id,
    COALESCE(d.site_id, p.site_id) AS site_id,
    d.status,
    d.subtotal,
    d.total,
    d.show_prices,
    d.issued_at,
    d.valid_until,
    d.parent_document_id,
    d.supersedes_id,
    d.created_at,
    COALESCE(
      NULLIF(trim(c.display_name), ''),
      NULLIF(trim(d.buyer_snapshot ->> 'display_name'), ''),
      NULLIF(trim(d.buyer_snapshot ->> 'legal_name'), ''),
      ''
    ) AS client_display_name,
    p.name AS project_name,
    d.formalization_mode,
    d.full_body_template_id,
    (
      d.doc_type IN ('quote', 'quote_amendment')
      AND (
        d.project_id IS NULL
        OR EXISTS (
          SELECT 1
          FROM data.commercial_document_events e
          WHERE e.document_id = d.id
            AND e.tenant_id = d.tenant_id
            AND (
              (e.event_type = 'issued' AND COALESCE((e.payload->>'orphan')::boolean, false))
              OR COALESCE((e.payload->>'project_created_from_quote')::boolean, false)
              OR e.event_type = 'project_linked'
            )
        )
      )
    ) AS issued_as_orphan
  FROM data.commercial_documents d
  LEFT JOIN data.contacts c
    ON c.id = d.client_id AND c.tenant_id = d.tenant_id
  LEFT JOIN data.projects p
    ON p.id = d.project_id AND p.tenant_id = d.tenant_id
  WHERE d.tenant_id = v_tenant_id
    AND (p_client_id IS NULL OR d.client_id = p_client_id)
    AND (
      p_site_id IS NULL
      OR d.site_id = p_site_id
      OR p.site_id = p_site_id
    )
    AND (p_doc_types IS NULL OR cardinality(p_doc_types) = 0 OR d.doc_type = ANY (p_doc_types))
    AND (p_statuses IS NULL OR cardinality(p_statuses) = 0 OR d.status = ANY (p_statuses))
    AND (p_issued_from IS NULL OR COALESCE(d.issued_at, d.created_at) >= p_issued_from)
    AND (p_issued_to IS NULL OR COALESCE(d.issued_at, d.created_at) <= p_issued_to)
    AND (
      NOT COALESCE(p_expired_only, false)
      OR (
        d.status = 'issued'
        AND d.valid_until IS NOT NULL
        AND d.valid_until < now()
        AND d.doc_type IN ('quote', 'quote_amendment')
      )
      OR d.status = 'expired'
    )
    AND (p_total_min IS NULL OR d.total >= p_total_min)
    AND (p_total_max IS NULL OR d.total <= p_total_max)
    AND (
      v_q IS NULL
      OR d.doc_number ILIKE '%' || v_q || '%'
      OR COALESCE(d.title, '') ILIKE '%' || v_q || '%'
      OR COALESCE(c.display_name, '') ILIKE '%' || v_q || '%'
      OR COALESCE(c.legal_name, '') ILIKE '%' || v_q || '%'
      OR COALESCE(d.buyer_snapshot ->> 'display_name', '') ILIKE '%' || v_q || '%'
      OR COALESCE(d.buyer_snapshot ->> 'legal_name', '') ILIKE '%' || v_q || '%'
      OR COALESCE(p.name, '') ILIKE '%' || v_q || '%'
      OR EXISTS (
        SELECT 1
        FROM data.commercial_document_lines l
        WHERE l.document_id = d.id
          AND l.tenant_id = d.tenant_id
          AND (
            COALESCE(l.name, '') ILIKE '%' || v_q || '%'
            OR COALESCE(l.description, '') ILIKE '%' || v_q || '%'
          )
      )
    )
  ORDER BY COALESCE(d.issued_at, d.created_at) DESC, d.created_at DESC
  LIMIT v_limit;
END;
$$;

REVOKE ALL ON FUNCTION api.search_commercial_documents(
  text, text[], text[], timestamptz, timestamptz, boolean, numeric, numeric, int, uuid, uuid
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.search_commercial_documents(
  text, text[], text[], timestamptz, timestamptz, boolean, numeric, numeric, int, uuid, uuid
) TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
