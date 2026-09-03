# Runbook: Offline deferred punch (ST-9 V2 / FF-04)

**Data:** 2026-07-17  
**Paquet:** EX-05.6  
**Flag:** `station_offline_deferred_punch`

---

## 1. Què fa

Permet a les estacions **desar fitxatges a la cua local** (IndexedDB) quan no hi ha xarxa i pujar-los després amb `occurred_at` = instant del toc i `received_at` = pujada.

**Sense el flag (default):** comportament V1 — sense xarxa no es pot fitxar; el servidor rebutja `p_occurred_at` amb `station_offline_disabled`.

**No és** identificació offline (cal haver identificat l’empleat abans).

---

## 2. Precondicions abans d’activar en producció

- [ ] EX-05.1–05.5 tancats (batch, outbox, timestamps, skew/max_age, E2E)
- [ ] CI `attendance-station-tests` verd (SQL + E2E offline)
- [ ] Tenant pilot acordat; WiFi del centre documentada
- [ ] RRHH informat de anomalies `CLOCK_SKEW` / `OFFLINE_DELAY`

---

## 3. Activar per un tenant

```sql
-- Override tenant (recomanat)
INSERT INTO data.tenant_feature_overrides (tenant_id, feature_key, override_status)
VALUES (
  '<TENANT_UUID>',
  'station_offline_deferred_punch',
  true
)
ON CONFLICT (tenant_id, feature_key) DO UPDATE
SET override_status = true,
    updated_at = now();
```

Verificar:

```sql
SELECT data.is_station_offline_deferred_punch_enabled('<TENANT_UUID>');
-- → true
```

Alternativa plataforma (tots els tenants): Admin → feature flags → `station_offline_deferred_punch` (`is_enabled`, `rollout_percentage`). El override tenant té prioritat.

Després d’activar: **recarregar / re-bootstrap** de l’estació (el kiosk llegeix `offline_deferred_punch_enabled` al bootstrap).

---

## 4. Desactivar (rollback operatiu)

```sql
INSERT INTO data.tenant_feature_overrides (tenant_id, feature_key, override_status)
VALUES ('<TENANT_UUID>', 'station_offline_deferred_punch', false)
ON CONFLICT (tenant_id, feature_key) DO UPDATE
SET override_status = false,
    updated_at = now();
```

Efectes:

| Cap | Comportament |
|-----|----------------|
| UI kiosk | Sense xarxa → error; no enqueue |
| Servidor | `occurred_at` → `403 station_offline_disabled` |
| Cua local pendent | El drain falla → quarantena (no esborra) |

Si hi ha pendents: buidar amb PIN admin (desparellar neteja outbox) o reactivar el flag, drenar i tornar a desactivar.

---

## 5. Diagnòstic

| Símptoma | Comprovar |
|----------|-----------|
| Offline no desa | Bootstrap `offline_deferred_punch_enabled`; override tenant |
| Sync falla `station_offline_disabled` | Flag desactivat després d’enqueue |
| `CLOCK_SKEW` / `OFFLINE_DELAY` | Normal en sync tardà; revisar a anomalies RRHH |
| `station_punch_too_old` | Cua > `attendance_offline_max_age_ms` (72 h) → quarantena |
| Duplicats | No haurien; `client_op_id` idempotent → `duplicate` |

Logs: Edge Function `station-api` (POST `/punch` amb `occurred_at`).  
DB: `data.time_punches` (`occurred_at`, `received_at`, `anomaly_codes`, `client_op_id`).

---

## 6. Settings relacionats (site / defaults)

| Clau | Default | Ús |
|------|---------|-----|
| `attendance_clock_offset_threshold_ms` | 300000 (5 min) | `CLOCK_SKEW` |
| `attendance_offline_delay_threshold_ms` | 300000 | `OFFLINE_DELAY` |
| `attendance_offline_max_age_ms` | 259200000 (72 h) | Rebuig `station_punch_too_old` |

---

## 7. Smoke ràpid post-activació

1. Estació aparellada, bootstrap amb `offline_deferred_punch_enabled: true`.
2. Mode avió → fitxar → banner «desat localment».
3. Tornar online → pending → 0; fila amb `received_at > occurred_at`.
4. Reintent mateix `client_op_id` → `duplicate`.

Scripts: `supabase/tests/e2e_attendance_station_offline_ex055.ps1` (local) / `.sh` (CI).
