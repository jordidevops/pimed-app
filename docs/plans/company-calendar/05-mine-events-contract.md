# Contracte «Els meus events» (V2.2)

Filtre `?mine=1` a `/calendar`. Combinat en **AND** amb tipus, site i cerca.  
No aplica al widget del dashboard.

## Regles per `entity_type`

| entity_type | És «meu» quan… |
|-------------|----------------|
| `manual` | `owner_id = auth.uid()` |
| `task` | `data.tasks.assignee_id = auth.uid()` (lookup per `entity_id`); o `metadata.assignee_id` / `metadata.assignee_user_id` |
| `shift_slot` | `metadata.employee_id =` empleat actiu de l’usuari al tenant |
| `project` | **Mai** a V2.2 (events d’empresa/camp, no personals) |
| altres | `owner_id = auth.uid()` |

## Implementació

- Helper: `apps/tenant-portal/src/features/calendar/mineCalendarEvents.ts`
- Lookup tasques: `useTaskAssignees` quan `mine=1`
- Empleat: `useMyEmployee`

## Fora d’abast V2.2

- Membres de projecte / visites FSM com a «meu»
- Persistència d’`assignee_id` a `calendar_events.metadata` (millora futura opcional)
