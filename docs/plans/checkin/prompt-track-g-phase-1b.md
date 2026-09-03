# Prompt d'implementació — Track G Fase 1b (Segmentació)

> **Creat:** 2026-07-05  
> **Track:** G — Temps efectiu de treball  
> **Fase:** **1b** (segments + nous `punch_type` — **sense** buckets nous ni consolidació completa)  
> **PRD:** [`plan-effective-work-time.md`](./plan-effective-work-time.md) §5.0, §11.3  
> **Prerequisit:** G1 ✅ ([`prompt-track-g-phase-1.md`](./prompt-track-g-phase-1.md))  
> **Següent fase:** G2a (motor `fixed_site` + buckets)

---

## Rol

Ets un **Principal Engineer** al monorepo `pimed-app-supabase`. Implementa la **Fase 1b**: nous tipus de fitxatge, taula `time_activity_segments`, classificador des de punches, validació de seqüència per `work_profile`, i integració al `recompute_attendance_worker` — **sense** canviar `paid_minutes` / `effective_minutes` (G2a).

---

## Abast IN / OUT

### ✅ Dins d'aquest prompt

1. Ampliar CHECK `punch_type`: `day_start`, `day_end`, `travel_start`, `travel_end`
2. Taula `data.time_activity_segments` + RLS + vista `api.time_activity_segments`
3. `data.validate_time_punch_sequence(...)` per perfil resolt
4. Actualitzar `api.record_time_punch` (tenant + portal)
5. `data.classify_activity_segments(...)` — invocada des del worker
6. `recompute_attendance_worker`: crida classify; anomalies `DAY_NOT_CLOSED`, `TRAVEL_NOT_CLOSED`, `WORK_PROFILE_MISMATCH`
7. Presència mobile: finestra `day_start`→`day_end` (fallback `in`→`out` si `fixed_site` o legacy)
8. Tests SQL seqüències vàlides/invàlides + segments
9. Reserva FK `work_log_id`, `expense_ref_id` (nullable, sense omplir encara)

### ❌ Fora d'abast

| Item | Fase |
|------|------|
| `consolidate_day_buckets`, columnes summary noves | G2a |
| Lectura `work_logs.field_punch` al classificador | G2c |
| UI botons `day_start` / portal mobile | G3 |
| Feature flag `attendance_effective_time_enabled` | G2a |
| Taula `work_locations` | Descartada |

---

## Decisions tancades

1. **`fixed_site`**: només `in`/`out`/`break_*`; nous tipus → `WORK_PROFILE_MISMATCH`
2. **`mobile_peripatetic` / `hybrid` / `delivery`**: permeten nous tipus; `in` sense `day_start` permès si política `legacy_in_out_only` (default `true` per `fixed_site`, `false` per mobile)
3. Segments **recomputables**: DELETE + INSERT per `(employee_id, work_date)` dins classify
4. `worked_minutes` al summary **no canvia** encara (mateix algorisme in/out); G2a migrarà buckets
5. Classificador G1b: **només punches** (no `work_logs`)

---

## Ordre d'execució

```text
1. Schema segments + punch_type CHECK
2. validate_time_punch_sequence + record_time_punch
3. classify_activity_segments
4. Patch recompute_attendance_worker
5. Tests SQL
6. STATUS.md
```

---

## Criteris de done

- [ ] Migració aplica en local
- [ ] Tests `attendance_activity_segments_tests.sql` passen
- [ ] `fixed_site` rebutja `day_start` amb missatge clar
- [ ] Seqüència mobile `day_start→in→out→day_end` genera segments WORK+TRAVEL
- [ ] Recompute crida classify; segments persistits
- [ ] `worked_minutes` idèntic abans/després per jornada `fixed_site` només in/out
- [ ] STATUS G1b ⚠️ o ✅

---

*Fi del prompt — Track G Fase 1b*
