# Fase 3 — UI de fites

> **Ordre:** 3 · **Depèn de:** fase 2 · **Bloqueja:** UAT amb fites visibles  
> **Índex:** [`README.md`](./README.md) · O-D11, O-D14, O-D15, O-D16

## Objectiu

Oficina edita fites a l’acord `project` mentre la versió és editable; després només lectura + marcar completat/cancel·lat.

## UI

### Detall d’acord (obligatori)

- Secció «Fites» visible si `kind=project` (amagar a specific/recurring/framework).
- Draft / pre-enviament: llista editable (títol, import €, data, ordre). Afegir / eliminar / reordenar.
- Mostrar `%` derivat i suma vs contractat (rollup O-D11). Error si suma > contractat (toast via `commercialErrorMessage` o equivalent acords).
- Post-enviament/firma: taula RO + accions «Marcar fet» / «Cancel·lar fita».

### Prepare (opcional V1)

- No cal editor de fites dins el diàleg de prepare. Flux: prepare → detall acord → definir fites → enviar a firma.
- Documentar aquest ordre a copy d’ajuda.

### PDF

- V1: **no** bloqueja sense fites al PDF. Ideal: llista de fites al HTML de l’acord si la plantilla té un bloc opcional; si no hi ha token, les fites només viuen a UI/DB.
- No ampliar validador de tokens de pressupost (CT-D5). Si cal token nou, només al context d’**acord** (`commercialAgreementContext`).

## Checklist

- [ ] Secció fites al detall d’acord.
- [ ] Wire `replace` / `set_status` / `list`.
- [ ] Estats disabled segons versió.
- [ ] i18n ca (mínim).
- [ ] Empty state: «Cap fita — opcional però recomanat abans de firmar».
- [ ] No mostrar secció a kinds ≠ project.

## DoD

- [ ] Smoke UI: crear 2 fites, firma, marcar una completed, imports bloquejats.
- [ ] Suma > contractat mostra error i no desa.

## Fora d’aquesta fase

Targeta seguiment OS; auto-fita des de DN; PDF obligatori amb fites.
