# Plantilles comercials — Pla mestre d'execució

> **Rol:** única font de veritat de l'ordre d'implementació i del treball pendent
> **Creat:** 2026-09-16
> **Pla:** [`README.md`](./README.md) · estat per epic: [`STATUS.md`](./STATUS.md) · epics: [`06-phases-and-backlog.md`](./06-phases-and-backlog.md)
> **Fase activa:** *Cap epic obert.* Pla documental acabat de crear; QT-0 és el primer a obrir.
> **Instruccions obligatòries:** [`00-agent-instructions-and-guardrails.md`](./00-agent-instructions-and-guardrails.md) — llegir abans d'obrir QT-0.

## Disciplina

1. Llegir aquest fitxer, [`STATUS.md`](./STATUS.md) i [`00-agent-instructions-and-guardrails.md`](./00-agent-instructions-and-guardrails.md) a l'inici de **cada** conversa d'implementació.
2. Treballar **només** la fase activa, o un ítem de backlog acordat explícitament amb l'usuari. **Mai més d'un epic per sessió** (veure guardrail 1).
3. En tancar un epic: marcar-lo a `STATUS.md`, afegir línia al changelog, avançar la fase activa aquí. **No** continuar amb l'epic següent a la mateixa sessió.
4. Cap epic es dona per fet sense la comprovació corresponent de [`06-phases-and-backlog.md`](./06-phases-and-backlog.md) § Acceptació detallada.
5. Si una decisió de [`README.md`](./README.md) § «Decisions tancades» s'ha de reobrir, es documenta abans de tocar codi.
6. Cap migració destructiva (`DROP`/`ALTER` que elimini dades o columnes existents). Només additiu.
7. Regenerar `database.types.ts` (i copiar-lo a `supabase/functions/_shared/`) després de qualsevol migració d'aquest pla.

## Ordre real

| Ordre | Epic | Estat | Nota |
|------:|------|-------|------|
| 1 | **QT-0** Contracte de context + validació legal | ❌ | Primer a obrir |
| 2 | **QT-1** Migració DB | ❌ | Depèn de QT-0 |
| 3 | **QT-2** Motor de renderitzat | ❌ | Depèn de QT-1 |
| 3b | **QT-3** Repositori de plantilles HTML | ❌ | Contingut pot avançar en paral·lel a QT-1/QT-2 un cop QT-0 tancat |
| 4 | **QT-4** Frontend | ❌ | Depèn de QT-2 i QT-3 |
| 5 | **QT-5** Tests | ❌ | Depèn de QT-1 i QT-2 |
| — | *Gate Fase 1 → Fase 2* | ❌ | Veure `06-phases-and-backlog.md` |
| 6 | **QT-6** Seed + renderitzat DOCX | ❌ | Fase 2 |
| 7 | **QT-7** Frontend DOCX | ❌ | Fase 2 |

## Registre de treball

*(buit — cap epic tancat encara)*
