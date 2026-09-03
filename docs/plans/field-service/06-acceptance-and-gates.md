# 06 — Acceptació V1 i gates

> Part del pla [Field Service / Work Orders](./README.md).

## Gate V1 → V1.5

| | |
|--|--|
| **Què cal** | Flux Tier A solo **perfectament provat i acceptat** (E2E verd + UAT interna / proxy sectorial) |
| **Què no cal** | Adopció comercial (“ja tenim solos usant-ho al mercat”) ni N clients en producció |

Checklist operativa: [`uat-tier-a-checklist.md`](./uat-tier-a-checklist.md). Quan estigui acceptada, actualitzar [`STATUS.md`](./STATUS.md) i obrir backlog V1.5.

## Criteris d’èxit V1 (acceptació Tier A)

1. Un autònom `field_service` completa **crear → planificar → iniciar → tancar** el primer dia sense formació.
2. El camí natural al mòbil és **Avui / FAB**, no la llista Projectes d’oficina.
3. Temps medi “Iniciar visita” des de home &lt; 5 s (amb prompt de geo).
4. Offline: start/stop no perd dades (cua + quarantine visibles).
5. Smoke E2E verd + checklist UAT **acceptada** per producte.

## Criteri GTM (no és gate V1.5)

La validació amb **≥3 usuaris reals** del sector ([05-modules-roadmap](../../product-design/05-modules-roadmap.md) Fase D) és criteri de **maduresa de mòdul / go-to-market**, separat del gate d’entrada a V1.5.

## Ordre de treball (quan s’implementi)

1. Mantenir aquesta carpeta com a SoT del pla; actualitzar `STATUS.md` a cada epic.
2. Spike UX (wire Avui + close-out) abans o en paral·lel amb FS-0–2.
3. Implementar FS-0 → FS-4 en ordre; FS-5 tanca V1.
4. Amb Tier A solo acceptat → obrir V1.5 (signatura / dispatch light / bundles).
