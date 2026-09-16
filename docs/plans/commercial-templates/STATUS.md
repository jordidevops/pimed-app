# Plantilles comercials — Estat d'implementació

> **Última actualització:** 2026-09-16
> **Propòsit:** seguir el desenvolupament dels epics QT i deixar constància honesta del que falta.
> **Pla:** [`README.md`](./README.md) · backlog [`06-phases-and-backlog.md`](./06-phases-and-backlog.md) · ordre [`EXECUTION.md`](./EXECUTION.md)

## Llegenda

| Símbol | Significat |
|--------|------------|
| ✅ | Fet i usable |
| 🔄 | En curs |
| ❌ | No començat |
| ⚠️ | Parcial |
| 📦 | Diferit (fase 2 o fora d'abast) |

---

## Resum

**Pla documental creat.** Cap epic implementat. Fase activa: **QT-0**.

Decisions tancades: fallback intacte, categories `quote`/`delivery_note` noves i mútuament excloents amb `commercial`, HTML primer/DOCX fase 2, contracte signat només forward-compat (sense epic), firma real via motor natiu del DMS (Fase 3).

## Fase 1 — HTML de cos complet

| Epic | Nom | Estat | Notes |
|------|-----|-------|-------|
| QT-0 | Contracte de context + validació legal | ❌ | |
| QT-1 | Migració DB | ❌ | |
| QT-2 | Motor de renderitzat | ❌ | |
| QT-3 | Repositori de plantilles HTML | ❌ | |
| QT-4 | Frontend | ❌ | |
| QT-5 | Tests | ❌ | |

## Fase 2 — DOCX

| Epic | Nom | Estat | Notes |
|------|-----|-------|-------|
| QT-6 | Seed + renderitzat DOCX | 📦 | Diferit fins tancar fase 1 |
| QT-7 | Frontend DOCX | 📦 | Diferit fins tancar fase 1 |

## Fase 3 — Signatura nativa

| Epic | Nom | Estat | Notes |
|------|-----|-------|-------|
| QT-8 | Autoria de camps de signatura | ❌ | Depèn de QT-3 |
| QT-9 | Pipeline de firma nativa | ❌ | Depèn de QT-2, QT-8 |
| QT-10 | Submission Hub | ❌ | Depèn de QT-9; verificar estat del pla de signatures abans d'obrir |

## Changelog

| Data | Canvi |
|------|-------|
| 2026-09-16 | Creat paquet documental (README, guardrails per a agents IA, contracte de context i clàusules, arquitectura de renderitzat, repositori de plantilles, frontend, forward-compat de contracte, fases, EXECUTION, STATUS). Decisions: fallback intacte, categories noves mútuament excloents, HTML→DOCX en dues fases, contracte només disseny. |
| 2026-09-16 | Afegida Fase 3 (QT-8/9/10): integració amb el motor de firma nativa del DMS ja existent (`sign-document-router`, `signing-field-map.ts`, Submission Hub). Nou fitxer `07-signing-integration.md`. Nota forward-compat sobre facturació fiscal futura afegida a doc 05. |
