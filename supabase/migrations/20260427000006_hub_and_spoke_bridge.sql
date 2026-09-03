-- =============================================================================
-- Migració: 20260427000006_hub_and_spoke_bridge.sql
-- Propòsit : Sistema de Feature Flags / Addons — Capa Bridge (sincronització)
--            Quan l'estat d'un addon canvia, el trigger actualitza automàticament
--            la taula de configuració Spoke corresponent.
--
-- Conté:
--   1. data.sync_addon_to_spoke()  — Funció de trigger Hub → Spoke
--   2. Trigger sobre data.tenant_addons
--
-- Comportament:
--   · status → 'active' o 'trial':
--       Aplica els valors de spoke_config.features a la taula Spoke del tenant.
--       Ex: email_configs.custom_domains_enabled = true, max_custom_domains = 1
--
--   · status → 'canceled' o 'expired':
--       Revoca els permisos sense esborrar dades:
--         - Booleans → false (desactiva la funcionalitat)
--         - Enters   → es mantenen (el boolean ja n'impedeix l'ús)
--
-- Seguretat:
--   · SECURITY DEFINER: el trigger escriu a data.* saltant RLS
--   · Whitelist de taules Spoke permeses (evita escriptura arbitrària)
--   · format() amb %I (quoting d'identificadors) per prevenir SQL injection
--   · EXECUTE ... USING $1 per als valors dinàmics quan aplica
--   · Els errors no trenquen la transacció principal (EXCEPTION + WARNING)
--
-- Com afegir nous Spokes:
--   1. Afegeix el nom de la taula a la whitelist del CASE a la funció.
--   2. Insereix un nou registre a data.billing_addons amb el spoke_config adequat.
--   No cal canviar el trigger.
-- =============================================================================


-- ============================================================================
-- 1. data.sync_addon_to_spoke() — Bridge trigger function
-- ============================================================================

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
  -- ------------------------------------------------------------------
  -- Optimització: no fer res si l'status no ha canviat (UPDATE sense canvi)
  -- ------------------------------------------------------------------
  IF TG_OP = 'UPDATE' AND OLD.status = NEW.status THEN
    RETURN NEW;
  END IF;

  -- ------------------------------------------------------------------
  -- 1. Carregar spoke_config del catàleg
  -- ------------------------------------------------------------------
  SELECT ba.spoke_config
    INTO v_spoke_config
    FROM data.billing_addons ba
   WHERE ba.id = NEW.addon_id;

  IF v_spoke_config IS NULL OR v_spoke_config = '{}'::jsonb THEN
    -- Addon sense Spoke configurat (ex: addons de facturació pura)
    RETURN NEW;
  END IF;

  v_table_name := v_spoke_config->>'table';
  v_features   := v_spoke_config->'features';

  IF v_table_name IS NULL OR v_features IS NULL OR v_features = '{}'::jsonb THEN
    RETURN NEW;
  END IF;

  -- ------------------------------------------------------------------
  -- 2. WHITELIST de taules Spoke permeses
  --    Afegeix aquí cada nova taula de configuració que actuï com a Spoke.
  --    Aquesta és la barrera de seguretat contra escriptura arbitrària.
  -- ------------------------------------------------------------------
  IF v_table_name NOT IN (
    'email_configs'
    -- Afegeix nous Spokes aquí separats per comes:
    -- 'sms_configs',
    -- 'storage_configs',
  ) THEN
    RAISE WARNING '[sync_addon_to_spoke] Taula Spoke no autoritzada: %. Addon: %, Tenant: %',
      v_table_name, NEW.addon_id, NEW.tenant_id;
    RETURN NEW;
  END IF;

  -- ------------------------------------------------------------------
  -- 3. Determinar si s'habilita o es deshabilita
  -- ------------------------------------------------------------------
  v_is_enabled := NEW.status IN ('active', 'trial');

  -- ------------------------------------------------------------------
  -- 4. Construir les clàusules SET dinàmicament
  --    Itera sobre cada camp de features del spoke_config.
  --
  --    Quan s'HABILITA:
  --      · Boolean → el valor del catàleg (ex: custom_domains_enabled = true)
  --      · Integer → el valor del catàleg (ex: max_custom_domains = 1)
  --
  --    Quan es DESHABILITA:
  --      · Boolean → false (revoca l'accés sense esborrar dades)
  --      · Integer → no es modifica (el boolean ja n'impedeix l'ús)
  --
  --    Ús de format():
  --      · %I per als noms de columna (quoting segur d'identificadors SQL)
  --      · %s per als literals booleans (true/false, no requereixen quoting)
  --      · ::integer per validar tipus numèric (prevé injecció via JSON)
  -- ------------------------------------------------------------------
  FOR v_col_name, v_col_value IN
    SELECT key, value FROM jsonb_each(v_features)
  LOOP
    IF v_is_enabled THEN
      CASE jsonb_typeof(v_col_value)
        WHEN 'boolean' THEN
          -- v_col_value::text → 'true' o 'false' (literals SQL vàlids)
          v_set_parts := array_append(
            v_set_parts,
            format('%I = %s', v_col_name, v_col_value::text)
          );

        WHEN 'number' THEN
          -- Cast a integer per validar el valor i evitar injecció
          v_set_parts := array_append(
            v_set_parts,
            format('%I = %s', v_col_name, (v_col_value #>> '{}')::integer)
          );

        ELSE
          -- Altres tipus (text, array, object) no s'apliquen automàticament.
          -- S'han de gestionar amb triggers específics si cal.
          RAISE DEBUG '[sync_addon_to_spoke] Tipus JSON no suportat per a columna %: %',
            v_col_name, jsonb_typeof(v_col_value);
      END CASE;

    ELSE
      -- Deshabilitació: només revertim els booleans (bandera de permís)
      IF jsonb_typeof(v_col_value) = 'boolean' THEN
        v_set_parts := array_append(
          v_set_parts,
          format('%I = false', v_col_name)
        );
      END IF;
      -- Els enters (límits) no es modifiquen en desactivar:
      -- el boolean ja fa de barrera i les dades existents es preserven.
    END IF;
  END LOOP;

  -- ------------------------------------------------------------------
  -- 5. Executar l'UPDATE si hi ha alguna clàusula SET
  -- ------------------------------------------------------------------
  IF array_length(v_set_parts, 1) IS NULL OR array_length(v_set_parts, 1) = 0 THEN
    RETURN NEW;
  END IF;

  -- format() amb %I per al nom de la taula (whitelistada a pas 2)
  -- $1 per al tenant_id (binding segur via USING)
  v_sql := format(
    'UPDATE data.%I SET %s, updated_at = now() WHERE tenant_id = $1',
    v_table_name,
    array_to_string(v_set_parts, ', ')
  );

  EXECUTE v_sql USING NEW.tenant_id;

  RAISE DEBUG '[sync_addon_to_spoke] % addon % → tenant %: SQL executat',
    CASE WHEN v_is_enabled THEN 'ACTIVA' ELSE 'DESACTIVA' END,
    NEW.addon_id, NEW.tenant_id;

  RETURN NEW;

EXCEPTION
  WHEN OTHERS THEN
    -- Els errors del Bridge no han de trencar la transacció principal.
    -- Ex: si la fila de la taula Spoke no existeix (tenant sense email_configs),
    --     l'operació de toggle_addon no ha d'echoar.
    RAISE WARNING '[sync_addon_to_spoke] Error sincronitzant addon % per tenant %: %',
      NEW.addon_id, NEW.tenant_id, SQLERRM;
    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION data.sync_addon_to_spoke()
  IS 'Trigger Bridge Hub→Spoke. Quan l''estat d''un tenant_addon canvia, aplica o revoca '
     'les features a la taula de configuració definida a billing_addons.spoke_config. '
     'Errors del Bridge no trenquen la transacció principal.';


-- ============================================================================
-- 2. Trigger sobre data.tenant_addons
--    S'executa AFTER INSERT OR UPDATE OF status per capturar:
--      · Noves subscripcions (INSERT)
--      · Canvis d'estat (UPDATE): active↔trial↔canceled↔expired
-- ============================================================================

DROP TRIGGER IF EXISTS trg_sync_addon_to_spoke ON data.tenant_addons;

CREATE TRIGGER trg_sync_addon_to_spoke
  AFTER INSERT OR UPDATE OF status
  ON data.tenant_addons
  FOR EACH ROW
  EXECUTE FUNCTION data.sync_addon_to_spoke();

COMMENT ON TRIGGER trg_sync_addon_to_spoke ON data.tenant_addons
  IS 'Bridge Hub→Spoke: sincronitza les features de la taula Spoke quan l''addon s''activa o desactiva.';
