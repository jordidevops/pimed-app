# 7. Mobile-first i palanca IA

> Aquests dos eixos són els que diferencien el producte d'un ERP/CRM clàssic.
> No són capa cosmètica: condicionen el model de dades, el fluxe de
> permisos i fins i tot la tria d'integracions (vegeu doc 06).

---

## 7.1 Per què mobile-first és literal, no eslògan

L'usuari objectiu (autònom, micro-equip de 3-15) treballa **fora del
seient**:

| Arquetip | On és la majoria del temps |
|---|---|
| `field_service` | Cotxe + obra del client. El portàtil només existeix els diumenges al vespre. |
| `practice` | Entre boxes i recepció. Mans ocupades, bata, guants. Veu i dictat són l'única captura realista. |
| `hospitality` | Sala/cuina. Mòbil de butxaca o tablet a mostrador. Sorollós, gestos ràpids. |
| `lodging` | Recepció + recorreguts a habitacions. Sovint un sol mòbil compartit per torn. |
| `workshop_maker` | Taller (sorollós, brut) + visites a casa del client. Mòbil amb funda dura. |
| `appointment_walkin` | Mostrador + atendre. Tablet o mòbil ràpid entre clients. |

**Conclusió**: si una funció no funciona bé al mòbil amb una mà i amb
brutícia/guants/sorroll a sobre, no funciona. Punt.

---

## 7.2 Estratègia de plataforma

### V1: PWA installable (no nativa)

Raons:
1. **Time-to-market** — sense app stores, sense releases coordinats.
2. **Una sola codebase** — React + Vite ja en marxa.
3. **Push notifications via Web Push** funcionen a Android i (des d'iOS
   16.4) també a iOS si l'usuari l'ha "afegit a la pantalla d'inici".
4. **Càmera** via `<input type="file" capture>` i geolocalització
   estàndard cobreixen el 90% dels casos.

### Quan saltarem a Capacitor / nativa (V2)

Triggers concrets, no "potser":

- Necessitat de **background sync agressiu** (ex: subir N fotos quan
  torna el wifi sense tenir l'app oberta).
- Necessitat de **lectura de NFC/Bluetooth** (etiquetes d'actius al
  taller, polseres d'hoste a `lodging`).
- **Notificacions push fiables a iOS** sense passar per "afegir a
  pantalla d'inici" — quan l'app store és necessari per l'usuari final.
- **Integració amb perifèrics** (bàscula, escàner codi barres BLE,
  impressora tèrmica de tickets a `hospitality`).

Mentre cap d'aquests trigger no es dispari, **PWA**.

### Stack PWA recomanat

- `vite-plugin-pwa` (Workbox per dins).
- **Service Worker** amb estratègies clares:
  - `network-first` per dades dinàmiques (api.* GET).
  - `stale-while-revalidate` per recursos UI.
  - `cache-first` per assets versionats.
- **App shell** carregada un cop, navegació SPA.
- Manifest amb icones adaptatives + `display: standalone`.

---

## 7.3 Offline-first lleuger (no dur)

### Què sí ha d'anar offline V1

- **Veure l'agenda del dia** (lectura).
- **Crear una nota o adjuntar foto** a un Project / Contact / Task.
- **Iniciar/aturar un work_log** (timestamp local + sync després).
- **Marcar una tasca com a feta** (idempotent per `client_op_id`).

### Què no ha d'anar offline (V1)

- Crear un Contact nou des de zero (depèn de validació de schema sectorial,
  duplicats…). **Excepció**: form simplificat amb sols nom+telèfon, marcat
  com a "draft offline", sincronitza al tornar.
- Pressupostos, facturació, pagaments.
- Qualsevol cosa que requereixi RLS contextual complex.

### Patró de sincronització

- Cua local a **IndexedDB** (Dexie.js) amb operacions tipades:
  ```ts
  type LocalOp = {
    id: string;             // client_op_id (UUID v7 per ordenació)
    tenant_id: string;
    kind: 'note.create' | 'photo.upload' | 'worklog.start' | 'worklog.stop' | 'task.complete';
    payload: jsonb;
    created_at: string;
    attempts: number;
    last_error?: string;
  }
  ```
- En tornar online: drainer envia operacions en ordre, el servidor les
  fa **idempotents per `client_op_id`** (taula `data.client_ops_dedup`).
- Conflictes minimitzats perquè les operacions són additives (notes,
  fotos, worklogs). No fem edicions concurrents offline.
- Si una operació falla 5 cops → quarantine + notificació in-app.

---

## 7.4 UX patterns mòbil acordats

### Layout

- **Vista "Today"** com a home: agenda d'avui + 3-5 alertes prioritàries
  + acció primària sectorial (FAB).
- **Bottom nav** amb 4-5 icones màxim. Mai 6+. Si calen més, viuen al
  drawer "Més".
- **Header sticky minimal** amb context tenant/site i acció secundària
  (cerca o notificacions).

### Components base

- **Drawer (Vaul)** en lloc de modals — gestos naturals al mòbil.
- **Sheet bottom-up** per accions ràpides (assignar, etiquetar, comentar).
- **Llistes amb swipe**: dreta = positiu (fet, confirmat), esquerra =
  destructiu/secundari (snooze, esborrar amb confirm).
- **FAB contextual**: l'acció primària canvia segons l'arquetip (vegeu
  §7.5).
- **Tabs verticals** o pestanyes scrollables per evitar overflow.
- **Skeletons** per percepció de velocitat, no spinners.

### Toques i mida

- Targets ≥ 48×48 dp.
- Tipografia mínima 16px llegible amb llum solar.
- **Mode alt contrast** (toggle a settings) — útil a la sala (`hospitality`)
  i exterior (`field_service`).

### Accessibilitat com a base

- Contrast WCAG AA mínim.
- Suport screen reader (rols ARIA correctes als nostres components).
- Targets focusables i ordre de tab raonable per a tablet amb teclat
  (recepció `lodging`/`appointment_walkin`).

---

## 7.5 FAB primari per arquetip (suggeriment)

| Arquetip | FAB Today | Per què |
|---|---|---|
| `field_service` | "Iniciar visita" → obre worklog amb cronòmetre i geo | És el 80% del seu mòbil |
| `practice` | "Següent pacient" → obre fitxa + dictat ràpid | Pas natural entre cites |
| `hospitality` | "Nova reserva" o "Marcar taula" segons rol | Acció més freqüent del cambrer/host |
| `lodging` | "Check-in / Check-out" segons hora | Pas crític del torn |
| `workshop_maker` | "Nova ordre" o "Iniciar tasca" segons departament | Depèn del bundle del usuari |
| `appointment_walkin` | "Nou walk-in" | Cua entrant |
| `generic` | "Nova nota" | Sense supòsits |

---

## 7.6 Capacitats natives via PWA — què sí podem

| Capacitat | API web | Limitacions |
|---|---|---|
| Geolocalització | `navigator.geolocation` | Funciona bé. Acuracy variable indoor. |
| Càmera (foto/vídeo) | `<input type="file" capture>` | Sense control fi (zoom, flash). Suficient V1. |
| Push notifications | Web Push + Service Worker | iOS només si "Add to Home Screen". |
| Vibració | `navigator.vibrate` | Bé a Android, no iOS. |
| Compartir | `navigator.share` | Suport ampli. Útil per "envia confirmació". |
| Storage | IndexedDB (Dexie) | 50MB+ disponibles, suficient. |
| Background sync | `sync` event SW | Limitat a iOS. Drainer al primer foreground basta. |

### Què deixem per Capacitor (V2)

- NFC, BLE, accés a perifèrics USB.
- Càmera amb control complet (escàner barcode/QR amb ML Kit).
- Push fiables a iOS sense fricció d'instal·lació.
- Lectors d'empremta / Face ID per re-auth ràpida.

---

## 7.7 Palanca IA — on aporta valor real (no marketing)

Tots els casos passen per `ai-gateway` (vegeu doc 06 §6.5). Mai crida directa
al provider des del frontend.

### a) Captura sense teclejar (la palanca més gran)

| Cas | Tècnica | Arquetips |
|---|---|---|
| Dictat de notes/anamnesi post-cita | Whisper + LLM resum | `practice` (clau), `field_service` |
| Foto targeta de visita / DNI → Contact | OCR (Mindee) + LLM normalització | Tots, especialment `lodging` (registre viatgers) |
| Foto ticket/factura → Expense | OCR + classificació | `field_service`, `workshop_maker`, `hospitality` |
| Foto albarà → línies de catàleg | OCR + matching catàleg | `workshop_maker` (entrades estoc) |
| Foto pissarra/llibreta → tasques | OCR + LLM split | `field_service` (notes d'obra) |

### b) Redacció assistida

- "Escriu un recordatori amistós a en Joan per la cita de dimecres" → genera
  esborrany en el to del tenant (configurable: formal / proper / breu).
- Resposta a ressenyes de Google/Tripadvisor (V2, `hospitality` i `lodging`).
- Pressupostos en llenguatge natural ("3 hores oficial 1a + canviar
  diferencial 40A 30mA + petit material") → línies de `project_lines` amb
  `catalog_item_id` quan hi ha match.

### c) Resum i context 360°

- Capçalera del Contact: "12 visites en 2 anys, última fa 3 mesos per dolor
  cervical, té cita dimarts, paga al dia." Generat **bajo demanda** i
  cacheat fins al següent canvi del Contact.
- "Brief del dia" matinal: agenda + alertes + 2 propostes (ex: "Dimecres
  tens un forat de 90 min que pots usar per tornar la trucada a la Maria").

### d) Classificació automàtica

- Tag automàtic de Contacts per històric ("recurrent", "vip", "morós",
  "només estiu") amb explicabilitat (per què s'ha posat).
- **Detecció de duplicats** en crear/importar Contact (telèfon, email,
  nom+adreça). Fuzzy matching + LLM com a desempat.
- Suggerència de tasques derivades d'un correu rebut o nota de veu.

### e) Cerca semàntica + RAG

- "Mostra'm pacients amb al·lèrgia a penicil·lina i visita pendent" →
  embeddings sobre `Contact.metadata` + filtre estructurat.
- "Quina és la garantia que vam donar al client X de la persiana?" → RAG
  sobre Documents del Contact.
- Stack: **pgvector** dins el mateix Postgres (sense vector DB extern V1).

### f) Onboarding intel·ligent

- Pas 1 del wizard (vegeu doc 03 §3.7): "Què fas?" → matching contra
  `verticals.keywords` + LLM per descripcions lliures atípiques
  ("Reparo i venc patinets elèctrics" → suggereix `workshop_maker` amb
  vertical custom + addons proposats).
- LLM **proposa, mai imposa**. L'usuari sempre confirma.

### g) "Make it useful" — micro-IA al detall

Casos petits que no semblen IA però la fan servir:

- Auto-completar adreça a partir de codi postal + nom carrer parcial.
- Suggerir hora de cita en funció de patró del Contact ("normalment ve
  divendres a les 18h").
- Detectar telèfon/email vàlid en text lliure i oferir crear Contact.
- Resumir últims 3 missatges de WhatsApp del Contact en un bullet abans
  de respondre.

---

## 7.8 IA — patró tècnic comú

```
Component UI  →  hook useAI(taskKind, input)  →  Edge Function  →  ai-gateway
                                                                    ├─ PII filter (si addon clínic)
                                                                    ├─ choose model (per taskKind + plan)
                                                                    ├─ cache lookup
                                                                    ├─ call provider
                                                                    ├─ log usage_metrics
                                                                    └─ audit ai_invocations
```

### `taskKind` enumerat (no prompts ad-hoc al frontend)

```
'voice.transcribe' | 'voice.summarize' |
'ocr.business_card' | 'ocr.id_doc' | 'ocr.invoice' | 'ocr.receipt' |
'text.draft_message' | 'text.draft_quote' | 'text.summarize_contact' |
'tag.classify_contact' | 'tag.detect_duplicates' |
'search.semantic' |
'onboarding.suggest_archetype'
```

Així:
- **Prompts viuen al servidor**, versionats.
- **Cost i temps acotats** per taskKind.
- **Fallback gracejós**: si l'IA falla, la UI degrada a flux manual sense
  trencar.

---

## 7.9 IA — política de dades i seguretat

- **PII filter obligatori** per `practice` amb addon clínic abans de
  qualsevol crida a provider extern (vegeu doc 06 §6.5).
- **Opt-in explícit** per usar IA en arquetips no-clínics; default = on
  per features de productivitat (resum, dictat) i off per features que
  envien dades de Contact a tercers (classificació massiva).
- **Sense entrenament amb dades del client**: contracte amb provider
  (OpenAI ZDR, Anthropic, etc.) i clàusula al ToS del tenant.
- **DPA per provider IA** disponible al panell d'integracions.
- **Logs d'IA** sense payload sensible (només mètriques): tokens, model,
  cost, taskKind, èxit/error.
- **Right to be forgotten**: esborrar Contact també esborra embeddings
  derivats i caches d'IA.

---

## 7.10 Realtime — què sí, què no

Supabase Realtime és barat de canalitzar però car d'usar bé.

**Sí en V1**:
- Agenda compartida (`hospitality`, `practice`, `lodging`) — nous events
  apareixen en directe.
- Cua walk-in (`appointment_walkin`).
- Estat de taules ocupades (`hospitality`).
- Estat habitacions (`lodging`: lliure / ocupada / per netejar).

**No en V1**:
- Col·laboració en temps real estil Google Docs (no és el target).
- Indicadors "està escrivint" a comunicacions (no aporta).
- Live cursors / multiplayer al CRM (overkill).

---

## 7.11 Tendències que aprofitem (resum tàctic)

| Tendència | Com l'aprofitem | Quan |
|---|---|---|
| Edge Functions / serverless | Tota la lògica async i webhooks | Ja |
| Supabase Realtime | Agenda i estat compartit | Fase B-C |
| pgvector + RAG | Cerca semàntica i context 360° | Fase D |
| Web Push + PWA | Notificacions sense store | V1 |
| Passwordless (magic link, passkeys) | Auth modern, especialment portal client | V2 |
| LLM com a router de UI | Microcomandaments ("nova cita demà 10h Joan") | V2-V3 |
| Idempotència via `client_op_id` | Sync offline robusta | V1 |

---

## 7.12 Anti-patrons que evitem (i per què)

| Anti-patró | Per què no |
|---|---|
| **Chatbot generalista** dins el producte | Sense context, l'usuari no troba res que ja no faci el menú. Frustració alta. |
| **Workflow builder visual** ("Quan X, fes Y") | El target no l'usaria; complexitat de manteniment desproporcionada. Si cal, Zapier/Make. |
| **Drag-and-drop kanban per defecte arreu** | Sobrevalorat. Mòbil ho fa malament. Sectors com `practice` o `lodging` no l'aprofiten. |
| **Dashboards amb 20 widgets configurables** | Decideix tu pel sector. Configuració no és producte. |
| **Notificacions in-app sense priorització** | Soroll. Tres categories: crític (bloca), important (banner), informatiu (silent badge). |
| **IA com a feature de marketing** sense mètrica de valor | Si no podem mesurar "cops salvats" o "minuts estalviats", no l'enviem. |
| **Configurar tot via JSON al UI** | Cada toggle nou és deute tècnic. Defecte sòlid > flexibilitat infinita. |
| **App nativa abans de necessitat real** | Multiplica costos sense ROI clar fins arribar als triggers de §7.2. |

---

## 7.13 Mètriques de salut mòbil + IA

Per saber si això funciona realment:

| Mètrica | Objectiu V1 |
|---|---|
| % sessions des de mòbil | ≥ 70% (excepte rols admin) |
| TTI (time-to-interactive) sobre 4G | < 3s |
| Operacions completades offline → sync | ≥ 95% sense conflicte |
| Adopció de dictat (% notes per veu sobre teclades) | ≥ 30% per `practice` als 3 mesos |
| Adopció OCR (% expenses creats per foto) | ≥ 50% per `field_service`/`workshop_maker` als 3 mesos |
| Cost mig IA per tenant actiu | < 1€/mes als plans bàsics |
| % notificacions push obertes | ≥ 25% (si baixa, repensar priorització) |

---

## 7.14 Decisions a tancar

1. **PWA-only V1, Capacitor V2** confirmat? (Recomanació: sí, però
   monitoritzar triggers de §7.2 a partir del 6è mes.)
2. **Dexie + IndexedDB** com a base offline? (Alternativa: solucions
   tipus Replicache/RxDB; massa complexitat per V1.)
3. **`pgvector` dins el mateix Postgres vs vector DB extern**: V1 pgvector,
   migrar només si latència de cerca degrada amb >10M embeddings/tenant.
4. **Provider Whisper**: OpenAI cloud V1, opció de Whisper.cpp self-hosted
   per `practice` Enterprise (privacitat).
5. **Política push**: opt-in granulat (recordatoris personals, alertes
   d'equip, comunicacions de Contact) en lloc d'un sol toggle.
6. **\"AI rate-limit fairness\"**: que un tenant que abusa no degradi
   latència dels altres. Cua per tenant + prioritat per pla.
