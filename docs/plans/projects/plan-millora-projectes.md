# Millora de Projectes

> **Estat:** Projects és el **substrat** d’ordres de servei, no el producte Field Service final.  
> **Pla FSM (prioritat #1 vertical):** [`../field-service/`](../field-service/)

## Relació amb Field Service

| Capa | On |
|------|-----|
| Motor (schema, CRUD, work_logs, lines, calendar) | `apps/tenant-portal/src/features/projects/` + migracions |
| Producte camp (Avui, FAB, close-out, PWA, labels sector) | [`docs/plans/field-service/`](../field-service/) |
| Pla històric d’implementació Projects | [`prompts/projectes/plan.md`](../../../prompts/projectes/plan.md) |

Qualsevol millora de Projectes orientada a `field_service` / `workshop_maker` a camp s’ha d’alinear amb els epics **FS-0…FS-5** i actualitzar [`../field-service/STATUS.md`](../field-service/STATUS.md).

## Fora d’aquest fitxer

- No reobrir taula `work_orders` separada (decisió **FS-1**).
- No confondre amb EAM `asset_work_orders` ni amb checkin “FSM” (veure [`../field-service/02-gap-and-naming.md`](../field-service/02-gap-and-naming.md)).
