# Prompt d'implementació — Track G Fase 3 (UI diària)

> **Creat:** 2026-07-05  
> **Track:** G — Temps efectiu de treball  
> **Fase:** **3** (UI 4 columnes + timeline segments + anomalies)  
> **PRD:** [`plan-effective-work-time.md`](./plan-effective-work-time.md) §5.4, §11.6  
> **Prerequisit:** G2a ✅ · G2b ✅ · G2c ✅

---

## Rol

Implementar la **Fase 3**: visualització diària del temps efectiu al tenant portal — resum **4 columnes**, **timeline de segments** (`time_activity_segments`), i catàleg d'**anomalies** de consolidació a la UI.

**Idioma UI:** català (claus i18n `attendance`).

---

## Entregables

| # | Fitxer | Descripció |
|---|--------|------------|
| 1 | `activitySegmentService.ts` | Tipus + fetch `api.get_activity_segments` |
| 2 | `effectiveTimeDayUtils.ts` | Helpers visibilitat columnes per perfil |
| 3 | `EffectiveTimeBucketsPanel.tsx` | Planificat · Presència/Net · Efectiu · Remunerable |
| 4 | `ActivitySegmentsTimeline.tsx` | Timeline segments per `activity_kind` |
| 5 | `dayDetailService.ts` | Ampliar `AttendanceDayDetail` amb segments |
| 6 | `AttendanceDayDetailDialog.tsx` | Integració panells quan hi ha buckets/segments |
| 7 | `anomalyUi.ts` + `attendance.json` | Anomalies G2 (`UNCLASSIFIED_GAP`, `DAY_NOT_CLOSED`, …) |
| 8 | STATUS G3 ✅ |

---

## Decisions tancades

1. **Mostrar panell efectiu** quan `summary` té buckets (`effective_minutes` / `presence_minutes` / `paid_minutes`) **o** hi ha segments
2. **Columna Remunerable** oculta si `fixed_site` i `paid_minutes === effective_minutes`
3. **Presència/Net:** mobile → `presence_minutes`; oficina → `worked_minutes` (net legacy)
4. **RPC segments:** `get_activity_segments(employee_id, work_date)` — ja existeix (G1b)
5. **PunchPage mobile** — ja implementat a G1b; **field_punch UI** → Projectes Fase 5
6. **Reclassificació segment (manager)** → post-MVP (sense RPC encara)

---

## Fora d'abast

| Item | Fase |
|------|------|
| EP8 mensual 4 columnes | G4 |
| Export D2 desglossament | G4 |
| Dashboard badge «Sense consolidació efectiva» | Opcional G3+ |
| `field_punch_start` / `switch_work_log` a PunchPage | Projectes F5 |
| Help `docs/help/horaris/temps-efectiu.md` | G0/G6 |

---

## Criteris d'acceptació

- [ ] Detall de dia mostra 4 columnes quan flag ON i consolidate ha omplert buckets
- [ ] Timeline segments amb colors per `WORK` / `TRAVEL` / `BREAK_*` / `OFF_DUTY` / `STANDBY`
- [ ] Anomalies noves visibles amb etiqueta + ajuda contextual
- [ ] Flag OFF o sense buckets → UI legacy sense regressió
- [ ] E6 (`approvalAssistUtils`) ja usa bucket per perfil — sense canvis obligatoris
