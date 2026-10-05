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
| Bottom nav | **Avui** \| **Ordres** \| **Horari** (si aplica) \| **Agenda** \| **Més** (`lg:hidden`, &lt;1024px; ≤5 slots) |
| Sidebar ≥ `lg` | Clúster **Camp** dins Operativa: Avui, Ordres, Agenda, Dispositiu (sync badge), Horari (si `canUseAttendance`) |
| Alçada curta | Sidebar compacta (context en popover, peu d’icones, **un sol scroll** al `aside`) perquè la nav mai col·lapsi a 0px |
| Agenda | `PageShell` (header sticky + tabs de vista); calendari/llista a l’esquerra; **Eines** a la dreta (Nova ordre, filtres, safata); mòbil: sheet d’eines |
| Agenda scope / safata | «Les meves / Totes» i safata sense planificar: només `owner`/`manager`; membres sempre `mine` |
| Detall ordre | Adreça + Maps, tasques/checklist, materials, worklog, timeline, close-out |
| Més | Clients, catàleg, settings, sync; mòduls HR amagats o secundaris per recepta Tier A |

El tècnic ha de poder fer el dia **sense** obrir la llista genèrica “Projectes” d’oficina.

`/field/calendar` redirigeix a `/field/agenda?view=week`. Inici manté el calendari genèric + enllaç a l’agenda de visites.

**Mes (mòbil vertical):** només punts de color per dia (OS / manteniment); tap → llista del dia.  
**Mes (apaisat / desktop):** targetes compactes (màx. 2) + `+N`.  
**Toolbar apaisada:** títol + controls en columnes; labels curts si `max-height` baixa.  
**Llista / Ordres:** dates amb locale de l’app (`ca-ES` / `es-ES` / `en-US`); Ordres ordenables per `planned_start`.

Estat fet vs fora d’abast: [`STATUS.md`](./STATUS.md) § Agenda de visites.

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
