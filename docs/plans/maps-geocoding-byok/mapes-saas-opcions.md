# Mapes estables i legals en un SaaS multi-tenant

> **Estat:** Compilació de decisions / opcions de producte  
> **Data:** 2026-07-29  
> **Relacionat:** [FUTURE-google-maps-js.md](./FUTURE-google-maps-js.md) (mapa visual amb Google Maps JS — diferent de Geocoding/Routes BYO)

---

## TL;DR

- **Leaflet** és la llibreria que pinta el mapa: gratuïta i adequada per a SaaS.
- El fons del mapa són sempre **tiles** (o un mapa natiu Google). Sense tiles (o sense Maps JS), no hi ha mapa de carrers.
- **OSM (dades)** és adequat com a base cartogràfica; **`tile.openstreetmap.org`** no ho és com a CDN de producció a escala.
- Actualment el basemap no surt de Google tiles: la preferència “google” només canvia l’estil a **Carto Voyager** (vegeu `MapBasemapLayer.tsx`). Sense contracte/SLA, qualsevol CDN públic pot retirar-se.
- Per a producció estable i legal cal un **proveïdor amb contracte** (plataforma i/o BYOK del tenant).
- **Geocoding API** i **Routes API** (Settings actual) serveixen per adreces i rutes; **no** licencien ni substitueixen el mapa interactiu.

---

## 1. Conceptes (no confondre)

| Concepte | Què és | Es veu un mapa? |
|----------|--------|-----------------|
| **Leaflet** | Motor de dibuix al navegador (open source, BSD) | Només si té capa de fons |
| **Tiles** | Imatges `z/x/y` que formen el fons | Sí — són el mapa de carrers |
| **Base cartogràfica OSM** | Dades / estil OpenStreetMap | Sí, via tiles d’un servidor |
| **`tile.openstreetmap.org`** | Servidor públic de tiles de la comunitat OSM | Sí, però sense SLA i amb política restrictiva |
| **Proveïdor OSM** (MapTiler, Stadia, etc.) | Tiles basades en OSM amb contracte / quota | Sí — camí estable |
| **Map Tiles API** (Google) | Tiles oficials Google per al *vostre* renderer (p.ex. Leaflet) | Sí |
| **Maps JavaScript API** (Google) | Widget de mapa natiu de Google (substitueix o competeix amb Leaflet) | Sí |
| **Geocoding / Routes** | Adreça ↔ coordenades / distància per carretera | No pinten el mapa |

**No són alternatives:** “mapa OSM directe” vs “Leaflet + tiles”.  
En web, el patró habitual és: **Leaflet → demana tiles → les tiles són OSM o Google (o un altre)**.

```
Usuari veu el mapa
        ↑
   Leaflet (o Maps JS)
        ↑
   Tiles / mapa natiu
        ↑
   Dades cartogràfiques (OSM, Google, …)
```

---

## 2. Estat actual a l’app

- Mapes interactius amb **Leaflet** (`react-leaflet`) a tenant-portal, tiles→ `https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png`.
- A Settings es configuren claus de **Google Geocoding** i **Google Routes** (backend, xifrades).

### Riscos de l’estat actual

| Font de tiles | Problema |
|---------------|----------|
| `tile.openstreetmap.org` | Política de la OSMF: sense SLA; poden bloquejar; serveis comercials han d’assumir que l’accés es pot retirar. Adequat per prototip / poc trànsit, no com a dependència de producte a escala. |
| `mt*.google.com` | Ús no documentat / fora del canal oficial de Maps Platform. Sense garantia; possible bloqueig; ToS. |

---

## 3. Opcions tècniques estables i legals

Totes aquestes són vàlides si es fan amb API oficials / proveïdor amb ToS clars.

### A) Leaflet + proveïdor de tiles OSM

- Es manté Leaflet i el codi de zones / marcadors / clustering.
- Es canvia la URL de tiles cap a un proveïdor (MapTiler, Stadia, Geoapify, self-host, etc.).
- Atribució OSM (+ del proveïdor) visible.
- **Recomanat com a camí natural** si es vol multi-proveïdor i reutilitzar la UI actual.

### B) Leaflet + Google Map Tiles API

- Es manté Leaflet; les tiles venen de Google de forma **oficial** (API key, billing, **session token**).
- Més complex que un proveïdor OSM típic (cicle de sessió, quotes per tile).
- Facturació: típicament per tile (pan/zoom pot encarir).

### C) Google Maps JavaScript API

- Mapa natiu Google al navegador (`google.maps.Map`).
- Camí que Google empeny per a “mostrar un mapa a la web”.
- **No** és un simple canvi de URL de tiles: cal reescriure (o duplicar) pantalles de mapa.
- Controls, Street View, Places UI, etc. més integrats; menys flexible per “qualsevol proveïdor”.

### Què prefereix Google vs què encaixa al SaaS

| Punt de vista | Preferència |
|---------------|-------------|
| **Google (mapa web estàndard)** | Maps JavaScript API |
| **Aquesta app (ja amb Leaflet, multi-tenant, possible multi-proveïdor)** | Leaflet + tiles (OSM proveïdor i/o Map Tiles si és Google) |
| **Maps JS** | Té sentit si el producte és Google-only (o un subconjunt de pantalles) i s’accepta el cost de mantenir un segon stack |

---

## 4. Models de clau: plataforma vs BYOK

El mapa estable **sempre** implica un proveïdor de pagament / quota. Qui posa la clau:

### 4.1 Cortesia de plataforma (API key de la startup)

- La plataforma contracta el proveïdor i serveix mapa “out of the box”.
- **Avantatges:** millor onboarding; el tenant no toca Cloud Console.
- **Inconvenients:** cost variable, risc de factura; cal **límits per tenant**, alertes de billing i kill switch.
- Quan s’esgota el cupó: **no** hi ha un fallback “gratis il·limitat” legítim. Opcions honestes:
  - forçar **BYOK**, o
  - **deixar de mostrar el mapa** (amb missatge clar), o
  - ambdues.

### 4.2 BYOK (Bring Your Own Key) del tenant

- El tenant configura la seva clau (i el tipus de proveïdor).
- **Avantatges:** risc i cost al tenant; model alineat amb Geocoding/Routes actuals.
- **Inconvenients:** fricció d’onboarding; cal guiat per proveïdor; no és “enganxa qualsevol key”.

### 4.3 Híbrid (habitual en SaaS)

| Fase | Comportament |
|------|----------------|
| Sense clau del tenant | Cupó baix de plataforma **o** mapa desactivat |
| Límit de plataforma | Avís → BYOK o sense mapa |
| BYOK actiu | Cost i quota al compte del tenant |

**“Per defecte”** en producte sol significar: el mapa que es veu sense configurar res = **cortesia de plataforma** (si n’hi ha). No implica tiles públiques d’OSM/Google sense contracte.

---

## 5. Decisió de producte (ja presa): “Maps JS només” per al mapa visual

Amb el model BYOK actual (Geocoding/Routes servits via Edge Functions) i el risc de dependència de tiles públics (sense SLA), la decisió és:

- **El mapa visual només es mostra** quan el tenant té configurada **Maps JavaScript API BYOK** (clau al navegador) o bé té **entitlement temporal de plataforma** (kill switch + dates) gestionat a `admin-portal`.
- Si el tenant **no** té clau Maps JS i no té entitlement, la UI ha de funcionar en mode “sense mapa”: captura manual de coordenades, àrees textuals i la resta de fluxos (geocoding/rutes) continuen via Edge Functions.

Això elimina la “doble ruta visual” com si fos una elecció permanent (Leaflet+tiles vs Maps JS) i posa el focus en mantenir el mapa com a feature controlable en cost i disponibilitat.

---

## 6. Matriu de decisió (resum)

| Objectiu | Opció |
|----------|--------|
| Mínim risc de cost per a la startup | Només **BYOK** (o mapa apagat fins a configurar) |
| Millor onboarding amb cupó controlat | Plataforma amb **límit dur** + fallback BYOK / sense mapa |
| Reutilitzar UI Leaflet actual | **Leaflet + proveïdor de tiles** |
| Mapa 100 % experiència Google | **Maps JavaScript API** |
| Google oficial mantenint Leaflet | **Map Tiles API** |
| Geocodificar / rutes | Geocoding / Routes (ja a Settings) — **independent del mapa** |

### Què no fer en producció a escala

- Dependre de `tile.openstreetmap.org` com a CDN del producte.
- Dependre de `mt*.google.com` sense Map Tiles / Maps JS.
- Prometre mapa “gratis il·limitat” de plataforma sense límits ni BYOK.
- Tractar la clau de Geocoding com a llicència del mapa interactiu.

---

## 7. Separació clara amb el mòdul actual de Settings → Mapes

| Capacitat | API / mecanisme | Pinta el mapa? |
|-----------|-----------------|----------------|
| Forward / reverse geocoding | Google Geocoding (+ cascada / Nominatim) | No |
| Distància / temps per carretera | Google Routes | No |
| Fons del mapa Leaflet | Proveïdor de tiles / Map Tiles | Sí |
| Mapa natiu Google | Maps JavaScript API | Sí |



---

## 8. Orientació de producte (síntesi de la discussió)

1. **Leaflet** es pot mantenir com a motor; és adequat per a SaaS multi-tenant.
2. Per a mapes **estables i legals**, cal proveïdor amb contracte (OSM comercial i/o Google oficial).
3. El model més segur per a la startup és **BYOK** (o cupó de plataforma molt baix + tall + BYOK / sense mapa).
4. Si s’ofereix cortesia de plataforma, calen **límits per tenant** i un fallback honest (BYOK o amagar el mapa) — no un segon canal “gratis” no oficial.
5. Oferir **Leaflet+tiles** i **Maps JS** alhora és viable però car de mantenir; només amb modes acotats i proveïdors suportats explícitament.
6. Per a tenants poc tècnics, prioritzar **un proveïdor recomanat amb guia**; no Map Tiles “a pèl” ni “qualsevol key”.

---

## Referències

- [OSMF Tile Usage Policy](https://operations.osmfoundation.org/policies/tiles/)
- [Google Map Tiles API](https://developers.google.com/maps/documentation/tile/overview)
- [Google Maps JavaScript API](https://developers.google.com/maps/documentation/javascript)
- [Google Maps Platform Terms](https://cloud.google.com/maps-platform/terms)
- Codi actual: `apps/tenant-portal/src/components/maps/MapBasemapLayer.tsx`, `apps/tenant-portal/src/components/maps/CoordinatePicker.tsx`
