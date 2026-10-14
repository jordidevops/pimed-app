# Fase 5 — Biblioteca i clonar

> **Tall desplegable:** sí
> **Schema:** files a `calculator_catalog` (la taula és de la fase 2)
> **Depèn de:** fase 4
> **Supòsits:** D9, D12

## Abast

1. Dues files de catàleg, els exemples A i B de [`01-schema.md`](./01-schema.md), amb preus `null` (no `assumed`, no un número). `target_archetypes: ["field_service"]`. `catalog_version: 1`. `tags` opcionals (p. ex. `["desplaçament"]`, `["m2", "persianes"]`, D16) que el clon hereta i el tenant pot editar després sense cap vínc ul amb el catàleg.
2. Llista «Biblioteca» filtrada per l’arquetip del tenant (`sector_profiles.archetype` via el perfil ja carregat al portal). Si l’arquetip no és `field_service` ni `generic`, la llista pot ser buida. `generic` veu les de `field_service` només quan no n’hi ha cap amb el seu arquetip (avui no n’hi ha d’altres).
3. Clonar: RPC `api.clone_calculator_from_catalog` que copia el JSON i els `tags` a `calculator_definitions` del tenant, estat `incomplete`, `cloned_from_catalog_id` + `cloned_from_catalog_version`. No hi ha FK viva que actualitzi el clon. Auditoria `CALCULATOR_CLONED`.
4. El clon no surt al flux d’execució fins que passa la porta de la fase 4 (omplir preus + cas).
5. No hi ha botó «actualitzar des del catàleg». El camp `cloned_from_*` queda per un avís futur, que aquest epic no implementa.
6. El catàleg no es pot editar des del portal.

## Verificació al navegador

- [ ] Tenant `field_service`: veu les dues calculadores, sense imports a les taules.
- [ ] Clonar obre l’editor en incomplete. Activar segueix bloquejat.
- [ ] Omplir preus i un cas verd: passa a activa.
- [ ] Un altre tenant no veu el clon. El catàleg global no ha canviat.
- [ ] Tornar a clonar crea una segona còpia, no enllaça la primera.

## Acceptació

- [ ] Test SQL: clonar no escriu a `calculator_catalog`. Tenant B no llegeix el clon de A.
- [ ] Les files de catàleg no contenen cap preu numèric (asserció al test o al JSON de la migració).

## Fora

Verticals noves, merge automàtic, diff de «hi ha una versió nova».
