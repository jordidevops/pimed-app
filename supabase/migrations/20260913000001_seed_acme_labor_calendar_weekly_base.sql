-- Seed helper: patró setmanal al calendari laboral Acme (dl–dv laboral, ds–dg festiu).
-- Cridat des de supabase/seeds/attendance_demo.sql després de db reset.
-- El calendari visual (buildDayMap) només mostra overrides + festius assignats;
-- work_schedules sol no omple la graella de l'empleat.

CREATE OR REPLACE FUNCTION data.seed_acme_labor_calendar_weekly_base()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_tenant_id    constant uuid := '10000000-0000-0000-0000-000000000001';
  v_site_gracia  constant uuid := '30000000-0000-0000-0000-000000000001';
  v_site_sants   constant uuid := '30000000-0000-0000-0000-000000000002';
  v_grp_oficina  constant uuid := '46000000-0000-0000-0000-000000000001';
  v_grp_taller   constant uuid := '46000000-0000-0000-0000-000000000002';
  v_grp_obres    constant uuid := '46000000-0000-0000-0000-000000000003';
  v_tz           constant text := 'Europe/Madrid';
  v_today        date := (now() AT TIME ZONE v_tz)::date;
  v_year         int;
  v_d            date;
  v_dow          int;
  v_is_holiday   boolean;
  v_weekends     int := 0;
  v_grp_days     int := 0;
BEGIN
  FOR v_year IN (EXTRACT(YEAR FROM v_today)::int - 1) .. (EXTRACT(YEAR FROM v_today)::int + 1) LOOP
    v_d := make_date(v_year, 1, 1);
    WHILE v_d <= make_date(v_year, 12, 31) LOOP
      v_dow := EXTRACT(DOW FROM v_d)::int;

      SELECT EXISTS (
        SELECT 1
        FROM data.planner_site_holidays(v_tenant_id, v_site_gracia, v_d, v_d) h
      ) INTO v_is_holiday;

      IF v_dow IN (0, 6) AND NOT v_is_holiday THEN
        INSERT INTO data.labor_calendar_overrides (
          tenant_id, site_id, group_id, employee_id,
          calendar_date, day_type, day_name, work_intervals
        )
        VALUES (
          v_tenant_id, NULL, NULL, NULL,
          v_d, 'holiday', 'Cap de setmana', '[]'::jsonb
        )
        ON CONFLICT ON CONSTRAINT labor_calendar_overrides_unique DO NOTHING;
        v_weekends := v_weekends + 1;
      ELSIF v_dow BETWEEN 1 AND 5 AND NOT v_is_holiday THEN
        -- Grup Oficina (global): jornada partida 37h
        INSERT INTO data.labor_calendar_overrides (
          tenant_id, site_id, group_id, employee_id,
          calendar_date, day_type, day_name,
          work_start, work_end, work_intervals
        )
        VALUES (
          v_tenant_id, NULL, v_grp_oficina, NULL,
          v_d, 'work', 'Laboral',
          '08:30'::time, '17:00'::time,
          '[{"start":"08:30","end":"14:00"},{"start":"15:00","end":"17:00"}]'::jsonb
        )
        ON CONFLICT ON CONSTRAINT labor_calendar_overrides_unique DO NOTHING;

        -- Grup Taller Gràcia: torn de matí
        INSERT INTO data.labor_calendar_overrides (
          tenant_id, site_id, group_id, employee_id,
          calendar_date, day_type, day_name,
          work_start, work_end, work_intervals
        )
        VALUES (
          v_tenant_id, v_site_gracia, v_grp_taller, NULL,
          v_d, 'work', 'Laboral',
          '07:00'::time, '15:00'::time,
          '[{"start":"07:00","end":"15:00"}]'::jsonb
        )
        ON CONFLICT ON CONSTRAINT labor_calendar_overrides_unique DO NOTHING;

        -- Grup Obres Sants
        INSERT INTO data.labor_calendar_overrides (
          tenant_id, site_id, group_id, employee_id,
          calendar_date, day_type, day_name,
          work_start, work_end, work_intervals
        )
        VALUES (
          v_tenant_id, v_site_sants, v_grp_obres, NULL,
          v_d, 'work', 'Laboral',
          '07:30'::time, '16:00'::time,
          '[{"start":"07:30","end":"16:00"}]'::jsonb
        )
        ON CONFLICT ON CONSTRAINT labor_calendar_overrides_unique DO NOTHING;

        v_grp_days := v_grp_days + 3;
      END IF;

      v_d := v_d + 1;
    END LOOP;
  END LOOP;

  RETURN jsonb_build_object(
    'weekend_rows', v_weekends,
    'group_work_rows', v_grp_days,
    'year_from', EXTRACT(YEAR FROM v_today)::int - 1,
    'year_to', EXTRACT(YEAR FROM v_today)::int + 1
  );
END;
$$;

REVOKE ALL ON FUNCTION data.seed_acme_labor_calendar_weekly_base() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.seed_acme_labor_calendar_weekly_base() TO service_role;
