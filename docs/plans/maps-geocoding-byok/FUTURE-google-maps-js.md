# Futur: Google Maps JavaScript (mapa visual) — Maps JS only

> **Estat:** fora d’abast del MVP actual.  
> **Context:** el pla [README.md](./README.md) i la decisió D1 ja no deixen el mapa visual com una opció permanent: **el mapa només es mostra si el tenant configura Maps JavaScript API BYOK** (clau al navegador) o bé té **entitlement temporal de plataforma** gestionat a `admin-portal`.
>
> **Aquest document:** què caldria per habilitar **mapa visual de Google** de manera opcional, com funciona la “clau publicable” (que necessàriament arriba al navegador), i un **prompt** per generar un pla d’implementació coherent amb “Maps JS only”.

---

## 1. Què tenim ara vs què demana “mapa Google”

| Capacitat | MVP actual (D1 visual) | Amb Maps JavaScript API |
|-----------|-------------------------|-------------------------|
| Dibuixar el mapa a pantalla | Leaflet + basemap (OSM o Carto) | SDK oficial Google Maps al navegador |
| Cerca / reverse d’adreces | `geocoding-proxy` → Google o Nominatim | Igual (es pot mantenir) |
| Distàncies per carretera | `routes-proxy` → Google Routes | Igual (es pot mantenir) |
| On viu la clau | Vault; **mai** al frontend | **Ha d’arribar al navegador** (key “publicable”) |
| Restricció típica GCP | Per **API** (Geocoding / Routes); IP no viable a Edge | Per **HTTP referrer / domini** (Maps JS) |
| Cost de “obrir un mapa” | ~0 (OSM) | Facturat per Google (Map Loads / sessions) |

**Conclusió:** tenir Geocoding / Routes BYOK **no** implica mapa visual Google. Cal un model addicional (Maps JS key) i un gating d’UX.

---

## 2. Decisió D1 i abast real (recordatori)

1. `CoordinatePicker` i el stack Leaflet ja existeixen i resolen la UX de captura d’adreça/coordenades.
2. Evitar facturar **map loads** fins que el tenant tingui una clau o entitlement.
3. Geocoding/Routes BYOK segueix sent **write-only** (clau al servidor).
4. El “fallback” visual de tiles OSM no és un camí de producció a escala: la decisió de producte és **Maps JS only per al mapa visual** (sense clau/entitlement → “mapa no disponible”, però coords/adreces continuen).

Canviar D1 és una **decisió de producte + cost + seguretat** i també una decisió de model d’UX (mapa no visible vs visible).

---

## 3. Què caldria per tenir mapes de Google

### 3.1 Producte / GCP (per tenant)

1. Al projecte Google Cloud del tenant: activar **Maps JavaScript API**.
2. Crear una **API key** pensada pel **navegador** (se serveix al client quan el tenant està habilitat).
3. Restringir la key per **Application restrictions → HTTP referrers** amb els dominis on realment es carrega el portal (veure §4).
4. Restringir per **API restrictions** a Maps JavaScript API (i el mínim necessari).
5. Documentació a Settings: hosts canònics (prod + staging) i nota sobre white-label.

### 3.2 Plataforma

1. Secret separat: `secret_type = 'maps_js_api_key'` (clau publicable, però només per a aquest secret_type).
2. Candidate → Verify → Activate amb una “prova” que carregui un mapa preview i capturi errors (sense heurístiques de referrer backend).
3. Endpoint autenticat per retornar la clau efectiva al navegador (amb RBAC per tenant).
4. Frontend: loader oficial i gating visual “mapa no disponible” si no hi ha key/entitlement.
5. Observabilitat: `onError` / `gm_authFailure` i telemetria agregada per admin-portal (sense clau ni URL-path sensibles).

### 3.3 Alternativa no recomanada

No considerar “Leaflet + tiles Google no oficials” com a producte: és fràgil i incompatible amb un camí legal i contractat.

---

## 4. Dificultat clau: restricció per domini (HTTP referrers)

Maps JavaScript API està dissenyada per executar-se al **navegador**. Google espera que la clau estigui limitada als **orígens** des d’on es carrega l’script.

### 4.1 Per què és difícil en un SaaS multi-tenant

| Escenari | Problema |
|----------|----------|
| Un sol domini SaaS (`app.pimed.example`) | Relativament fàcil: el tenant afegeix `https://app.pimed.example/*` (i preview/staging si cal). |
| Dominis custom per tenant (`client.pimed.app`, white-label) | Cal llista de referrers **per tenant** o instruccions perquè cada un afegeixi el seu host. |
| Localhost / preview deploys (`*.vercel.app`, ports locals) | Si no s’afegeixen, “mapa blanc” / `RefererNotAllowedMapError` en desenvolupament. |
| Geocoding key reutilitzada al browser | Mal model: la mateixa clau amb Geocoding + sense referrer pot filtrar-se i abusar-se des de qualsevol origen. |

**Edge Functions no serveixen de “proxy de tiles” trivial** per Maps JS: l’SDK de Google espera la clau (o un mecanisme oficial de sessió) al client. Un proxy genèric de tiles tampoc encaixa bé amb ToS/producte.

### 4.2 Instruccions que hauríem de donar al tenant (esborrany)

Text orientatiu per Settings / docs d’ajuda (cal adaptar dominis reals del producte):

1. Ves a [Google Cloud Console → APIs & Services → Library](https://console.cloud.google.com/google/maps-apis) i activa **Maps JavaScript API**.
2. Crea una API key **nova** (recomanat: no reutilitzar la de Geocoding del servidor).
3. **Application restrictions:** *HTTP referrers (web sites)*.
4. Afegeix exactament els referrers que et indiqui piMed, per exemple:
   - `https://<host-del-tenant-portal>/*`
   - `https://<host-del-tenant-portal>`
   - (si s’ofereix) `http://localhost:5173/*` només per entorns de prova autoritzats
5. **API restrictions:** restringeix a *Maps JavaScript API*.
6. Enganxa la clau a **Settings → Mapes → Maps JavaScript** (candidata → Provar → Activar).
7. Si el mapa surt en gris amb error de referrer: revisa que l’URL de la barra del navegador coincideix amb un patró de la llista (inclou `https` vs `http`, amb/sense `www`, path `/*`).

**Nota ops:** la plataforma ha de publicar la llista canònica de referrers (prod + staging). Si hi ha white-label, el formulari hauria de mostrar el/s host/s del tenant actiu perquè els copiïn a GCP.

---

## 5. Què vol dir “exposar una clau publicable”

### 5.1 Definició

Una clau **publicable** (o *browser key* / *client-side key*) és una API key pensada per **anar al navegador**: el JavaScript de l’app l’usa per carregar Maps JS. Qualsevol usuari tècnic pot veure-la a Network / codi font / DevTools.

No és “secreta” en el sentit de Vault write-only. La seguretat ve de:

1. **Restricció per HTTP referrer** (només el teu domini pot usar-la amb èxit).
2. **Restricció per API** (només Maps JavaScript, no Cloud Billing admin, etc.).
3. **Quotes i billing alerts** al projecte GCP del tenant.
4. (Opcional) rotació ràpida si es filtra i s’abusa des d’un origen mal configurat.

### 5.2 Contrast amb el model actual (write-only)

| | Clau Geocoding / Routes (avui) | Clau Maps JS (“publicable”) |
|--|--------------------------------|-----------------------------|
| On s’usa | Només Edge Function / servidor | Navegador de cada usuari |
| Es retorna al frontend? | **No** (disseny actual) | **Sí** (inevitable per Maps JS clàssic) |
| Protecció principal | No sortir mai del vault + restricció per API | Referrer + API + quota GCP |
| Risc si es filtra | Alt (crides server-side sense referrer) | Mitjà si el referrer està ben posat; alt si la clau és `None` / unrestricted |

**“Exposar una clau publicable”** al nostre producte significaria, en la pràctica:

1. Desar-la a Vault com la resta (encara xifrada en repòs).
2. Tenir un RPC/edge **autenticat** del tipus `get_maps_js_browser_key` que **sí retorna** la clau (o un fragment usable) als rols autoritzats del tenant.
3. El frontend la passa a `Loader({ apiKey })`.
4. Acceptar que deixa de ser “write-only” per a aquest `secret_type` concret — cal documentar-ho a Settings i a la política de seguretat (§8).

### 5.3 Variants més fines (per al pla futur)

- **Clau separada maps_js** (recomanat): Geocoding segueix write-only; només Maps JS és publicable.
- **Session / short-lived token:** si Google o un intermediari ho permeten al producte escollit, el servidor emet un token de curta vida en lloc de la clau crua (més complex; cal validar productes Google actuals).
- **Una sola clau GCP amb dues restriccions:** sovint inviable (server sense referrer vs browser amb referrer); millor **dues claus**.

---

## 6. Riscos i criteris “go / no-go”

| Risc | Mitigació |
|------|-----------|
| Cost per map load | Copy clar + BYOK (paga el tenant) + entitlement temporal; sense promises de “quota exacta per tenant” si la clau és compartida |
| `RefererNotAllowedMapError` | Diagnòstic i errors visibles a admin-portal (telemetria agregada), no heurística backend |
| Filtració de clau unrestricted | RBAC al endpoint + restricció per referrer a la key; endpoint mai serveix la key d’un altre tenant |
| Dual stack Leaflet + Google | Dual stack només com a migració; l’estat final ha de ser Maps JS only per mapa visual |
| ToS / caching | No cachejar tiles ni abusar d’APIs no contractades |

**Go** només si producte accepta: cost GCP per mapa, clau al browser, i suport a tenants amb restricció de referrer.

---

## 7. Prompt per generar un pla d’implementació (futur)

Copiar/enganxar a un agent o sessió de planificació quan es vulgui implementar:

```text
Context: SaaS multi-tenant. Decisió actual: el mapa visual només es mostra si el tenant té Maps JavaScript API BYOK (clau al navegador) o si té entitlement temporal de plataforma. Geocoding/Routes BYOK ja existeix via Edge Functions com a secrets write-only a Vault (geocoding_api_key, routes_api_key). Geocoding/Routes NO s’han d’exposar al browser.

Objectiu: escriure un pla d’implementació (markdown) per habilitar mapa visual amb Google Maps JavaScript API (BYOK per tenant i entitlement temporal de plataforma), mantenint intacte el model BYOK write-only de Geocoding/Routes, i definint l’estat “mapa no disponible” quan no hi ha key/entitlement.

Has de cobrir:
1. Decisió de producte: “Maps JS only per al mapa visual” (sense key/entitlement → mapa no disponible), i gating UX a Settings.
2. Nou secret_type maps_js_api_key (candidata → verify → activate), separat de geocoding/routes.
3. Seguretat: què vol dir clau “publicable”; endpoint autenticat per retornar-la al client; contrast amb write-only; prohibir reutilitzar la clau de Geocoding al browser.
4. Restricció HTTP referrer: llista de dominis del producte; white-label; localhost/staging; textos d’ajuda per al tenant; errors RefererNotAllowedMapError.
5. Frontend: loader oficial; `CoordinatePicker` (MVP) amb el model de click-to-pick i punt seleccionat; gating visual; i recàrrega completa després de canviar tenant quan Maps JS ja està carregada.
6. Verify: un únic preview (cost mínim acceptable), capturant errors `onError` i `gm_authFailure`/codes; dedup per tenant.
7. Cost/observabilitat: map loads i errors agregats aprox; sense promises de quota dura per tenant.
8. Migracions, RBAC (owner/manager pot activar; lectura per member/viewer si toca), i18n, i actualització de D1/README.
9. Criteris d’acceptació + riscos + ordre de fases (MVP primer a CoordinatePicker, després la resta).
10. Explicitar NO-objectius: no proxy de tiles; no reutilitzar geocoding/routes keys al browser; no heurístiques de referrer backend “false sense garantia”.

Sortida: un sol document de pla estructurat (resum, arquitectura, fluxos, schema, seguretat, fases, AC), alineat amb l’estil de docs/plans/maps-geocoding-byok/README.md i el doc futur docs/plans/maps-geocoding-byok/FUTURE-google-maps-js.md.
```

---

## 8. Referències

- Decisió D1 i abast MVP: [README.md](./README.md) §2, i la decisió d’“estan només mapa si maps_js BYOK/entitlement”.
- Shape geo compartit: [ADR-geo-coordinates.md](./ADR-geo-coordinates.md).
- Google Maps Platform – API keys / HTTP referrers: documentació oficial de Google Cloud (Maps JavaScript API).
- Prompt històric de producte/cost: `prompts/Google/maps.md` (parla de Maps JS al client; el MVP va triar BYOK server-side per Geocoding/Routes + OSM visual).
