# Prompt d'implementació — Track G Fase 2c (field_punch + gaps D-INT-7)

> **Creat:** 2026-07-05  
> **Track:** G — Temps efectiu de treball  
> **Fase:** **2c** (`work_logs.field_punch`, gaps declarats, RPCs composta)  
> **PRD:** [`plan-effective-work-time.md`](./plan-effective-work-time.md) §11.5b, §18.9  
> **Prerequisit:** G2b ✅ · [`prompt-track-g-phase-2b.md`](./prompt-track-g-phase-2b.md)  
> **Doc compartit:** [`prompts/shared/work-logs-time-attendance-integration.md`](../../../prompts/shared/work-logs-time-attendance-integration.md)

---

## Rol

Implementar la **Fase 2c**: integració **`work_logs.entry_mode = field_punch`** al classificador de segments, gaps declarats (**D-INT-7**), RPCs **`field_punch_start` / `field_punch_stop` / `switch_work_log`**, i detecció **`UNCLASSIFIED_GAP`** a consolidació.

**Model preferit (§18.5):** `day_start` → `field_punch`(projecte) → `switch_work_log` + gap → `day_end`. Coexisteix amb punch-only G2b (legacy).

---

## Entregables

| # | Fitxer | Descripció |
|---|--------|------------|
| 1 | `20260905000001_*` | `entry_mode`, `time_punch_*_id`, `work_log_field_gaps` |
| 2 | `20260905000002_*` | RPCs `field_punch_*`, `switch_work_log` |
| 3 | `20260905000003_*` | `classify_field_punch_segments` + patch classificador |
| 4 | `20260905000004_*` + `000005` | `collect_unclassified_gaps` + consolidate |
| 5 | `20260905000006_*` | Recompute: dia tancat field_punch sense in/out; no `MISSING_IN` |
| 6 | `attendance_effective_time_field_punch_tests.sql` | Fixtures A, B, D |
| 7 | STATUS G2c ✅ |

---

## Decisions tancades

1. **Classificador:** si existeix `field_punch` al dia → branca **`field_punch`**; sinó → **`mobile_walk`** (G2b)
2. **Segments WORK** des de `work_log.check_in`→`check_out` amb `work_log_id`; pausa legal des de punches
3. **Gaps declarats** a `work_log_field_gaps`; `UNCLASSIFIED` no genera segment — consolidate + `needs_review`
4. **`timer`/`manual`** work_logs **ignorats** pel classificador (D-INT-3)
5. **Un sol flag** `attendance_effective_time_enabled`

---

## Tests obligatoris

| Test | Assert |
|------|--------|
| TA | Lampista field_punch — mateixos buckets que G2b T1 + `work_log_id` |
| TB | Multi-obra, gap TRAVEL declarat — `needs_review=false` |
| TD | Gap UNCLASSIFIED 45 min — `needs_review`, `UNCLASSIFIED_GAP`, meta |

---

## Fora d'abast

- UI PunchPage / switch dialog (G3 / Projectes Fase 5)
- Timesheet fixture C (D-INT-11)
- `project_expenses` nullable (D-INT-12)
