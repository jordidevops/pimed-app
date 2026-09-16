# 05 — Acceptació i gates

> **Pla:** [`README.md`](./README.md) · epics a [`04-phases-and-backlog.md`](./04-phases-and-backlog.md)

## Gate d'entrada

Aquest pla toca el mateix recorregut de camp que [Field Service](../field-service/README.md), que encara té la UAT Tier A pendent i offline parcial. Per no acumular deute:

- CF-0, CF-1 i CF-2 es poden fer en paral·lel, perquè milloren el que ja existeix;
- **CF-4 en endavant no s'obre** fins que el recorregut bàsic «crear, planificar, iniciar, tancar» estigui provat i acceptat.

## Acceptació del Tall 1

Un autònom, des del mòbil, sense formació i sense sortir de l'aplicació:

1. crea la feina amb client, adreça i **Visita estàndard**;
2. emet un pressupost i n'obtén acceptació signada, **o** captura la renúncia signada amb descripció de la feina;
3. treballa i registra hores, km i materials;
4. en tancar veu **només les desviacions**;
5. quan hi ha sobrecost, genera i fa signar l'**ampliació abans de cobrar-la**;
6. emet i signa l'albarà, que **mai supera l'import autoritzat**;
7. registra el cobrament sense duplicats ni dobles càrrecs;
8. envia el document per WhatsApp o correu sense configurar el portal.

### Criteris de fracàs

El Tall 1 **no és vàlid** si:

- en una urgència amb sobrecost cal sortir de la pantalla de tancament o passar per oficina;
- l'aplicació permet emetre un albarà valorat per sobre de l'import autoritzat a un consumidor;
- la pantalla d'acceptació dona més pes visual a Acceptar que a Refusar;
- un doble toc o un reintent duplica línies, documents o cobraments;
- un tècnic sense permís comercial pot canviar preu, descompte o impost;
- apareix qualsevol camp de cost a `api.project_lines` o `api.catalog_items`.

### Gate específic de simplicitat de l’OS

La primera reestructuració visual en tres fases **no es considera completada**: no havia passat l’acceptació funcional. L’estabilització tècnica posterior queda preparada per a UAT, però CF-2 continua ⚠️ fins a superar una prova observada sense explicar la interfície.

Perfils obligatoris:

- un autònom que prepara, executa i cobra la seva pròpia feina;
- una persona d’oficina o responsable d’una empresa de 2–10 tècnics.

Tasques observades: identificar què toca en obrir l’OS, preparar preus, pressupost o renúncia, iniciar o reprendre, tancar, trobar el Part de treball si el negoci l’utilitza, emetre l’albarà sense dependre del part i localitzar el saldo pendent.

Criteris:

- identifica la següent acció en menys de 5 segons en cada estat;
- completa el happy path sense ajuda i sense buscar una funció en més d’una fase;
- distingeix Part de treball d’Albarà en menys de 5 segons;
- entén que publicar el Part de treball és opcional i no bloqueja l’albarà ni el cobrament;
- després d’un refus entén que cal crear un pressupost nou;
- cap acció ni contingut queda ocult per barres;
- en acabar pot respondre què falta per cobrar mirant una sola pantalla.

Evidència tècnica disponible el 2026-09-14: matriu unitària de workflow verda, E2E dels casos `307df…` i `510000…` verd, i prova SQL de reemissió/idempotència/aïllament verda. Aquesta evidència **no substitueix** els dos recorreguts humans; cal registrar temps, dubtes, errors i punts d’abandonament.

### Gate CF-16 — Offline d'actuals

CF-16 sincronitza hores, km, materials i l'intent de tancament. El reconnect **no emet cap albarà**: «Emetre albarà» continua sent una acció manual i online després que el tancament consti al servidor.

Acceptació obligatòria:

- obrir una OS online, perdre xarxa, registrar km/materials, tancar i recarregar sense perdre l'estat;
- reconnectar i comprovar una sola aplicació de cada operació, inclosos reintents i dues pestanyes;
- conservar el tancament local amb checklist o media pendents i aplicar-lo només quan aquestes cues acabin;
- mostrar separadament `local_pending`, `action_required` i tancament sincronitzat;
- impedir el tancament offline quan IndexedDB no sigui durable;
- verificar bloqueig de checklist, bypass només manager i overage de consumidor;
- assertar que no s'ha creat cap `delivery_note` durant la sincronització.

La cobertura automàtica no substitueix una UAT offline real en mòbil; fins llavors CF-16 queda ⚠️.

### Comprovacions tècniques

| Prova | Criteri |
|-------|---------|
| Numeració concurrent | Cap número duplicat amb emissions simultànies |
| Immutabilitat | Cap escriptura possible sobre un document emès |
| `authorized_total` | Coherent després d'acceptar, refusar i anul·lar, dins la mateixa transacció |
| Bloqueig legal | Emissió rebutjada per sobre de l'autoritzat amb `is_consumer = true` |
| Avís B2B | Emissió permesa amb motiu registrat quan `is_consumer = false` |
| Idempotència | Aplicar plantilla, emetre i cobrar dues vegades amb el mateix `client_op_id` no duplica |
| Aïllament | Cap document visible entre tenants |
| Retenció | Cap esborrat físic de documents comercials |

## Gate Tall 1 → Tall 2

| Ítem | Requisit |
|------|----------|
| Acceptació del Tall 1 | Provada amb un tenant real de camp |
| Tests SQL | Verds i a `supabase/tests` |
| Evidència | Un cas complet amb sobrecost, ampliació signada i cobrament |
| Documentació | [`STATUS.md`](./STATUS.md) actualitzat amb el que s'ha fet i el que ha quedat parcial |

## Acceptació del Tall 2

1. Un tècnic registra actuals i proposa un extra; l'oficina l'aprova abans de cobrar-lo. **(CF-13)** — cobert: llindar `commercial.deviation_approval_threshold_eur`, `commercial.pricing.edit`, proposar vs acceptar, RPC `office_approval_required` / `pending_amendment_blocks_delivery`.
2. Es troba qualsevol pressupost per client, número o text de línia en menys de deu segons. **(CF-15)** — cobert: `/quotes` + `search_commercial_documents`; crear (tria OS + emissió) i duplicar (reemissió de terminals) des de la secció.
3. La fitxa del client mostra l'estat comercial sense obrir cada document. **(CF-14)** — cobert: resum a Contacte + tab Pressupostos amb estat i acció pendent.
4. Una feina es tanca sense connexió i s'emet correctament en recuperar-la, sense duplicats.
5. Un cobrament parcial deixa saldo pendent correcte. **(CF-17)** — cobert: cap a `record_payment`, bestretes, `payment_link` amb referència; Stripe i Holded API 📦.
6. El PDF de marca es genera amb la plantilla del tenant i queda desat al DMS. **(CF-18)** — cobert: HTML del snapshot + Gotenberg/cua + `rendered_document_id`; TAP prova l’enllaç DMS, no la conversió; signatura formal 📦.

## Gate Tall 2 → Tall 3

| Ítem | Requisit |
|------|----------|
| Qualitat de dades | Hores, materials, km i despeses registrats de manera fiable a feines reals |
| Materials | Cost i preu de venda separats i realment omplerts |
| Despeses | Model ampliat amb `is_billable` i `paid_by` |
| Permisos | Permís financer definit i provat |

Sense aquestes quatre condicions, la rendibilitat del Tall 3 donaria xifres falses, cosa pitjor que no donar-ne cap.

## Acceptació del Tall 3

1. Es pot veure el resultat brut estimat i real d'una feina, mai anomenat «benefici net».
2. Cap usuari sense permís financer accedeix a costos ni marges, comprovat a la base de dades.
3. Els costos històrics no canvien quan es modifiquen sous o preus de catàleg.
4. Un contracte de manteniment distingeix el que està inclòs del que és extra autoritzable.
5. Una obra registra bestreta, fites i ordres de canvi signades, amb seguiment de contractat, executat i facturat.
