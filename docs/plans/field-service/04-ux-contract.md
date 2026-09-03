# 04 — Contracte UX mòbil

> Part del pla [Field Service / Work Orders](./README.md).  
> Font de principis: [07-mobile-and-ai-leverage](../../product-design/07-mobile-and-ai-leverage.md).

## Principis

1. **Una mà, exterior, brutícia** — si no funciona així, no funciona.
2. **Today-first** — home = agenda d’avui + acció primària, no dashboard multi-widget d’oficina.
3. **FAB contextual** — per `field_service`: **Iniciar visita** (worklog + geo).
4. **Bottom nav ≤ 5** — la resta al drawer “Més”.
5. **Targets ≥ 48×48 dp**, tipografia ≥ 16px, contrast usable amb sol.

## Shell V1 (Tier A solo)

| Element | Contingut |
|---------|-----------|
| Home **Avui** | Ordres/visites amb `planned_start` avui: client, adreça, estat, hora |
| FAB | Iniciar visita → `start_work_log` + geo (RPCs existents) |
| Bottom nav | **Avui** \| **Ordres** \| **Agenda** \| **Més** |
| Detall ordre | Adreça + Maps, tasques/checklist, materials, worklog, timeline, close-out |
| Més | Clients, catàleg, settings, mòduls HR amagats o secundaris per recepta Tier A |

El tècnic ha de poder fer el dia **sense** obrir la llista genèrica “Projectes” d’oficina.

## Close-out (Epic FS-3)

Drawer / sheet inferior:

1. Aturar work_log (si obert)
2. Adjuntar ≥1 foto (DMS)
3. Registrar materials (opcional però UI present)
4. Marcar ordre / visita completada
5. Confirmació visible (estat + temps registrat)

Signatura del client = **V1.5**, no V1.

## Offline V1 (Epic FS-4)

| Sí offline | No offline (V1) |
|------------|-----------------|
| Llegir Avui (cache) | Crear contacte complet |
| Start/stop work_log | Pressupostos / cobraments |
| Completar tasca | |
| Pujar foto a cua | |

Patró: IndexedDB / Dexie + `client_op_id` (ja usat a field sync). PWA installable (`vite-plugin-pwa`) al tenant-portal — **no** app `tech-portal` separada a V1.

## Glossari UX

| Sigla / terme | Significat |
|---------------|------------|
| **FAB** | Floating Action Button — botó d’acció primària flotant |
| **JTBD** | Jobs To Be Done — “treballs” que l’usuari vol acabar |
| **Close-out** | Flux de tancament de visita |
| **PWA** | Progressive Web App installable |
