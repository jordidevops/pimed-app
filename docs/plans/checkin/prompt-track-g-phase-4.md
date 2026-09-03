# Prompt d'implementació — Track G Fase 4 (Mensual EP8 + D2)

> **Creat:** 2026-07-05  
> **Track:** G — Temps efectiu de treball  
> **Fase:** **4** (Mensual EP8 + D2 desglossament + L1)  
> **PRD:** [`plan-effective-work-time.md`](./plan-effective-work-time.md) §6.1, §10, §11.7  
> **Prerequisit:** G3 ✅

---

## Rol

Ampliar el **resum mensual** (tenant + portal EP8) i l'**export nòmina D2** amb buckets de temps efectiu (`presence`, `effective`, `paid`, `travel`) i text **L1** actualitzat.

---

## Entregables

| # | Fitxer | Descripció |
|---|--------|------------|
| 1 | `20260906000001_*` | Patch `export_attendance_month`, `export_payroll_period`, `employee_portal_get_monthly_report`, `get_payroll_review_days` |
| 2 | `monthlyReportService.ts` | Tipus buckets + summary |
| 3 | `MonthlyEffectiveTimeSummary.tsx` | Resum mensual 4 columnes |
| 4 | `MonthlyAttendanceReportPanel.tsx` | Integració + columnes dia |
| 5 | `MonthlyEmployeeConfirmDialog.tsx` | L1 per perfil efectiu |
| 6 | `payrollExportService.ts` + `payrollConnectorTypes.ts` | Camps D2 §10 |
| 7 | Portal: `monthly-report-service.ts`, `PortalMonthlyPage.tsx` | EP8 buckets |
| 8 | STATUS G4 ✅ |

---

## Fora d'abast

- Rollups anuals / alertes (G5)
- Protocol DMS (G6)
- Barres setmanals (visual avançat — opcional post-MVP)

---

## L1 (confirmació empleat)

Quan hi ha dades de consolidació efectiva:

> «He revisat el temps **remunerable**, el temps efectiu i les hores extra del mes»

Sinó: text legacy «He revisat les hores del mes…».
