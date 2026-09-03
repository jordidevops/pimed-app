# UAT — Tier A solo (electricista proxy)

> Acceptació interna del flux V1 abans d’obrir V1.5.  
> Gate: [06-acceptance-and-gates.md](./06-acceptance-and-gates.md) · estat: [STATUS.md](./STATUS.md)

**Data:** _______________  
**Qui prova:** _______________  
**Tenant / seed:** `field_service` (demo: contact sites + ordre Muntaner al seed; UI amb archetype mock o recepta aplicada)  
**Resultat:** ☐ Acceptat · ☐ Rebutjat (motius a baix)  
**Enginyeria:** smoke Playwright `tests/field-service-smoke.spec.ts` (shell Avui / Ordres / Més)

---

## Preparació

- [ ] Tenant amb recepta `field_service` (labels “Ordre de servei”)
- [ ] Catàleg seed visible (visita / hora / km)
- [ ] Almenys 1 client amb 1 adreça (contact site)
- [ ] Prova en mòbil o viewport mòbil + (si cal) mode offline

## Cicle complet

| # | Pas | OK |
|---|-----|----|
| 1 | Veig vocabular “Ordre de servei” / “Client” (no “Projecte” genèric on no toca) | ☐ |
| 2 | Creo una ordre amb client + adreça + data planificada en ≤3 min | ☐ |
| 3 | L’ordre apareix a **Avui** el dia planificat | ☐ |
| 4 | Obro Maps / adreça des del detall | ☐ |
| 5 | FAB o equivalent: **Iniciar visita** (geo + cronòmetre) &lt; 5 s després del prompt | ☐ |
| 6 | Completo ≥1 ítem de checklist / tasca | ☐ |
| 7 | Afegeixo ≥1 material | ☐ |
| 8 | Afegeixo ≥1 foto al close-out | ☐ |
| 9 | Tanco la visita (stop work_log + estat completat) | ☐ |
| 10 | Sense xarxa: veig Avui i puc start/stop (o veig cua pendent) sense perdre dades | ☐ |

## Criteris qualitatius

- [ ] El camí natural ha estat Avui / FAB, no la llista Projectes d’oficina
- [ ] Sense formació prèvia (o amb ≤5 min d’orientació)
- [ ] Cap blocker de UX que impedeixi tancar el cicle

## Notes / blockers

_…_

## Signatura d’acceptació

| Rol | Nom | Data | Signatura |
|-----|-----|------|-----------|
| Producte | | | |
| Enginyeria (opcional) | | | |
