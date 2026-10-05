# EXECUTION — Ordre estricte per a l’agent

Font de veritat de **què fer ara**. Actualitzar [`STATUS.md`](./STATUS.md) en tancar cada fase.

## Abans de començar

1. Llegir [`README.md`](./README.md), [`01-product-and-naming.md`](./01-product-and-naming.md), [`02-data-model-and-ux.md`](./02-data-model-and-ux.md).
2. No implementar V2 ([`04-backlog-v2.md`](./04-backlog-v2.md)) fins a V1 tancada al checklist.
3. No editar el fitxer del pla Cursor com a font; aquest directori mana.

## Seqüència V1

```
Fase 0  Nav + i18n + stub ruta + tests resolveNav
   ↓
Fase 1  Projector multiday + colors + weekStartsOn + delete RPC/SQL
   ↓
Fase 2  EventDetail + CreateEventForm (àmbit, all-day, delete)
   ↓
Fase 3  CompanyCalendarPage + URL state + filtres + vistes
   ↓
Fase 4  Widget preview + Dashboard CTAs + e2e
   ↓
Fase 5  Acceptació + STATUS/CHECKLIST
```

## Regles d’implementació

- Una fase completa abans de la següent (excepció: stubs mínims a Fase 0).
- Preferir reutilitzar `CalendarGrid` / `useCalendarEvents` / registry; no duplicar Agenda FSM.
- Migracions locals: `npx supabase migration up --local` (o flux del repo).
- Commits només si l’usuari ho demana.
- En dubte de producte: reobrir [`01`](./01-product-and-naming.md); no inventar validity/filtres falsos.

## Després de V1

Ordre V2: **2.1 Cerca → 2.2 Els meus → 2.3 Time-grid → 2.4 DnD → 2.5 Integracions**.

No començar DnD sense time-grid si el DnD és a slots horaris; DnD a dia (month) pot anar en paral·lel menor, però el pla oficial és seqüencial.

**iCal (V2.5):** pla a [`06`](./06-ical-how-it-works.md) / [`07`](./07-ical-security.md) / [`08`](./08-ical-architecture-and-phases.md). Implementar per fases **I1→I4** de `08` quan es prioritzí; no començar OAuth abans.

## Prompt curt per reprendre

> Implementa la següent fase pendent de `docs/plans/company-calendar/` segons `EXECUTION.md` i marca el checklist. No facis V2.
