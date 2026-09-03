# Paquet de Treball per Implementar Automatització

**Objectiu:** convertir el pla `arquitectura-automatitzacio-v2.md` en una guia executable per a una IA implementadora.

Aquest directori no substitueix el pla arquitectònic. El complementa amb contractes, riscos i decisions d'implementació que no poden quedar implícites.

## Ordre recomanat de lectura

1. `01-revisio-tecnica-i-riscos.md` - que cal corregir del pla abans de picar codi.
2. `02-contractes-events-workflows.md` - contractes d'events, workflow JSONB i step definitions.
3. `03-model-dades-contracte.md` - model conceptual de taules, camps obligatoris i invariants.
4. `04-state-machine-i-concurrencia.md` - transicions, locks, idempotència i prevenció de bucles.
5. `05-contracte-handlers.md` - patró únic per implementar handlers d'accions.
6. `06-roadmap-implementacio-agent.md` - ordre d'implementació per fases i criteris d'acceptació.
7. `07-prompt-agent-implementador.md` - prompt base per donar a una IA quan comenci la implementació.

## Decisió executiva

Estic d'acord amb el nucli de `revisio_pla_v2.md`: la proposta V2 és bona conceptualment, però necessita més precisió tècnica abans d'implementar-la. Especialment en:

- Concurrència i execució duplicada de steps.
- Bucles indirectes entre workflows i `audit_logs`.
- Esquema rígid de JSONB validat amb Zod.
- State machine centralitzat: els handlers no decideixen el següent pas.
- Context de seguretat en background: `tenant_id`, `site_id`, `actor_user_id`, `triggered_by_run_id`.
- Execucions llargues: signatura, PDF i esperes han de tenir correlació explícita.

## Regla d'or per a la IA implementadora

Cap handler ha d'implementar la seva pròpia lògica de transició. Un handler només pot:

1. Reclamar el step de forma atòmica.
2. Executar l'acció.
3. Escriure `output` o `error`.
4. Marcar estat final del step.
5. Cridar una única funció central de transició.

La funció central de transició és l'únic lloc que decideix quin step ve després.
