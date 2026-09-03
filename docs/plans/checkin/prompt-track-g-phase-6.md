# Prompt d'implementació — Track G Fase 6 (Protocol DMS + portal Documents)

> **Creat:** 2026-07-07  
> **Track:** G — Temps efectiu de treball  
> **Fase:** **6** (Protocol de registre horari + DMS + portal Documents)  
> **PRD:** [`plan-effective-work-time.md`](./plan-effective-work-time.md) §8  
> **Prerequisit:** G4 ✅, G5 ✅

---

## Rol

Publicar el **protocol de registre horari** als empleats del portal (L1 lectura + checkbox, L2 signatura opcional), amb pestanya **Documents** i bloqueig opcional de fitxatge.

---

## Entregables

| # | Fitxer | Descripció |
|---|--------|------------|
| 1 | `20260908000001_track_g_phase6_protocol_dms.sql` | Taula assignments, plantilla DMS, settings, RPCs portal + manager |
| 2 | `documents-service.ts` + `employee-portal-api` routes | GET `/documents`, POST `/documents/acknowledge` |
| 3 | `PortalDocumentsPage` + nav + ruta `/portal/documents` | L1 ack + enllaç signatura L2 |
| 4 | `protocolSettings.ts` + `attendanceProtocolService.ts` | Settings tenant + publicació des de fitxa empleat |
| 5 | `AttendanceProtocolSettingsSection` | Configuració a `/settings/attendance-control` |
| 6 | Gate fitxatge `protocol_pending` | `employee_portal_has_pending_protocol` |
| 7 | STATUS G6 ✅ | |

---

## Fora d'abast (post-MVP) — backlog G6+

> **Estat MVP (G6):** publicació **manual per empleat** des de la fitxa; plantilla **plataforma fixa** (`71000000-…-030`); variables Liquid per empleat (nom, perfil de jornada, jurisdicció); L1 lectura+checkbox; L2 signatura opcional.

| # | Item | Estat |
|---|------|-------|
| G6.5 | Enllaç PunchPage tenant-portal | ✅ Lot 1 |
| G6.8 | Signatura sense email RRHH | ✅ Lot 1 — `resolve_employee_signer_email` |
| G6.9 | Registre mensual L2 `signers[]` | ✅ Lot 1 |
| G6.1 | Plantilla tenant configurable | ✅ Lot 2 — setting + selector Configuració |
| G6.2 | Protocol per perfil de jornada | ✅ Lot 2 — mapa + plantilles plataforma 031–033 |
| G6.3 | Publicació massiva | ✅ Lot 3 — cua PGMQ + diàleg Configuració |
| G6.4 | Onboarding automàtic | ✅ Lot 3 — setting + trigger employees |
| G6.6 | Republicació / versions | ✅ Lot 4 — supersede + protocol_version + audit |
| G6.7 | PDF asíncron (cua) | ✅ Lot 4 — pending + finalize després de pdf_job |
| G6.10 | Neteja documents orfes | ✅ Lot 4 — cron setmanal cleanup |

### Decisions pendents (producte)

- Un protocol **per empleat** (actual) vs **per grup** amb re-publicació en canvi de conveni.
- Si el tenant edita la plantilla: **versionar** i obligar re-ack / re-signatura?
- L2: un sol flux DocuSeal vs reutilitzar el PDF ja generat (`generate_only` + `sign` sobre `document_existing`).

---

## Smoke test

1. Configuració → Protocol: activar L1, opcional bloqueig fitxatge.
2. Fitxa empleat → Timesheet → «Publicar protocol horari».
3. Portal empleat → Documents: obrir PDF, confirmar lectura.
4. Si bloqueig actiu: fitxar abans d'ack → error `protocol_pending`.
5. Activar L2 signatura → republicar → signar des del portal.
