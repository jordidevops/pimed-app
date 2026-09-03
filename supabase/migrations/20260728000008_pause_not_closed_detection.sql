-- F2.1: Detecció de pauses no tancades (crash/abandon d'app).
--
-- La funció `api.check_unclosed_pauses` escriu l'anomalia PAUSE_NOT_CLOSED
-- als time_punches i time_daily_summaries quan l'últim punch d'un empleat és
-- break_start i ha passat més temps del max_duration_minutes de la pausa.
-- S'executa via pg_cron cada 5 minuts.
--
-- El recompute worker actualitzat també detecta PAUSE_NOT_CLOSED durant
-- el recompute diari.

-- ─── 1. Funció principal de detecció ────────────────────────────────────────

CREATE OR REPLACE FUNCTION api.check_unclosed_pauses(
  p_tenant_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = api, data, public
AS $$
DECLARE
  v_tenant_id   uuid;
  v_default_max int := 240;  -- 4h per defecte si no hi ha config
  v_rec         record;
  v_max_min     int;
  v_elapsed_min numeric;
  v_count       int := 0;
BEGIN
  -- Opcionalment restringir a un tenant concret; sinó processa tots
  v_tenant_id := COALESCE(p_tenant_id, data.active_tenant_id());

  FOR v_rec IN
    SELECT DISTINCT ON (tp.employee_id)
      tp.id         AS punch_id,
      tp.employee_id,
      tp.tenant_id,
      tp.occurred_at AS break_start_at,
      tp.pause_type,
      (tp.occurred_at AT TIME ZONE 'Europe/Madrid')::date AS work_date
    FROM data.time_punches tp
    WHERE tp.punch_type = 'break_start'
      AND (v_tenant_id IS NULL OR tp.tenant_id = v_tenant_id)
      -- Només punches amb data d'avui o d'ahir (evitem processar historial llarg)
      AND tp.occurred_at >= now() - interval '2 days'
      -- Que no tinguin ja el codi PAUSE_NOT_CLOSED per evitar duplicats
      AND NOT ('PAUSE_NOT_CLOSED' = ANY(tp.anomaly_codes))
    ORDER BY tp.employee_id, tp.occurred_at DESC
  LOOP
    -- Comprovem que realment és l'últim punch de l'empleat avui
    -- (si hagués fet break_end o out posteriors, no seria l'últim)
    IF EXISTS (
      SELECT 1 FROM data.time_punches tp2
      WHERE tp2.employee_id = v_rec.employee_id
        AND tp2.occurred_at > v_rec.break_start_at
        AND tp2.punch_type IN ('break_end', 'out', 'in')
    ) THEN
      CONTINUE;  -- Hi ha punches posteriors: la pausa no és l'últim estat
    END IF;

    -- Obtenim el max_duration_minutes per aquest tipus de pausa del tenant
    SELECT COALESCE(
      (SELECT MIN(max_duration_minutes)
       FROM data.tenant_pause_configs
       WHERE tenant_id = v_rec.tenant_id
         AND is_active = true
         AND max_duration_minutes IS NOT NULL
         AND (pause_type = v_rec.pause_type OR v_rec.pause_type IS NULL)),
      v_default_max
    ) INTO v_max_min;

    -- Calculem minuts transcorreguts
    v_elapsed_min := EXTRACT(EPOCH FROM (now() - v_rec.break_start_at)) / 60;

    IF v_elapsed_min > v_max_min THEN
      -- Afegim PAUSE_NOT_CLOSED al punch de break_start
      UPDATE data.time_punches
      SET anomaly_codes = array_append(anomaly_codes, 'PAUSE_NOT_CLOSED')
      WHERE id = v_rec.punch_id
        AND NOT ('PAUSE_NOT_CLOSED' = ANY(anomaly_codes));

      -- Actualitzem time_daily_summaries si existeix
      UPDATE data.time_daily_summaries
      SET
        anomaly_codes = array_append(
          CASE WHEN NOT ('PAUSE_NOT_CLOSED' = ANY(anomaly_codes))
               THEN anomaly_codes ELSE anomaly_codes END,
          'PAUSE_NOT_CLOSED'
        ),
        needs_review = true,
        updated_at   = now()
      WHERE employee_id = v_rec.employee_id
        AND work_date   = v_rec.work_date
        AND NOT ('PAUSE_NOT_CLOSED' = ANY(anomaly_codes));

      v_count := v_count + 1;
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'processed', v_count,
    'tenant_id', v_tenant_id,
    'checked_at', now()
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.check_unclosed_pauses(uuid) TO service_role;

-- ─── 2. pg_cron: cada 5 minuts comprova pauses no tancades ──────────────────
-- Requereix l'extensió pg_cron habilitada (disponible a Supabase per defecte).
-- En entorns locals sense pg_cron, s'omet silenciosament.

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    IF NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'check-unclosed-pauses') THEN
      PERFORM cron.schedule(
        'check-unclosed-pauses',
        '*/5 * * * *',
        'SELECT api.check_unclosed_pauses(NULL);'
      );
    END IF;
  END IF;
END;
$$;

-- ─── 3. Actualitzar recompute_attendance_worker ──────────────────────────────
-- Afegim detecció de PAUSE_NOT_CLOSED al worker per al càlcul en diff.
-- Nota: l'afegim com a funció addicional post-recompute per no reescriure
-- el worker complet. El cron de 5 min és el mecanisme principal.

-- Funció auxiliar cridada al final del recompute per un dia/empleat concret
CREATE OR REPLACE FUNCTION data.detect_pause_not_closed_for_day(
  p_employee_id uuid,
  p_work_date   date
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_last_punch      record;
  v_max_min         int;
  v_elapsed_min     numeric;
BEGIN
  SELECT punch_type, occurred_at, pause_type, tenant_id, id
  INTO v_last_punch
  FROM data.time_punches
  WHERE employee_id = p_employee_id
    AND (occurred_at AT TIME ZONE 'Europe/Madrid')::date = p_work_date
  ORDER BY occurred_at DESC
  LIMIT 1;

  IF NOT FOUND OR v_last_punch.punch_type != 'break_start' THEN
    RETURN;
  END IF;

  SELECT COALESCE(
    (SELECT MIN(max_duration_minutes)
     FROM data.tenant_pause_configs
     WHERE tenant_id = v_last_punch.tenant_id
       AND is_active = true
       AND max_duration_minutes IS NOT NULL),
    240
  ) INTO v_max_min;

  v_elapsed_min := EXTRACT(EPOCH FROM (now() - v_last_punch.occurred_at)) / 60;

  IF v_elapsed_min > v_max_min
     AND NOT ('PAUSE_NOT_CLOSED' = ANY(
       SELECT UNNEST(anomaly_codes) FROM data.time_punches WHERE id = v_last_punch.id
     ))
  THEN
    UPDATE data.time_punches
    SET anomaly_codes = array_append(anomaly_codes, 'PAUSE_NOT_CLOSED')
    WHERE id = v_last_punch.id;
  END IF;
END;
$$;
