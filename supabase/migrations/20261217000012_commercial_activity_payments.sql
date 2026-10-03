-- CF-27 follow-up: project Activity for invoice_cancelled + payment_recorded;
-- narrative payment events on commercial_document_events (payments remain money ledger).

-- ---------------------------------------------------------------------------
-- 1. Event type: payment_recorded
-- ---------------------------------------------------------------------------
ALTER TABLE data.commercial_document_events
  DROP CONSTRAINT IF EXISTS commercial_document_events_event_type_check;

ALTER TABLE data.commercial_document_events
  ADD CONSTRAINT commercial_document_events_event_type_check
  CHECK (event_type IN (
    'issued', 'sent', 'viewed', 'accepted', 'rejected',
    'signed', 'superseded', 'cancelled', 'pdf_rendered', 'invoice_cancelled',
    'accounting_reviewed', 'accounting_changes_requested', 'included_in_export',
    'payment_recorded'
  ));

-- ---------------------------------------------------------------------------
-- 2. Helper: ensure payment_recorded event (idempotent / repair by client_op_id)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.ensure_commercial_payment_recorded_event(
  p_tenant_id uuid,
  p_document_id uuid,
  p_actor_id uuid,
  p_client_op_id uuid,
  p_payment_id uuid,
  p_amount_cents integer,
  p_method text,
  p_reference text,
  p_allocations jsonb DEFAULT '[]'::jsonb
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_doc data.commercial_documents%ROWTYPE;
  v_existing uuid;
BEGIN
  IF p_client_op_id IS NULL OR p_payment_id IS NULL THEN
    RETURN;
  END IF;

  SELECT id INTO v_existing
  FROM data.commercial_document_events
  WHERE tenant_id = p_tenant_id
    AND client_op_id = p_client_op_id;
  IF v_existing IS NOT NULL THEN
    RETURN;
  END IF;

  SELECT * INTO v_doc
  FROM data.commercial_documents
  WHERE id = p_document_id;
  IF NOT FOUND THEN
    RETURN;
  END IF;

  INSERT INTO data.commercial_document_events (
    tenant_id, document_id, event_type, actor_id, content_hash, client_op_id, payload
  ) VALUES (
    p_tenant_id,
    p_document_id,
    'payment_recorded',
    p_actor_id,
    v_doc.content_hash,
    p_client_op_id,
    jsonb_build_object(
      'payment_id', p_payment_id,
      'amount_cents', p_amount_cents,
      'method', p_method,
      'reference', p_reference,
      'allocations', COALESCE(p_allocations, '[]'::jsonb)
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION data.ensure_commercial_payment_recorded_event(
  uuid, uuid, uuid, uuid, uuid, integer, text, text, jsonb
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.ensure_commercial_payment_recorded_event(
  uuid, uuid, uuid, uuid, uuid, integer, text, text, jsonb
) TO service_role;

-- ---------------------------------------------------------------------------
-- 3. Project Activity projection (fan-out for multi-OS invoices)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.trg_commercial_document_event_project_audit()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_doc data.commercial_documents%ROWTYPE;
  v_project_id uuid;
  v_payload jsonb;
  v_active_links_only boolean;
BEGIN
  IF NEW.event_type NOT IN (
    'issued', 'sent', 'accepted', 'rejected', 'cancelled', 'superseded',
    'invoice_cancelled', 'payment_recorded'
  ) THEN
    RETURN NEW;
  END IF;

  SELECT * INTO v_doc
  FROM data.commercial_documents
  WHERE id = NEW.document_id;
  IF NOT FOUND THEN
    RETURN NEW;
  END IF;

  v_payload := jsonb_build_object(
    'doc_number', v_doc.doc_number,
    'doc_type', v_doc.doc_type,
    'event', NEW.event_type,
    'commercial_document_id', v_doc.id
  );
  IF NEW.event_type = 'payment_recorded' THEN
    v_payload := v_payload || jsonb_build_object(
      'payment_id', NEW.payload ->> 'payment_id',
      'amount_cents', NEW.payload -> 'amount_cents',
      'method', NEW.payload ->> 'method'
    );
  END IF;

  -- invoice_cancelled: links already released → ignore released_at
  -- payment_recorded on multi-OS invoice: only active links
  v_active_links_only := (NEW.event_type = 'payment_recorded');

  IF v_doc.project_id IS NOT NULL THEN
    PERFORM data.log_audit_event(
      NEW.tenant_id,
      NEW.actor_id,
      NULL,
      'PROJECT_COMMERCIAL_' || upper(NEW.event_type),
      'project',
      v_doc.project_id,
      v_payload
    );
    RETURN NEW;
  END IF;

  IF v_doc.doc_type IS DISTINCT FROM 'invoice' THEN
    RETURN NEW;
  END IF;

  FOR v_project_id IN
    SELECT DISTINCT d.project_id
    FROM data.invoice_delivery_notes link
    JOIN data.commercial_documents d ON d.id = link.delivery_note_id
    WHERE link.invoice_id = v_doc.id
      AND d.project_id IS NOT NULL
      AND (NOT v_active_links_only OR link.released_at IS NULL)
  LOOP
    PERFORM data.log_audit_event(
      NEW.tenant_id,
      NEW.actor_id,
      NULL,
      'PROJECT_COMMERCIAL_' || upper(NEW.event_type),
      'project',
      v_project_id,
      v_payload
    );
  END LOOP;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_commercial_document_event_project_audit
  ON data.commercial_document_events;
CREATE TRIGGER trg_commercial_document_event_project_audit
  AFTER INSERT ON data.commercial_document_events
  FOR EACH ROW
  EXECUTE FUNCTION data.trg_commercial_document_event_project_audit();

-- ---------------------------------------------------------------------------
-- 4. Timeline message helpers
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.timeline_audit_message_vars(
  p_action  text,
  p_payload jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
  CASE p_action
    WHEN 'EMPLOYEE_CREATED' THEN
      RETURN jsonb_build_object('name', coalesce(p_payload ->> 'full_name', p_payload ->> 'name'));
    WHEN 'EMPLOYEE_UPDATED' THEN
      IF p_payload ? 'changes' THEN
        RETURN jsonb_build_object(
          'changes', p_payload -> 'changes',
          'change_count', jsonb_array_length(p_payload -> 'changes')
        );
      END IF;
      RETURN jsonb_build_object('changes', '[]'::jsonb, 'change_count', 0);
    WHEN 'EMPLOYEE_TERMINATED' THEN
      RETURN jsonb_build_object(
        'name', coalesce(p_payload ->> 'full_name', p_payload ->> 'name'),
        'ends_on', p_payload ->> 'ends_on'
      );
    WHEN 'EMPLOYEE_PORTAL_TOKEN_CREATED' THEN
      RETURN jsonb_build_object(
        'label', coalesce(p_payload ->> 'label', '—'),
        'pin_required', coalesce(p_payload -> 'pin_required', 'false'::jsonb),
        'shared_device', coalesce(p_payload -> 'shared_device', 'false'::jsonb)
      );
    WHEN 'EMPLOYEE_PORTAL_TOKEN_REVOKED' THEN
      RETURN jsonb_build_object(
        'label', coalesce(p_payload ->> 'label', '—'),
        'revoke_reason', p_payload ->> 'revoke_reason',
        'compromised', coalesce(p_payload -> 'compromised', 'false'::jsonb)
      );
    WHEN 'EMPLOYEE_PORTAL_FIRST_ACCESS' THEN
      RETURN jsonb_build_object(
        'label', coalesce(p_payload ->> 'label', '—')
      );
    WHEN 'CONTACT_CREATED', 'CONTACT_ARCHIVED', 'CONTACT_UNARCHIVED' THEN
      RETURN jsonb_build_object('name', coalesce(p_payload ->> 'display_name', p_payload ->> 'name'));
    WHEN 'CONTACT_UPDATED' THEN
      IF p_payload ? 'changes' THEN
        RETURN jsonb_build_object(
          'changes', p_payload -> 'changes',
          'change_count', jsonb_array_length(p_payload -> 'changes')
        );
      END IF;
      RETURN jsonb_build_object('changes', '[]'::jsonb, 'change_count', 0);
    WHEN 'COMMENT_TASK_RESOLVED' THEN
      RETURN jsonb_build_object(
        'task_preview', p_payload ->> 'task_preview',
        'resolver_id', p_payload ->> 'resolved_by'
      );
    WHEN 'PROJECT_STATUS_CHANGED' THEN
      RETURN jsonb_build_object(
        'old', coalesce(p_payload ->> 'old_status', p_payload #>> '{old,status}'),
        'new', coalesce(p_payload ->> 'new_status', p_payload #>> '{new,status}')
      );
    WHEN 'CLIENT_REPORT_PUBLISHED',
         'CLIENT_REPORT_VERSION_CREATED',
         'CLIENT_REPORT_SHARE_CREATED',
         'CLIENT_REPORT_SHARE_REVOKED',
         'CLIENT_REPORT_SHARE_EMAIL_ENQUEUED',
         'CLIENT_REPORT_STAFF_SESSION_CREATED' THEN
      RETURN coalesce(p_payload, '{}'::jsonb);
    WHEN 'PROJECT_COMMERCIAL_ISSUED',
         'PROJECT_COMMERCIAL_SENT',
         'PROJECT_COMMERCIAL_ACCEPTED',
         'PROJECT_COMMERCIAL_REJECTED',
         'PROJECT_COMMERCIAL_CANCELLED',
         'PROJECT_COMMERCIAL_SUPERSEDED',
         'PROJECT_COMMERCIAL_INVOICE_CANCELLED',
         'PROJECT_COMMERCIAL_PAYMENT_RECORDED' THEN
      RETURN coalesce(p_payload, '{}'::jsonb);
    ELSE
      IF coalesce(p_action, '') LIKE 'ATTENDANCE\_%' ESCAPE '\' THEN
        RETURN coalesce(p_payload, '{}'::jsonb);
      END IF;
      RETURN jsonb_build_object('action', p_action);
  END CASE;
END;
$$;

CREATE OR REPLACE FUNCTION data.timeline_audit_message_key(p_action text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE p_action
    WHEN 'EMPLOYEE_CREATED' THEN 'timeline.audit.EMPLOYEE_CREATED'
    WHEN 'EMPLOYEE_UPDATED' THEN 'timeline.audit.EMPLOYEE_UPDATED'
    WHEN 'EMPLOYEE_TERMINATED' THEN 'timeline.audit.EMPLOYEE_TERMINATED'
    WHEN 'EMPLOYEE_DELETED' THEN 'timeline.audit.EMPLOYEE_DELETED'
    WHEN 'EMPLOYEE_PORTAL_TOKEN_CREATED' THEN 'timeline.audit.EMPLOYEE_PORTAL_TOKEN_CREATED'
    WHEN 'EMPLOYEE_PORTAL_TOKEN_REVOKED' THEN 'timeline.audit.EMPLOYEE_PORTAL_TOKEN_REVOKED'
    WHEN 'EMPLOYEE_PORTAL_FIRST_ACCESS' THEN 'timeline.audit.EMPLOYEE_PORTAL_FIRST_ACCESS'
    WHEN 'CONTACT_CREATED' THEN 'timeline.audit.CONTACT_CREATED'
    WHEN 'CONTACT_UPDATED' THEN 'timeline.audit.CONTACT_UPDATED'
    WHEN 'CONTACT_ARCHIVED' THEN 'timeline.audit.CONTACT_ARCHIVED'
    WHEN 'CONTACT_UNARCHIVED' THEN 'timeline.audit.CONTACT_UNARCHIVED'
    WHEN 'COMMENT_TASK_RESOLVED' THEN 'timeline.audit.TASK_RESOLVED'
    WHEN 'PROJECT_STATUS_CHANGED' THEN 'timeline.audit.PROJECT_STATUS'
    WHEN 'CLIENT_REPORT_PUBLISHED' THEN 'timeline.audit.CLIENT_REPORT_PUBLISHED'
    WHEN 'CLIENT_REPORT_VERSION_CREATED' THEN 'timeline.audit.CLIENT_REPORT_VERSION_CREATED'
    WHEN 'CLIENT_REPORT_SHARE_CREATED' THEN 'timeline.audit.CLIENT_REPORT_SHARE_CREATED'
    WHEN 'CLIENT_REPORT_SHARE_REVOKED' THEN 'timeline.audit.CLIENT_REPORT_SHARE_REVOKED'
    WHEN 'CLIENT_REPORT_SHARE_EMAIL_ENQUEUED' THEN 'timeline.audit.CLIENT_REPORT_SHARE_EMAIL_ENQUEUED'
    WHEN 'CLIENT_REPORT_STAFF_SESSION_CREATED' THEN 'timeline.audit.CLIENT_REPORT_STAFF_SESSION_CREATED'
    WHEN 'PROJECT_COMMERCIAL_ISSUED' THEN 'timeline.audit.PROJECT_COMMERCIAL_ISSUED'
    WHEN 'PROJECT_COMMERCIAL_SENT' THEN 'timeline.audit.PROJECT_COMMERCIAL_SENT'
    WHEN 'PROJECT_COMMERCIAL_ACCEPTED' THEN 'timeline.audit.PROJECT_COMMERCIAL_ACCEPTED'
    WHEN 'PROJECT_COMMERCIAL_REJECTED' THEN 'timeline.audit.PROJECT_COMMERCIAL_REJECTED'
    WHEN 'PROJECT_COMMERCIAL_CANCELLED' THEN 'timeline.audit.PROJECT_COMMERCIAL_CANCELLED'
    WHEN 'PROJECT_COMMERCIAL_SUPERSEDED' THEN 'timeline.audit.PROJECT_COMMERCIAL_SUPERSEDED'
    WHEN 'PROJECT_COMMERCIAL_INVOICE_CANCELLED' THEN 'timeline.audit.PROJECT_COMMERCIAL_INVOICE_CANCELLED'
    WHEN 'PROJECT_COMMERCIAL_PAYMENT_RECORDED' THEN 'timeline.audit.PROJECT_COMMERCIAL_PAYMENT_RECORDED'
    ELSE 'timeline.audit.GENERIC'
  END;
$$;

-- ---------------------------------------------------------------------------
-- 5. record_payment — write / repair payment_recorded
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.record_payment(
  p_document_id uuid,
  p_amount_cents integer,
  p_method text,
  p_client_op_id uuid,
  p_reference text DEFAULT NULL,
  p_occurred_at timestamptz DEFAULT now()
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_doc data.commercial_documents%ROWTYPE;
  v_id uuid;
  v_remaining integer;
  v_ref text;
  v_pay_amount integer;
  v_pay_method text;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;
  IF p_client_op_id IS NULL THEN
    RAISE EXCEPTION 'client_op_id_required' USING ERRCODE = 'P0001';
  END IF;
  IF p_amount_cents IS NULL OR p_amount_cents <= 0 THEN
    RAISE EXCEPTION 'invalid_amount' USING ERRCODE = 'P0001';
  END IF;
  IF p_method NOT IN ('cash', 'card', 'transfer', 'bizum', 'payment_link') THEN
    RAISE EXCEPTION 'invalid_payment_method' USING ERRCODE = 'P0001';
  END IF;
  IF p_method = 'payment_link'
     AND NULLIF(btrim(COALESCE(p_reference, '')), '') IS NULL THEN
    RAISE EXCEPTION 'payment_link_reference_required' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_doc
  FROM data.commercial_documents
  WHERE id = p_document_id;
  IF NOT FOUND OR NOT (data.jwt_user_tenants() ? v_doc.tenant_id::text) THEN
    RAISE EXCEPTION 'document_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  IF v_doc.doc_type = 'invoice' THEN
    RAISE EXCEPTION 'use_record_invoice_payment' USING ERRCODE = 'P0001';
  END IF;

  PERFORM data.guard_payment_fiscal_year(v_doc.tenant_id, p_occurred_at);

  IF v_doc.project_id IS NOT NULL THEN
    PERFORM 1
    FROM data.commercial_documents d
    WHERE d.tenant_id = v_doc.tenant_id
      AND d.project_id = v_doc.project_id
    FOR UPDATE;
  ELSE
    PERFORM 1
    FROM data.commercial_documents d
    WHERE d.id = v_doc.id
    FOR UPDATE;
  END IF;

  SELECT * INTO v_doc
  FROM data.commercial_documents
  WHERE id = p_document_id;

  SELECT id INTO v_id
  FROM data.payments
  WHERE tenant_id = v_doc.tenant_id
    AND client_op_id = p_client_op_id;
  IF v_id IS NOT NULL THEN
    -- Idempotent + repair missing narrative event
    SELECT amount_cents, method, reference
    INTO v_pay_amount, v_pay_method, v_ref
    FROM data.payments
    WHERE id = v_id;
    PERFORM data.ensure_commercial_payment_recorded_event(
      v_doc.tenant_id, p_document_id, v_uid, p_client_op_id, v_id,
      v_pay_amount, v_pay_method, v_ref, '[]'::jsonb
    );
    RETURN v_id;
  END IF;

  IF v_doc.doc_type = 'delivery_note' THEN
    IF v_doc.status NOT IN ('issued', 'signed', 'accepted') THEN
      RAISE EXCEPTION 'payment_document_not_collectable' USING ERRCODE = 'P0001';
    END IF;
    IF data.delivery_note_is_invoiced(v_doc.id) THEN
      RAISE EXCEPTION 'delivery_note_invoiced' USING ERRCODE = 'P0001';
    END IF;
  ELSIF v_doc.doc_type IN ('quote', 'quote_amendment') THEN
    IF v_doc.status NOT IN ('accepted', 'signed') THEN
      RAISE EXCEPTION 'payment_document_not_collectable' USING ERRCODE = 'P0001';
    END IF;
  ELSE
    RAISE EXCEPTION 'payment_document_not_collectable' USING ERRCODE = 'P0001';
  END IF;

  v_remaining := data.commercial_payment_remaining_cents(v_doc.id);
  IF p_amount_cents > v_remaining THEN
    RAISE EXCEPTION 'payment_exceeds_remaining' USING ERRCODE = 'P0001';
  END IF;

  v_ref := NULLIF(btrim(COALESCE(p_reference, '')), '');

  INSERT INTO data.payments (
    tenant_id, document_id, amount_cents, method, reference,
    collected_by, occurred_at, client_op_id
  ) VALUES (
    v_doc.tenant_id, p_document_id, p_amount_cents, p_method,
    v_ref,
    v_uid, COALESCE(p_occurred_at, now()), p_client_op_id
  ) RETURNING id INTO v_id;

  PERFORM data.ensure_commercial_payment_recorded_event(
    v_doc.tenant_id, p_document_id, v_uid, p_client_op_id, v_id,
    p_amount_cents, p_method, v_ref, '[]'::jsonb
  );

  RETURN v_id;
END;
$$;

REVOKE ALL ON FUNCTION api.record_payment(uuid, integer, text, uuid, text, timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.record_payment(uuid, integer, text, uuid, text, timestamptz)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 6. record_invoice_payment — write / repair payment_recorded after allocations
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.record_invoice_payment(
  p_invoice_id uuid,
  p_amount_cents integer,
  p_method text,
  p_reference text,
  p_client_op_id uuid,
  p_occurred_at timestamptz DEFAULT now()
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_tenant uuid := data.active_tenant_id();
  v_invoice data.commercial_documents%ROWTYPE;
  v_existing data.payments%ROWTYPE;
  v_payment_id uuid;
  v_left integer;
  v_slice integer;
  v_row record;
  v_open integer := 0;
  v_pos int := 0;
  v_allocations jsonb := '[]'::jsonb;
  v_ref text;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'active_tenant_required' USING ERRCODE = 'P0001';
  END IF;
  PERFORM data.assert_invoice_permission(v_tenant, 'invoices.edit');
  PERFORM data.guard_payment_fiscal_year(v_tenant, p_occurred_at);
  IF p_client_op_id IS NULL THEN
    RAISE EXCEPTION 'client_op_id_required' USING ERRCODE = 'P0001';
  END IF;
  IF p_amount_cents IS NULL OR p_amount_cents <= 0 THEN
    RAISE EXCEPTION 'invalid_amount' USING ERRCODE = 'P0001';
  END IF;
  IF p_method NOT IN ('cash', 'card', 'transfer', 'bizum', 'payment_link') THEN
    RAISE EXCEPTION 'invalid_payment_method' USING ERRCODE = 'P0001';
  END IF;

  v_ref := NULLIF(btrim(COALESCE(p_reference, '')), '');

  SELECT * INTO v_existing
  FROM data.payments
  WHERE tenant_id = v_tenant
    AND client_op_id = p_client_op_id;
  IF FOUND THEN
    SELECT COALESCE(jsonb_agg(
      jsonb_build_object(
        'delivery_note_id', a.delivery_note_id,
        'amount_cents', a.amount_cents,
        'position', a.position
      ) ORDER BY a.position
    ), '[]'::jsonb)
    INTO v_allocations
    FROM data.payment_allocations a
    WHERE a.payment_id = v_existing.id;

    PERFORM data.ensure_commercial_payment_recorded_event(
      v_tenant, v_existing.document_id, v_uid, p_client_op_id, v_existing.id,
      v_existing.amount_cents, v_existing.method, v_existing.reference, v_allocations
    );

    RETURN jsonb_build_object(
      'payment_id', v_existing.id,
      'amount_cents', v_existing.amount_cents,
      'allocations', v_allocations,
      'idempotent', true
    );
  END IF;

  SELECT * INTO v_invoice
  FROM data.commercial_documents
  WHERE id = p_invoice_id
  FOR UPDATE;
  IF NOT FOUND
     OR v_invoice.tenant_id IS DISTINCT FROM v_tenant
     OR NOT (data.jwt_user_tenants() ? v_invoice.tenant_id::text) THEN
    RAISE EXCEPTION 'document_not_found' USING ERRCODE = 'no_data_found';
  END IF;
  IF v_invoice.doc_type IS DISTINCT FROM 'invoice' OR v_invoice.status IS DISTINCT FROM 'issued' THEN
    RAISE EXCEPTION 'invoice_not_collectable' USING ERRCODE = 'P0001';
  END IF;

  PERFORM 1
  FROM data.commercial_documents d
  JOIN data.invoice_delivery_notes link ON link.delivery_note_id = d.id
  WHERE link.invoice_id = v_invoice.id
    AND link.released_at IS NULL
  ORDER BY d.id
  FOR UPDATE;

  SELECT COALESCE(SUM(x.remaining_cents), 0)::integer
  INTO v_open
  FROM (
    SELECT
      CASE
        WHEN d.project_id IS NOT NULL THEN COALESCE((
          SELECT b.remaining_cents
          FROM data.delivery_balances(v_invoice.tenant_id, ARRAY[d.project_id]) b
          WHERE b.delivery_note_id = d.id
        ), 0)
        ELSE GREATEST(
          0,
          data.commercial_document_total_cents(d.total)
          - COALESCE((
              SELECT SUM(p.amount_cents)::integer FROM data.payments p
              JOIN data.commercial_documents pd ON pd.id = p.document_id
              WHERE p.document_id = d.id AND pd.doc_type IS DISTINCT FROM 'invoice'
            ), 0)
          - COALESCE((
              SELECT SUM(a.amount_cents)::integer FROM data.payment_allocations a
              WHERE a.delivery_note_id = d.id
            ), 0)
        )
      END AS remaining_cents
    FROM data.invoice_delivery_notes link
    JOIN data.commercial_documents d ON d.id = link.delivery_note_id
    WHERE link.invoice_id = v_invoice.id
      AND link.released_at IS NULL
  ) x;

  IF p_amount_cents > v_open THEN
    RAISE EXCEPTION 'payment_exceeds_remaining' USING ERRCODE = 'P0001';
  END IF;

  INSERT INTO data.payments (
    tenant_id, document_id, amount_cents, method, reference,
    collected_by, occurred_at, client_op_id
  ) VALUES (
    v_invoice.tenant_id,
    v_invoice.id,
    p_amount_cents,
    p_method,
    v_ref,
    v_uid,
    COALESCE(p_occurred_at, now()),
    p_client_op_id
  ) RETURNING id INTO v_payment_id;

  v_left := p_amount_cents;
  FOR v_row IN
    SELECT
      d.id,
      CASE
        WHEN d.project_id IS NOT NULL THEN COALESCE((
          SELECT b.remaining_cents
          FROM data.delivery_balances(v_invoice.tenant_id, ARRAY[d.project_id]) b
          WHERE b.delivery_note_id = d.id
        ), 0)
        ELSE GREATEST(
          0,
          data.commercial_document_total_cents(d.total)
          - COALESCE((
              SELECT SUM(p.amount_cents)::integer FROM data.payments p
              JOIN data.commercial_documents pd ON pd.id = p.document_id
              WHERE p.document_id = d.id AND pd.doc_type IS DISTINCT FROM 'invoice'
            ), 0)
          - COALESCE((
              SELECT SUM(a.amount_cents)::integer FROM data.payment_allocations a
              WHERE a.delivery_note_id = d.id AND a.payment_id IS DISTINCT FROM v_payment_id
            ), 0)
        )
      END AS remaining_cents
    FROM data.invoice_delivery_notes link
    JOIN data.commercial_documents d ON d.id = link.delivery_note_id
    WHERE link.invoice_id = v_invoice.id
      AND link.released_at IS NULL
    ORDER BY COALESCE(d.issued_at, d.created_at), d.id
  LOOP
    v_slice := LEAST(v_left, v_row.remaining_cents);
    IF v_slice <= 0 THEN
      CONTINUE;
    END IF;

    INSERT INTO data.payment_allocations (
      tenant_id, payment_id, delivery_note_id, amount_cents, position
    ) VALUES (
      v_invoice.tenant_id, v_payment_id, v_row.id, v_slice, v_pos
    );

    v_allocations := v_allocations || jsonb_build_array(
      jsonb_build_object(
        'delivery_note_id', v_row.id,
        'amount_cents', v_slice,
        'position', v_pos
      )
    );
    v_pos := v_pos + 1;
    v_left := v_left - v_slice;
    EXIT WHEN v_left = 0;
  END LOOP;

  IF v_left <> 0 THEN
    RAISE EXCEPTION 'payment_allocation_incomplete' USING ERRCODE = 'P0001';
  END IF;

  PERFORM data.ensure_commercial_payment_recorded_event(
    v_tenant, v_invoice.id, v_uid, p_client_op_id, v_payment_id,
    p_amount_cents, p_method, v_ref, v_allocations
  );

  RETURN jsonb_build_object(
    'payment_id', v_payment_id,
    'amount_cents', p_amount_cents,
    'allocations', v_allocations,
    'idempotent', false
  );
END;
$$;

REVOKE ALL ON FUNCTION api.record_invoice_payment(uuid, integer, text, text, uuid, timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.record_invoice_payment(uuid, integer, text, text, uuid, timestamptz)
  TO authenticated, service_role;

COMMENT ON FUNCTION data.ensure_commercial_payment_recorded_event(
  uuid, uuid, uuid, uuid, uuid, integer, text, text, jsonb
) IS
  'CF-27: narrative payment_recorded on commercial_document_events; idempotent by client_op_id.';

NOTIFY pgrst, 'reload schema';
