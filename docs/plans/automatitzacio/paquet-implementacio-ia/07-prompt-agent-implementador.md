# Prompt per a l'Agent Implementador

Copia aquest prompt quan vulguis encarregar la implementació del motor d'automatització a una IA.

---

## Prompt

Actua com a enginyer principal del projecte, expert en Supabase, PostgreSQL, PGMQ, Edge Functions en Deno, React/TypeScript i arquitectures multi-tenant.

Has d'implementar el motor d'automatització intern V1 seguint estrictament aquests documents:

1. `docs/plans/automatitzacio/arquitectura-automatitzacio-v2.md`
2. `docs/plans/automatitzacio/paquet-implementacio-ia/README.md`
3. `docs/plans/automatitzacio/paquet-implementacio-ia/01-revisio-tecnica-i-riscos.md`
4. `docs/plans/automatitzacio/paquet-implementacio-ia/02-contractes-events-workflows.md`
5. `docs/plans/automatitzacio/paquet-implementacio-ia/03-model-dades-contracte.md`
6. `docs/plans/automatitzacio/paquet-implementacio-ia/04-state-machine-i-concurrencia.md`
7. `docs/plans/automatitzacio/paquet-implementacio-ia/05-contracte-handlers.md`
8. `docs/plans/automatitzacio/paquet-implementacio-ia/06-roadmap-implementacio-agent.md`

## Regles obligatòries

- No implementis BPMN, pools, lanes, gateways avançats, loops interns ni compensacions Saga.
- No inventis una nova infraestructura de cues. Reutilitza PGMQ i QueueRunner.
- No creïs una taula `event_outbox`; PGMQ ja cobreix el patró transaccional.
- No facis que un handler encui directament el següent step. Usa una state machine central.
- No executis cap query de worker sense `tenant_id` explícit.
- No llegeixis steps des de `automation_workflows` durant una run; usa `automation_runs.workflow_snapshot`.
- No permetis JSONB lliure sense validar amb Zod.
- No implementis IA a V1. Només deixa el motor extensible per step types futurs.
- No implementis canvas visual a V1.

## Primer treball obligatori

Abans d'escriure migracions o codi, explora el repo i identifica patrons existents:

- `supabase/functions/_shared/queue-runtime.ts`
- `supabase/functions/_shared/supabase.ts`
- `supabase/functions/_shared/context-builder.ts`
- `supabase/functions/_shared/liquid-renderer.ts`
- Workers existents `process-email-queue`, `process-reminders-queue`, `process-deletion-queue`.
- Migracions de `audit_logs`, `notifications`, `calendar_events`, `tasks`, `documents`, `signing_submissions`.
- Vistes `api.*` i policies RLS existents.

Després explica breument quin patró local seguiràs.

## Ordre d'implementació

Segueix el roadmap de `06-roadmap-implementacio-agent.md` fase a fase.

No passis a la fase següent fins que la fase anterior compili i tingui una validació mínima.

## Criteris de qualitat

- Canvis petits i verificables.
- Migracions amb comentaris de capçalera actualitzats.
- Audit logs per canvis de cicle de vida.
- Tipus Supabase regenerats si es toca `data.*`, `api.*` o RPC exposades.
- Frontend amb i18n obligatori: `t('key', 'Fallback en Català')`.
- Tests o validacions per idempotència, concurrència i tenant isolation.

## Primer increment recomanat

Implementa només la Fase 1 i Fase 2:

- Migració base de taules d'automatització.
- RLS i vistes mínimes.
- Tipus regenerats.
- Zod schemas i helpers compartits.
- Sense UI encara.
- Sense handlers complexos encara.

En acabar, reporta:

- Fitxers modificats.
- Com validar localment.
- Quins riscos queden oberts.
