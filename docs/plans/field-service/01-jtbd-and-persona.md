# 01 — JTBD i persona

> Part del pla [Field Service / Work Orders](./README.md).

## Persona V1 — Tier A solo

| Atribut | Valor |
|---------|--------|
| Arquetip | `field_service` |
| Proxy de validació | Electricista autònom (també serveix lampista, clima, etc.) |
| Equip | **Una sola persona** porta tot: crear ordres, executar, tancar, cobrar (cobrament = integració, no V1) |
| Dispositiu principal | Mòbil al cotxe / obra; portàtil “diumenge al vespre” |
| Objectiu d’aprenentatge | Completar el cicle el primer dia **sense formació** |

No cal un vertical `electrician` al codi: el comportament el defineix l’arquetip; el vertical només aporta labels/catàleg seed ([03-sector-profiles](../../product-design/03-sector-profiles.md)).

## Persona V1.5 — Tier B micro-equip

Després del gate d’acceptació Tier A ([06](./06-acceptance-and-gates.md)):

| Rol | Necessitat |
|-----|------------|
| Admin / comercial | Crea ordres, pressupostos, planifica |
| Tècnic | Només veu **Avui** / les seves ordres; executa i tanca |
| Bundles | `tecnic`, `comercial`, `admin` ([04-roles](../../product-design/04-roles-and-permissions.md)) |

## Jobs-to-be-done (camp)

El tècnic / autònom només necessita **5 gestos diaris**:

1. **Veure què tinc avui** — lloc, hora, client
2. **Anar-hi** — adreça / deep-link Maps
3. **Iniciar visita** — cronòmetre + geo, un polze (FAB)
4. **Fer la feina** — checklist/tasques, fotos, materials
5. **Tancar** — resum, estat fet (signatura = V1.5)

## Jobs d’oficina (solo diumenge / Tier B admin)

- Crear ordre de servei
- Pressupost via `project_lines` + catàleg
- Planificar data (`planned_start` → CalendarEvent)
- Revisar temps / materials / documents
- Cobrar (integració — fora V1)

## Principi d’adopció

Si la UI principal és la llista genèrica de **Projectes** d’oficina, **fracassa l’adopció** encara que el backend sigui correcte. El camí natural ha de ser **Avui → FAB → close-out**.
