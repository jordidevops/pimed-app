-- EP9: push web en canvi de torn (shift_slots → cua → worker Edge)

SELECT pgmq.create('employee_portal_push_queue');

-- ─── Enqueue (mai bloqueja operacions de planificació) ───────────────────────

CREATE OR REPLACE FUNCTION data.enqueue_employee_portal_shift_push(
  p_tenant_id   uuid,
  p_employee_id uuid,
  p_slot_id     uuid,
  p_event       text
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_msg_id bigint;
  v_event  text := lower(btrim(COALESCE(p_event, '')));
BEGIN
  IF p_employee_id IS NULL OR p_slot_id IS NULL OR p_tenant_id IS NULL THEN
    RETURN NULL;
  END IF;

  IF v_event NOT IN ('assigned', 'changed', 'cancelled') THEN
    RETURN NULL;
  END IF;

  -- Només notificar si l'empleat té subscripcions actives
  IF NOT EXISTS (
    SELECT 1
    FROM data.employee_portal_push_subscriptions s
    WHERE s.employee_id = p_employee_id
      AND s.tenant_id = p_tenant_id
  ) THEN
    RETURN NULL;
  END IF;

  BEGIN
    SELECT pgmq.send(
      'employee_portal_push_queue',
      jsonb_build_object(
        'task', 'shift_push',
        'tenant_id', p_tenant_id,
        'employee_id', p_employee_id,
        'slot_id', p_slot_id,
        'event', v_event,
        'idempotency_key',
          format('portal-shift-%s-%s-%s', p_slot_id, v_event, extract(epoch from clock_timestamp())::bigint)
      )
    ) INTO v_msg_id;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'enqueue_employee_portal_shift_push failed: %', SQLERRM;
    RETURN NULL;
  END;

  RETURN v_msg_id;
END;
$$;

REVOKE ALL ON FUNCTION data.enqueue_employee_portal_shift_push(uuid, uuid, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.enqueue_employee_portal_shift_push(uuid, uuid, uuid, text) TO service_role;

-- ─── Context per al worker ───────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION api.get_shift_slot_push_context(p_slot_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_row record;
BEGIN
  SELECT
    ss.id AS slot_id,
    ss.tenant_id,
    ss.employee_id,
    ss.slot_date,
    ss.start_time,
    ss.end_time,
    ss.status,
    ws.name AS shift_name
  INTO v_row
  FROM data.shift_slots ss
  JOIN data.work_shifts ws ON ws.id = ss.shift_id
  WHERE ss.id = p_slot_id;

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  RETURN jsonb_build_object(
    'slot_id', v_row.slot_id,
    'tenant_id', v_row.tenant_id,
    'employee_id', v_row.employee_id,
    'slot_date', v_row.slot_date,
    'start_time', to_char(v_row.start_time, 'HH24:MI'),
    'end_time', to_char(v_row.end_time, 'HH24:MI'),
    'status', v_row.status,
    'shift_name', v_row.shift_name
  );
END;
$$;

REVOKE ALL ON FUNCTION api.get_shift_slot_push_context(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.get_shift_slot_push_context(uuid) TO service_role;

CREATE OR REPLACE FUNCTION api.list_employee_portal_push_subscriptions(
  p_employee_id uuid,
  p_tenant_id   uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_rows jsonb;
BEGIN
  SELECT COALESCE(jsonb_agg(row_to_json(s)::jsonb), '[]'::jsonb)
  INTO v_rows
  FROM (
    SELECT id, endpoint, p256dh, auth
    FROM data.employee_portal_push_subscriptions
    WHERE employee_id = p_employee_id
      AND tenant_id = p_tenant_id
    ORDER BY updated_at DESC
  ) s;

  RETURN v_rows;
END;
$$;

REVOKE ALL ON FUNCTION api.list_employee_portal_push_subscriptions(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.list_employee_portal_push_subscriptions(uuid, uuid) TO service_role;

CREATE OR REPLACE FUNCTION api.delete_employee_portal_push_subscription(p_endpoint text)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
BEGIN
  IF p_endpoint IS NULL OR btrim(p_endpoint) = '' THEN
    RETURN false;
  END IF;

  DELETE FROM data.employee_portal_push_subscriptions
  WHERE endpoint = p_endpoint;

  RETURN FOUND;
END;
$$;

REVOKE ALL ON FUNCTION api.delete_employee_portal_push_subscription(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.delete_employee_portal_push_subscription(text) TO service_role;

-- ─── Trigger: canvis rellevants a shift_slots publicats ──────────────────────

CREATE OR REPLACE FUNCTION data.trg_shift_slots_employee_portal_push()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.status = 'published' AND NEW.employee_id IS NOT NULL THEN
      PERFORM data.enqueue_employee_portal_shift_push(
        NEW.tenant_id, NEW.employee_id, NEW.id, 'assigned'
      );
    END IF;
    RETURN NEW;
  END IF;

  IF TG_OP = 'UPDATE' THEN
    IF OLD.status IS DISTINCT FROM 'published'
       AND NEW.status = 'published'
       AND NEW.employee_id IS NOT NULL THEN
      PERFORM data.enqueue_employee_portal_shift_push(
        NEW.tenant_id, NEW.employee_id, NEW.id, 'assigned'
      );
    END IF;

    IF OLD.status = 'published'
       AND NEW.status = 'cancelled'
       AND OLD.employee_id IS NOT NULL THEN
      PERFORM data.enqueue_employee_portal_shift_push(
        OLD.tenant_id, OLD.employee_id, OLD.id, 'cancelled'
      );
    END IF;

    IF OLD.status = 'published' AND NEW.status = 'published' THEN
      IF OLD.employee_id IS DISTINCT FROM NEW.employee_id THEN
        IF OLD.employee_id IS NOT NULL THEN
          PERFORM data.enqueue_employee_portal_shift_push(
            OLD.tenant_id, OLD.employee_id, OLD.id, 'cancelled'
          );
        END IF;
        IF NEW.employee_id IS NOT NULL THEN
          PERFORM data.enqueue_employee_portal_shift_push(
            NEW.tenant_id, NEW.employee_id, NEW.id, 'assigned'
          );
        END IF;
      ELSIF NEW.employee_id IS NOT NULL
        AND (
          OLD.shift_id IS DISTINCT FROM NEW.shift_id
          OR OLD.slot_date IS DISTINCT FROM NEW.slot_date
          OR OLD.start_time IS DISTINCT FROM NEW.start_time
          OR OLD.end_time IS DISTINCT FROM NEW.end_time
        ) THEN
        PERFORM data.enqueue_employee_portal_shift_push(
          NEW.tenant_id, NEW.employee_id, NEW.id, 'changed'
        );
      END IF;
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_shift_slots_employee_portal_push ON data.shift_slots;

CREATE TRIGGER trg_shift_slots_employee_portal_push
  AFTER INSERT OR UPDATE ON data.shift_slots
  FOR EACH ROW
  EXECUTE FUNCTION data.trg_shift_slots_employee_portal_push();

-- ─── Dispatcher pg_cron → Edge worker ────────────────────────────────────────

CREATE OR REPLACE FUNCTION data.invoke_employee_portal_push_worker(
  p_batch_size integer DEFAULT 20
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public, extensions
AS $$
DECLARE
  v_supabase_url text;
  v_service_key  text;
  v_request_id   bigint;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_net') THEN
    RAISE WARNING 'invoke_employee_portal_push_worker: pg_net not installed. Skipping.';
    RETURN -2;
  END IF;

  SELECT decrypted_secret INTO v_supabase_url
  FROM vault.decrypted_secrets WHERE name = 'app_supabase_url' LIMIT 1;

  SELECT decrypted_secret INTO v_service_key
  FROM vault.decrypted_secrets WHERE name = 'app_service_role_key' LIMIT 1;

  IF v_supabase_url IS NULL OR v_service_key IS NULL THEN
    RAISE WARNING 'invoke_employee_portal_push_worker: vault secrets not configured. Skipping.';
    RETURN -1;
  END IF;

  BEGIN
    SELECT extensions.http_post(
      url := v_supabase_url || '/functions/v1/process-employee-portal-push-queue',
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'Authorization', 'Bearer ' || v_service_key
      ),
      body := jsonb_build_object('batch_size', COALESCE(p_batch_size, 20)),
      timeout_milliseconds := 30000
    ) INTO v_request_id;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'invoke_employee_portal_push_worker: http_post failed: %', SQLERRM;
    RETURN NULL;
  END;

  RETURN v_request_id;
END;
$$;

REVOKE ALL ON FUNCTION data.invoke_employee_portal_push_worker(integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.invoke_employee_portal_push_worker(integer) TO service_role;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule('process-employee-portal-push-worker')
    WHERE EXISTS (
      SELECT 1 FROM cron.job WHERE jobname = 'process-employee-portal-push-worker'
    );

    PERFORM cron.schedule(
      'process-employee-portal-push-worker',
      '*/2 * * * *',
      'SELECT data.invoke_employee_portal_push_worker(20)'
    );
  END IF;
END;
$$;

NOTIFY pgrst, 'reload schema';
