-- =============================================================================
-- Tenant AI — Phase 4: addon_ai hub/spoke + sync bridge for tenant_ai_config
-- =============================================================================

INSERT INTO data.billing_addons (
  id,
  name,
  price_monthly,
  trial_days,
  trial_cooldown_months,
  spoke_config
)
VALUES (
  'addon_ai',
  'Generació amb IA (BYOK)',
  0,
  14,
  6,
  '{"table": "tenant_ai_config", "features": {"is_active": true}}'::jsonb
)
ON CONFLICT (id) DO UPDATE
  SET name = EXCLUDED.name,
      spoke_config = EXCLUDED.spoke_config,
      trial_days = EXCLUDED.trial_days,
      updated_at = now();

-- Extend Hub→Spoke bridge: tenant_ai_config (UPSERT per tenants sense fila prèvia)
CREATE OR REPLACE FUNCTION data.sync_addon_to_spoke()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_spoke_config  jsonb;
  v_table_name    text;
  v_features      jsonb;
  v_col_name      text;
  v_col_value     jsonb;
  v_set_parts     text[]  := ARRAY[]::text[];
  v_sql           text;
  v_is_enabled    boolean;
BEGIN
  IF TG_OP = 'UPDATE' AND OLD.status = NEW.status THEN
    RETURN NEW;
  END IF;

  SELECT ba.spoke_config
    INTO v_spoke_config
    FROM data.billing_addons ba
   WHERE ba.id = NEW.addon_id;

  IF v_spoke_config IS NULL OR v_spoke_config = '{}'::jsonb THEN
    RETURN NEW;
  END IF;

  v_table_name := v_spoke_config->>'table';
  v_features   := v_spoke_config->'features';

  IF v_table_name IS NULL OR v_features IS NULL OR v_features = '{}'::jsonb THEN
    RETURN NEW;
  END IF;

  IF v_table_name NOT IN (
    'email_configs',
    'tenant_ai_config'
  ) THEN
    RAISE WARNING '[sync_addon_to_spoke] Taula Spoke no autoritzada: %. Addon: %, Tenant: %',
      v_table_name, NEW.addon_id, NEW.tenant_id;
    RETURN NEW;
  END IF;

  v_is_enabled := NEW.status IN ('active', 'trial');

  FOR v_col_name, v_col_value IN
    SELECT key, value FROM jsonb_each(v_features)
  LOOP
    IF v_is_enabled THEN
      CASE jsonb_typeof(v_col_value)
        WHEN 'boolean' THEN
          v_set_parts := array_append(
            v_set_parts,
            format('%I = %s', v_col_name, v_col_value::text)
          );
        WHEN 'number' THEN
          v_set_parts := array_append(
            v_set_parts,
            format('%I = %s', v_col_name, (v_col_value #>> '{}')::integer)
          );
        ELSE
          RAISE DEBUG '[sync_addon_to_spoke] Tipus JSON no suportat per a columna %: %',
            v_col_name, jsonb_typeof(v_col_value);
      END CASE;
    ELSE
      IF jsonb_typeof(v_col_value) = 'boolean' THEN
        v_set_parts := array_append(
          v_set_parts,
          format('%I = false', v_col_name)
        );
      END IF;
    END IF;
  END LOOP;

  IF array_length(v_set_parts, 1) IS NULL OR array_length(v_set_parts, 1) = 0 THEN
    RETURN NEW;
  END IF;

  IF v_table_name = 'tenant_ai_config' THEN
    INSERT INTO data.tenant_ai_config (tenant_id)
    VALUES (NEW.tenant_id)
    ON CONFLICT (tenant_id) DO NOTHING;

    v_sql := format(
      'UPDATE data.%I SET %s, updated_at = now() WHERE tenant_id = $1',
      v_table_name,
      array_to_string(v_set_parts, ', ')
    );
  ELSE
    v_sql := format(
      'UPDATE data.%I SET %s, updated_at = now() WHERE tenant_id = $1',
      v_table_name,
      array_to_string(v_set_parts, ', ')
    );
  END IF;

  EXECUTE v_sql USING NEW.tenant_id;

  RETURN NEW;

EXCEPTION
  WHEN OTHERS THEN
    RAISE WARNING '[sync_addon_to_spoke] Error sincronitzant addon % per tenant %: %',
      NEW.addon_id, NEW.tenant_id, SQLERRM;
    RETURN NEW;
END;
$$;
