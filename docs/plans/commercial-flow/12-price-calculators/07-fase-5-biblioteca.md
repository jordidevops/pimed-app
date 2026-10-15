# Fase 5 — Biblioteca i clonar

> **Tall desplegable:** sí
> **Schema:** files a `calculator_catalog` (la taula és de la fase 2; columnes `title`/`summary`/`default_case` a migració ready)
> **Depèn de:** fase 4
> **Supòsits:** D9; **D12 overturn** (veure sota)

## Overturn D12 (catàleg ready)

La biblioteca de plataforma ja **no** és un esquelet amb preus `null`. Conté receptes **llestes** amb preus **il·lustratius** + `default_case` (`name`, `params`, opcionalment `expected_lines`). El tenant clona, el portal orquestra cas verd + publish + `active`, i pot editar tarifes. Banner «preus d’exemple» fins a `tariffs_reviewed_at`.

## Abast

1. Cinc (o més) files de catàleg per `field_service`: visita tècnica, electricista, persianes, ascensors, HORECA. `catalog_version` ≥ 2. Tags heretats al clon.
2. Llista «Biblioteca» filtrada per arquetip (`generic` veu `field_service` si no n’hi ha de propi).
3. Clonar: RPC `api.clone_calculator_from_catalog` copia JSON + tags → `incomplete` + `cloned_from_*`. El **portal** activa els ready (cas + publish + active).
4. Sense «actualitzar des del catàleg». Sense edició del catàleg des del portal.
5. UI tipus plantilles: Les meves | Biblioteca; «Ja la tens» / Nova còpia.

## Verificació al navegador

- [ ] Tenant `field_service`: veu la biblioteca amb títols i resums.
- [ ] Clonar ready → activa i surt al flux ràpid / Apply.
- [ ] Banner de preus d’exemple; «He revisat les tarifes» el treu.
- [ ] Un altre tenant no veu el clon. Segona clonació = nova fila.

## Acceptació

- [ ] Test SQL: clone no escriu al catàleg; tenant B aïllat; catàleg amb almenys un preu numèric d’exemple i `default_case`.
- [ ] Motor: `activationGaps` ignora `bound_column` null als tiers.

## Fora

Merge/update des del catàleg v2, editor visual AST arbitrari.
