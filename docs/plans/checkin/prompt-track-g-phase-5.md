# Prompt d'implementació — Track G Fase 5 (Rollups + alertes + ledger C3)

> **Creat:** 2026-07-06  
> **Track:** G — Temps efectiu de treball  
> **Fase:** **5** (Rollups anuals multi-bucket + alertes legals + ledger C3)  
> **PRD:** [`plan-effective-work-time.md`](./plan-effective-work-time.md) §6.3, §7  
> **Prerequisit:** G4 ✅

---

## Rol

Implementar **comptadors legals incrementals** (rollups anuals), el **ledger de compensació** (Track C3), **alertes event-driven** en consolidar cada dia, i la **UI** de consulta (fitxa empleat, resum mensual, widget tauler).

---

## Entregables

| # | Fitxer | Descripció |
|---|--------|------------|
| 1 | `20260907000001_track_g_phase5_rollups_ledger_alerts.sql` | Taules rollups/snapshots/ledger/alerts + funcions sync + RPCs |
| 2 | `20260907000002_track_g_phase5_recompute_rollups_hook.sql` | Hook `sync_attendance_rollups_for_day` al recompute |
| 3 | `attendance_g5_rollups_ledger_tests.sql` | T1–T4: delta, sync+ledger, alert dedup, RPC counters |
| 4 | `legalCountersService.ts` + hooks | `get_attendance_legal_counters`, `list_site_legal_risk_employees` |
| 5 | `AttendanceLegalCountersPanel.tsx` | Barres % límit OT/treball/conveni + saldo C3 |
| 6 | `MonthlyAttendanceReportPanel.tsx` | Saldo compensació al resum mensual |
| 7 | `EmployeeTimesheetTab` + `MyRecordPage` | Panell comptadors a vista Mes |
| 8 | `DashboardLegalRiskWidget.tsx` + layout | Widget «Risc legal equip» al tauler |
| 9 | `attendance.json` | i18n `legal_counters.*`, `dashboard.legal_risk_*` |
| 10 | STATUS G5 ✅ | |

---

## Fora d'abast

- Compensació manual UI (moviments `compensated_time_off`, `paid_payroll`) — **C3.1+C3.2 ✅** (`20260909000001`, `CompensationLedgerPanel`)
- Crèdit automàtic festiu treballat en consolidar — **C3.3 ✅** (`20260909000002`, `attendance_c3_3_holiday_worked_auto_tests.sql`)
- Export D2 columna saldo compensació — **C3.4 ✅** (`20260909000003`, `attendance_c3_4_payroll_export_balance_tests.sql`)
- Protocol DMS portal Documents (G6)
- Cron global de rollups (només event-driven via recompute)

---

## Smoke test manual

1. Tenant amb `attendance_effective_time_enabled` + límits legals configurats.
2. Consolidar un dia amb hores extra autoritzades → comprovar rollup `cy:YYYY` i entrada ledger `accrued`.
3. Fitxa empleat → Timesheet → Mes: panell comptadors amb barres %.
4. Registre mensual: banner saldo compensació si `balance > 0`.
5. Tauler → widget Risc legal: empleats ≥80% límit OT.
6. Repetir consolidació amb mateix llindar → una sola fila a `attendance_legal_alert_fired`.
