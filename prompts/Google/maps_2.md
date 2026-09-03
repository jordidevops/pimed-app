# Prompt: Pla d'implementació — Ubicació d'instal·lacions + Google Maps BYOK


---

## Rol

Ets un/a enginyer/a de producte i arquitectura de software. Has de produir un **pla d'implementació detallat** per afegir a una aplicació SaaS multi-tenant:

1. Alta / edició d’una **instal·lació o ubicació física (adreça)** amb adreça i coordenades, assistida per mapa i geocoding.
2. Configuració del tenant amb **claus API pròpies de Google Maps** (model Bring Your Own Key), separades per ús: Geocoding i Routes.

No escriguis codi de producció. El lliurable és un pla actionable.

---

## Context de producte

L’app gestiona entitats físiques (instal·lacions / edificis / punts de servei) que necessiten:

- Adreça estructurada (carrer, número, localitat, província, codi postal).
- Coordenades `lat` / `lng` fiables per mapes, distàncies, dispatch i llistes properes.
- Un nom visible de la instal·lació.

Els costos de Google Maps poden disparar-se en un SaaS B2B. Per això el tenant pot configurar la **seva pròpia clau** (BYOK) i aprofitar el crèdit gratuït de Google. Si no en té, el sistema pot fer fallback a un proveïdor gratuït (p.ex. Nominatim/OSM) i/o a una clau de plataforma amb quotes per pla.

---

## Funcionalitat A — Formulari d’ubicació (alta / edició d’instal·lació)

### Objectiu UX

Un sol formulari on l’usuari pot definir la ubicació de tres maneres equivalents i sincronitzades:

| Via | Què passa |
|-----|-----------|
| **Cerca d’adreça** | Escriu text → crida a servei de geocoding (forward) → suggereix resultats → en seleccionar-ne un omple `lat`/`lng` + camps d’adreça (+ opcionalment el nom si està buit). |
| **Clic al mapa** | Clica el mapa → actualitza `lat`/`lng` i el marcador; pot oferir reverse geocoding per omplir l’adreça. |
| **Edició manual de lat/lng** | Escriu o enganxa coordenades → el mapa es recentra i el marcador es mou; pot disparar reverse geocoding. |

També pot haver-hi un botó **“La meva ubicació”** (Geolocation API del navegador) que posa les coordenades i intenta reverse geocode.

### Camps del formulari

- **Nom de la instal·lació** (obligatori o amb default raonable).
- **Carrer**
- **Número**
- **Localitat** (ciutat)
- **Província**
- **Codi postal**
- **Latitud** (editable)
- **Longitud** (editable)
- Mapa interactiu amb marcador
- Camp de **cerca d’adreça** (pot ser separat dels camps estructurats)

Opcional segons domini: selector de seu/local (`site`), titular, referència cadastral, etc. Inclou-ho al pla només si cal; no inventis camps de negoci.

### Regles de sincronització (important)

1. Forward geocode (adreça → coords): omple coords **i** camps estructurats; si el nom està buit, proposa un nom tipus `{carrer} {número} - {ciutat}`.
2. Clic al mapa / edició de coords: actualitza marcador i vista del mapa (zoom mínim raonable, p.ex. 16).
3. Reverse geocode (coords → adreça): omple camps estructurats **sense** sobreescriure coords (ja són la font de veritat en aquest flux).
4. Validació: lat ∈ [-90, 90], lng ∈ [-180, 180].
5. En desar: persistir adreça + `lat`/`lng`. Si el domini ho necessita, calcular també `geohash` (o equivalent) al client o al servidor.
6. Mostrar estat de càrrega, errors (“cap resultat”, error de xarxa) i, si aplica, la **font** del resultat (`google` | `nominatim` | …).

### Mapa a la UI

- El mapa és per **posicionar**, no cal Google Maps JS obligatori per dibuixar tessel·les.
- Preferència raonable: mapa open-source (Leaflet / MapLibre) amb tiles OSM o similars, i Google només per **Geocoding / Routes** via backend.
- El clic al mapa ha de ser el mecanisme principal d’ajust fi; el scroll del mapa pot estar desactivat dins de modals.

### Backend de geocoding (no cridar Google des del browser amb la clau del tenant)

- Endpoints / callables autenticats, p.ex.:
  - `forwardGeocode({ tenantId, address })` → `{ suggestions[], source }`
  - `reverseGeocode({ tenantId, lat, lng })` → `{ street, streetNumber, city, province, postalCode, source, cached? }`
- Cascade recomanada (forward i reverse):
  1. Si el tenant té clau **Google Geocoding** → usar-la.
  2. Sinó → fallback gratuït (Nominatim) i/o clau de plataforma amb **quotes diàries/mensuals** del pla.
- Parsejar `address_components` de Google (o equivalent OSM) a camps estructurats.
- Retornar fins a N suggeriments (p.ex. 5).
- Timeout curt (p.ex. 8s), gestió d’errors clara, **mai** retornar la API key al client en aquests fluxos.
- Opcional però valuós: cache de geocoding (global o per tenant) + log d’ús / cost estimat.

---

## Funcionalitat B — Configuració del tenant: claus Google Maps (BYOK)

### Objectiu

A **Configuració / Settings** del tenant, una secció “Google Maps — Claus API” amb dues claus independents:

| Tipus | Ús |
|-------|-----|
| **Google Geocoding API** | Forward + reverse geocoding (adreces ↔ coordenades). |
| **Google Routes API** | Distàncies/temps per carretera (seu → instal·lació, tasques properes, etc.). |

### UX de la secció

- Estat: “configurada” (amb data d’actualització) vs “sense clau” (s’usen límits del pla / fallback).
- Formulari per enganxar la clau (`type=password`), desar, canviar.
- Guia curta: activar l’API a Google Cloud Console, crear clau, restringir-la, configurar budget alert.
- Accions: **provar clau** (ping controlat), **veure clau** (només rol molt restringit, p.ex. owner, amb re-auth si cal), **canviar clau**.
- Descripció clara de què fa cada clau i del cost.

### Seguretat (no negociable al pla)

- Les claus **es xifren en repòs** (p.ex. AES-256-GCM) amb clau mestra d’entorn; columnes típiques: ciphertext, IV, auth tag, key version.
- El frontend **no** ha de llegir el secret via API pública/GraphQL; només flags tipus `hasGeocodingKey` / `hasRoutesKey`.
- Guardar / llegir / provar clau només via backend autenticat.
- Autorització: només rols globals del tenant (p.ex. `owner` / `manager`); validar a BD, no confiar només en claims obsolets.
- Mai loguejar la clau en clar.
- Validar format mínim de la clau abans de desar.

### Relació amb producte

- Sense clau Geocoding: el formulari d’ubicació ha de continuar funcionant (fallback).
- Sense clau Routes: funcionalitats de distància per carretera degradades o desactivades; pot oferir distància en línia recta (haversine / PostGIS) com a alternativa gratuïta.
- Separar clarament al pla: **cost de tiles/mapa visual** vs **cost de Geocoding** vs **cost de Routes**.

---

## Stack d’exemple (adapta-ho)

Exemple de referència:

- Frontend: React + TypeScript, formulari controlat, mapa Leaflet.
- Backend: Edge Functions de Supabase.
- BD: PostgreSQL multi-tenant; secrets xifrats; flags `has_*_key` llegibles pel client.
- i18n: tots els strings visibles amb claus + fallback.

Si el teu stack és diferent, mantén el comportament de producte i adapta la capa tècnica.

---

## El que has de lliurar (estructura del pla)

1. **Resum executiu** (½ pàgina): valor de negoci i abast MVP vs post-MVP.
2. **User stories** i criteris d’acceptació (formulari + settings).
3. **Fluxos UX** (diagrames mermaid o steps): cerca, clic mapa, edició coords, meva ubicació, desar.
4. **Model de dades**: camps d’instal·lació; taula/config de `map_configs`; què es xifra vs què és flag públic.
5. **Arquitectura**: diagrama client ↔ backend ↔ Google / Nominatim; on viuen les claus; cascade i quotes.
6. **API contract** (request/response) de: `forwardGeocode`, `reverseGeocode`, `saveMapApiKey`, `getMapApiKey` (si cal), `testMapApiKey`.
7. **Seguretat i compliment**: xifrat, RBAC, restriccions de clau a Google Cloud, què no exposar.
8. **Gestió de costos**: BYOK vs clau plataforma; límits diaris/mensuals; cache; quan usar Routes vs haversine.
9. **Fases d’implementació** amb estimació relativa (S/M/L) i dependències:
   - Fase 0: schema + xifrat + save/test key
   - Fase 1: forward/reverse + UI formulari + mapa
   - Fase 2: settings UX completa + guies
   - Fase 3: Routes (si entra a l’abast) + distàncies
   - Fase 4: cache, quotes, observabilitat
10. **Riscos i mitigacions** (abuse de Nominatim, quotes Google, keys filtrades, desincronia mapa/form, GDPR d’ubicació).
11. **Pla de proves**: unitaris (parse components), integració (cascade), E2E (cerca → clic → desar), proves de permisos.
12. **Decisions obertes** amb recomanació: Google Maps JS vs Leaflet; una sola clau vs dues; cache global vs per tenant; reverse auto en cada clic vs botó explícit.

---

## Restriccions

- No proposis posar la API key de Google al frontend `.env` com a solució definitiva multi-tenant.
- No proposis llegir secrets via Postgres públic.
- No conflacionis “dibuixar el mapa” amb “Geocoding API” ni amb “Routes API”.
- Prioritza un MVP usable **sense** clau Google (fallback), i millora de qualitat/cost quan el tenant afegeix BYOK.
- Sigues concret: noms de mòduls, taules, endpoints i ordres de tasques. Evita fluff.

---

## Preguntes que pots fer (màxim 5)

Si falta informació crítica del stack o del domini, fes **com a màxim 5 preguntes** al final. Mentrestant, assumeix defaults raonables i marca-les com a assumpcions.

---

## Inici

Comença pel resum executiu i les decisions obertes amb la teva recomanació; després desenvolupa les fases.

Un cop implementat s'ha d'aplicar als contactes per donar d'alta adreces.
