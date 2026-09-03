# Lodging — Hotels / B&B / càmping (estudi d’adopció)

> **Estat:** estudi aparcat (2026-07). No hi ha implementació en curs.
> Arquetip `lodging` = **V2 / Fase D-bis** al disseny de producte; **no seedat** ni seleccionable a l’onboarding.

Aquest document resumeix què necessiten hotels petits, B&B / cases rurals i càmpings per **decidir-se a utilitzar l’app**, contrastat amb el que ja tenim i el que queda al calaix. Mateix esperit que els gap docs de [QSR](QSR%20-%20Quick%20Service%20Restaurant..md) i [FSR](FSR%20-%20Full%20Service%20Restaurant.md).

**Fonts canòniques:** [03-sector-profiles.md](../03-sector-profiles.md), [08-erp-crm-checklist.md](../08-erp-crm-checklist.md), [05-modules-roadmap.md](../05-modules-roadmap.md), [04-roles-and-permissions.md](../04-roles-and-permissions.md), [06-integracions.md](../06-integracions.md), [07-mobile-and-ai-leverage.md](../07-mobile-and-ai-leverage.md).

**Abast explícit del producte:** fonaments per allotjament *petit* — **no** un PMS hoteler complet ([08](../08-erp-crm-checklist.md)).

**Verticals previstos** (doc 03): `bnb_small`, `rural_house`, `small_hotel`, `campsite` (+ alberg, apartaments turístics, coliving curt al catàleg).

---

## Quan dirien que NO

Per ordre de gravetat (compartit pels tres verticals):

1. **No hi ha estades multi-dia amb bloqueig d’unitat** — sense disponibilitat per rang de dies i sense “no doble booking”, no hi ha producte lodging.
2. **No hi ha check-in / check-out** — el ritual diari de recepció no existeix a l’app.
3. **No hi ha registre de viatgers / DNI** — a ES/EU és obligació d’hostaleria; sense això l’eina no substitueix el flux legal.
4. **No hi ha estat d’unitat + neteja entre estades** — especialment bloquejant per hotel petit; B&B i càmping ho noten menys el primer dia.
5. **No hi ha channel manager** — bloqueja hotels (i B&B) amb >~50 % de reserves via Booking/Airbnb; menys crític si venen sobretot directe.
6. **No hi ha taxa turística** — important a molts municipis; pot ser addon posterior si el nucli operatiu ja funciona.

## Quan dirien que SÍ (avui, amb honestedat)

Només si el dolor principal és **RRHH / control horari / torns del personal** (recepció, neteja) i accepten portar reserves, check-in, OTA i registre de viatgers **fora** de PiMed (Excel, Booking extranet, WhatsApp, PMS extern). És un “sí” feble: l’app encara no és un producte lodging.

---

## 1. Lodging ≠ hospitality

`hospitality` (V1) = F&B / esdeveniments amb **rotació per hores** (taules). Hotels i allotjaments multi-dia van a `lodging` ([03](../03-sector-profiles.md)).

| Tret | Hospitality (F&B) | Lodging |
|------|-------------------|---------|
| Rotació del recurs | Hores (taules) | **Dies** (habitació / parcel·la) |
| Event clau | Reserva horària | **Estada** (rang start–end) |
| Neteja | Bloc opcional | **Primera classe** entre estades |
| Documentació client | Lleugera | **DNI / passaport** |
| Canals externs | TheFork / TPV | **OTA** (Booking, Airbnb…) |
| Fiscal específic | — | **Taxa turística** |

> **Drift conegut:** [01-vision](../01-vision-and-positioning.md) i el seed DB de `hospitality` encara mencionen hotels/allotjaments; cal alinear-los amb doc 03 quan es reobri el tema.

---

## 2. Matriu d’adopció per vertical

Criteri: **Must** = sense això no adopten; **Should** = decideixen més fàcil / retenen; **Later** = addon o fase posterior; **Out** = no prometre.

| Capacitat | B&B / casa rural | Hotel petit | Càmping | Estat avui |
|-----------|------------------|-------------|---------|------------|
| Inventari d’unitats (habitació / parcel·la) com a Asset amb capacitat + tarifa nit | Must | Must | Must (parcel·les + tipologies) | Schema Assets genèric; sense UI lodging ni `nightly_rate` |
| Disponibilitat multi-dia + no doble booking (bloqueig Asset) | Must | Must | Must | Calendar genèric; bloqueig multi-dia dissenyat, no productitzat lodging |
| Flux check-in / check-out | Must | Must | Must | ❌ |
| Estat unitat (lliure / ocupada / per netejar / manteniment) | Should | Must | Should | ❌ (D-bis) |
| `cleaning_block` automàtic entre estades | Should | Must | Should | ❌ |
| Hostes (Contact) + preferències | Must | Must | Must | ✅ Contacts (labels via recepta) |
| Registre viatgers + escaneig DNI → DMS | Must (ES/EU) | Must | Must | ❌ (D-bis); DMS sí existeix |
| Comms pre-arrival (instruccions, codi pany) | Must | Should | Should | Email/templates parcial; flux lodging ❌ |
| Torns / RRHH (recepció, neteja) | Should | Must | Must (temporada) | ✅ Employees + Attendance |
| Tarifes estacionals / tipologies | Should | Must | Must (parcela, bungalow, caravana) | ❌ |
| Taxa turística | Should | Must (molts municipis) | Must | ❌ addon V2.5 |
| Channel manager (Booking/Airbnb) | Should → Must si volum OTA alt | Must | Should | ❌ addon V2.5 |
| Portal / reserva pública multi-dia | Should | Should | Should | ❌ |
| Folio / facturació hoste | Later | Later | Later | Diferit |
| PMS complet (grups, overbooking avançat, yield) | Out | Out | Out | ❌ per disseny |

### Lectura per negoci

- **B&B / casa rural:** adopten amb un **MVP estret** — unitats + estades + check-in/out + DNI + pre-arrival. Channel manager i taxa poden esperar si el volum OTA és baix.
- **Hotel petit:** no adopten sense **estat d’habitacions + housekeeping + RRHH/torns**; channel manager i taxa pugen a Must ràpid.
- **Càmping:** mateix nucli lodging, però inventari per **tipologia de parcel·la** (capacitat, serveis) i temporada; housekeeping menys “habitació a habitació”, més zones/serveis.

---

## 3. Mòduls de la plataforma: rol en lodging

### Ja útils (abaixen cost; no suficients sols)

| Mòdul | Rol lodging |
|-------|-------------|
| Contacts | Hostes / CRM lleuger |
| Calendar | Substrat de reserves multi-dia |
| Locations (+ schema Assets) | Propietat → plantes/zones → unitats |
| Employees + Attendance | Recepció, neteja, torns |
| DMS / Signing | Escanejos DNI, consentiments |
| Catalog | Tarifes nit + extres (patró seed) |
| Public portal / leads | Consultes web (no reserva confirmada) |
| Email / reminders | Pre-arrival / post-stay (infra) |

### Recepta lodging (disseny, no codi) — [03 §3.6](../03-sector-profiles.md)

- Labels: Contact = **Hoste**, Project = **Estada**, Event = **Reserva** (rang de dies).
- Sites: una propietat. Locations: plantes / edificis / zones.
- Assets = habitacions / parcel·les / apartaments amb `capacity` i `nightly_rate_cents`.
- Contact metadata: `id_document`, `nationality?`, `birthdate?`, `preferences?`, `vip?`.
- Addons: calendar (booking multi-dia), reminders, dms, employees, shifts; V2.5: `channel_manager`, `tourist_tax`.
- Event types: `stay`, `cleaning_block`, `maintenance_block`, `staff_shift`.
- Bundles: `reception`, `housekeeping`, `maintenance`, `lodging_admin` ([04](../04-roles-and-permissions.md)).
- Templates: confirmació, pre-arrival, check-in, post-stay (review), no-show.

### Bloc nou imprescindible (Fase D-bis)

El que fa que diguin “sí” al cicle operatiu diari:

1. **Booking multi-dia** sobre Calendar + bloqueig Asset.
2. **Check-in / check-out** (incl. FAB mòbil a [07](../07-mobile-and-ai-leverage.md)).
3. **Room/plot status** realtime + tasques housekeeping.
4. **Registre viatgers** (OCR DNI → Contact + DMS sensible).
5. **Comms pre-arrival** (plantilles lodging).
6. **Recepta + verticals** seed: `bnb_small`, `rural_house`, `small_hotel`, `campsite`.

### Addons que tanquen la venda (especialment hotel)

- `channel_manager` via Hostaway / Lodgify / Smoobu ([06](../06-integracions.md)).
- `tourist_tax`.
- Tarifes estacionals (producte D-bis, no només addon).

---

## 4. Criteri de decisió del client (resum)

Un allotjament petit **es decideix** quan pot fer el cicle diari sense Excel / WhatsApp paral·lel:

1. Veure qui arriba / marxa avui.
2. No sobrebookejar unitats.
3. Fer check-in amb documentació legal.
4. Marcar unitat “per netejar” i tancar neteja.
5. (Hotel / càmping) Quadrar personal per torns.
6. (Si venen per OTA) No haver de picar reserves a dos llocs → channel manager.

RRHH, contacts, DMS i calendar genèric **abaixen el cost** d’arribar-hi, però **no substitueixen** el nucli 1–4.

---

## 5. Ordre de construcció suggerit (si es reobre)

| Fase | Què | Valor |
|------|-----|-------|
| **A** | Recepta `lodging` + Assets unitat (`capacity`, tarifa) + estades multi-dia amb bloqueig | Demo creïble B&B |
| **B** | Check-in / check-out + registre viatgers (DNI → DMS) + plantilles pre-arrival | Substitueix el ritual legal/operatiu |
| **C** | Estat unitat realtime + `cleaning_block` + bundle housekeeping | Hotel petit adoptable |
| **D** | Tarifes estacionals + taxa turística (`tourist_tax`) | Fit fiscal / temporada |
| **E** | Channel manager (`channel_manager`) | Tanca venda si OTA és el canal principal |

Reutilitza Calendar + Assets + DMS + Employees; el codi nou és sobretot **booking multi-dia**, **bloqueig d’Asset per rang** i els fluxos CIO / housekeeping / registre ([05 §14b](../05-modules-roadmap.md)).

---

## 6. Què no prometre

- PMS hoteler complet (grups, yield, overbooking avançat).
- Folio / facturació hoste com a mòdul propi (diferit; facturació externa o mínim més endavant).
- POS / carta F&B (autoritat externa, com a hospitality).
- Inventari d’amenities pesat.

---

## 7. Pendents documentals (quan es reobri)

- Alinear [01-vision](../01-vision-and-positioning.md) i seed `hospitality` (treure hotels/allotjaments del text F&B).
- Seed / onboarding card per `lodging` (avui només 5 arquetips V1).
- Sense seed demo lodging (contrasta amb BurgerVista QSR).
