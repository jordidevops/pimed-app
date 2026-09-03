# ADR-EC-WFM-02 — Temporalitat de rangs

| Camp | Valor |
|------|--------|
| **Estat** | Acceptat |
| **Data** | 2026-07-21 |
| **Paquet** | EC-WFM P1 |
| **Decideix** | Semiobert `[inici, fi)`, finals inclusius legacy i anti-solapament |
| **Relacionats** | Annex §9 · §16.2 |

## Context

Contractes usen `starts_on`/`ends_on` amb semàntica inclusiva històrica. Placements nous necessiten rangs sense solapament.

## Decisió

1. **`employee_placement_periods`:** interval semiobert `[starts_on, ends_on)` — `ends_on` NULL = obert. Un dia `d` hi pertany si `starts_on <= d AND (ends_on IS NULL OR d < ends_on)`.
2. **Contractes:** es manté la semàntica inclusiva existent de `starts_on`/`ends_on` (no es reinterpreta en P1).
3. **Anti-solapament:** un sol placement base per `(employee_id, dia)` via exclusió GiST / trigger.
4. **Trasllat:** tancar amb `ends_on = dia_inici_nou` i obrir fila nova el mateix dia (semiobert: el nou comença on acaba l'anterior).
5. **Torn puntual** en altre centre: `shift_slots.site_id`, no crea placement.

## Conseqüències

- UI i RPCs de placement documenten `[inici, fi)`.
- Conversió a dies inclusius només a capa de presentació si cal.
