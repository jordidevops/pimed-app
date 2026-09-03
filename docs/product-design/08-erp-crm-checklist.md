# 8. Checklist contra ERP/CRM clàssics

> Repassem funcionalitats típiques d'ERP (Holded, Odoo, Sage, Holded,
> Quipu) i CRM (HubSpot, Pipedrive, Zoho) per identificar el que **ens
> podríem deixar al calaix sense voler**, i decidir conscientment què
> entra, què queda fora i què deleguem a integració.
>
> Aquest doc és la "última xarxa de seguretat" abans de tancar disseny.

## 8.0 Convencions

- ✅ **Inclòs a la base** (V1 / V1.5)
- 🟡 **Mòdul vertical posterior** (V2 / Fase D-E)
- 🔌 **Integració de tercer** (vegeu doc 06)
- ❌ **Fora d'abast** (no som això)

Quan apareixen els arquetips, fan referència als definits a
[03-sector-profiles.md](03-sector-profiles.md):
`field_service`, `practice`, `hospitality`, `lodging`, `workshop_maker`,
`appointment_walkin`, `generic`.

---

## 8.1 Bloc CRM

| Funcionalitat | Decisió | Comentari |
|---|---|---|
| Contactes amb camps personalitzats | ✅ V1 | `contact.metadata` validat per JSON Schema sectorial. |
| Empreses ↔ persones (jerarquia simple) | ✅ V1 | `employer_contact_id` i `primary_contact_id` (vegeu doc 02 §2.2). |
| Relacions N:M tipades | 🟡 V2 | `data.contact_relationships` només quan hi hagi cas real (vet, advocat, pediatre amb 2 tutors). |
| Pipeline de vendes (kanban) | 🟡 D | Reaprofitant `Projects` amb `type='lead'`/`status='quoted'`. |
| Activitats / timeline 360° per Contact | ✅ V1.5 | Vista que uneix events, communications, documents, project_lines. |
| Lead scoring | ❌ | No target (autònoms i micro-equips). Deixem-ho per HubSpot. |
| Email marketing massiu (campanyes) | 🔌 | Mailchimp/Brevo. Nosaltres som transaccional. |
| Formularis web embedables | 🟡 V2 | Tipus Calendly/Typeform light per `practice` i `appointment_walkin`. |
| Cerca avançada / segments | ✅ V1.5 | Tags + filtres + cerca semàntica (pgvector, vegeu doc 07 §7.7e). |
| Importació CSV/Excel | ✅ V1 | **Imprescindible**. Sense això un autònom no migra. |
| Exportació total / GDPR right to access | ✅ V1 | Obligatori legalment. |
| Detecció duplicats | ✅ V1.5 | Fuzzy + LLM (vegeu doc 07 §7.7d). |

---

## 8.2 Bloc Calendari / Agenda

| Funcionalitat | Decisió | Comentari |
|---|---|---|
| Esdeveniments amb recurrència | ✅ V1 | RFC 5545 (RRULE). |
| Esdeveniments multi-dia (rang) | ✅ V1.5 | Necessari per `lodging` (estades) i `workshop_maker` (instal·lacions). |
| Recordatoris multicanal | ✅ V1.5 | Email/SMS/WhatsApp via jobs (PGMQ). |
| Booking públic (slots horaris) | 🟡 D | Fase D, lligat a `practice` i `appointment_walkin`. |
| Booking públic multi-dia | 🟡 D-bis | `lodging` (V2). |
| Sincronització Google/Outlook | 🔌 | Tier 2. V1 pull only. |
| Gestió de capacitat (taules, boxes, habitacions) | ✅ V1 | `Asset.metadata.capacity` i bloqueig per rang. |
| No-show tracking | ✅ V1.5 | Estat de l'event + acció ràpida des del recordatori. |
| Bloqueig automàtic d'Asset durant esdeveniment | ✅ V1.5 | Crític per `lodging` (no doble booking). |
| Llista d'espera / overbooking gestionat | 🟡 D | `practice` amb cancel·lacions; `lodging` amb walk-in. |

---

## 8.3 Bloc Operacions

| Funcionalitat | Decisió | Comentari |
|---|---|---|
| Projects + Tasks | ✅ V1 | Ja fet. |
| Work Orders / Field Service | 🟡 D | Reaprofita Projects (`field_service`, `workshop_maker` a camp). |
| Time tracking (`work_logs`) | ✅ V1 | Ja previst. Pausable, geolocalitzat opcional. |
| Despeses + dietes per projecte | 🟡 D | `project_expenses` (D-INT-12 Opció A). Pla producte: [`docs/plans/expenses/`](../plans/expenses/). OCR via doc 06. |
| Catàleg de productes/serveis amb preus | ✅ B | `catalog_items` (V1 mínim, sense variants). |
| Pressupostos i comandes (línies de catàleg) | ✅ B | `Project` + `project_lines`, sense taules `quotes`/`orders` separades. |
| Estoc lleuger de producte acabat | 🟡 D | `catalog_items.stock_qty` simple, sense lots/ubicacions. |
| Materials consumits per projecte | 🟡 D | Via `project_lines.consumed=true` que decrementa stock. |
| Inventari complet (rotació, lots, sèries, multi-magatzem) | ❌ | Fora d'abast. Si cal: integració amb Holded/Odoo. |
| Comandes de compra a proveïdor | ❌ V1 | Possible V2 si demanda forta a `workshop_maker`. |
| Reserves d'estoc (allocació) | ❌ | Innecessari per al target. |
| Manteniment preventiu (PM) calendarized | 🟡 E | RRULE sobre Asset → CalendarEvents (`workshop_maker`, `lodging`). |
| Cua walk-in | 🟡 D | `appointment_walkin` (V2). Estat realtime. |
| Estat habitacions (lliure/ocupada/per netejar) | 🟡 D-bis | `lodging` (V2). Realtime. |

---

## 8.4 Bloc RRHH

| Funcionalitat | Decisió | Comentari |
|---|---|---|
| Empleats com a entitat separada de User | ✅ V1 | Vegeu doc 02 §2.3. |
| Contractes (DMS) | ✅ V1 | Documents polimòrfics amb `entity_type='employee'`. |
| Fitxatge horari | ✅ V1 | Reusem `work_logs` amb `kind='clock_in/out'`. |
| Torns / planificació setmanal | 🟡 D | Crític per `hospitality` i `lodging`. Vista calendari + assignació. |
| Vacances i absències | 🟡 D | Workflow simple aprovació, no engine de BPM. |
| Nòmines | 🔌 | Integració amb gestoria/A3/Sage/Holded payroll. |
| Onboarding/offboarding employee | 🟡 D | Checklist + DMS folders + revocació accessos. |
| Avaluacions / OKR | ❌ | No target. |
| Compliance laboral (ERTO, IT) | ❌ | Delegat a gestoria. |

---

## 8.5 Bloc Documental (DMS)

| Funcionalitat | Decisió | Comentari |
|---|---|---|
| DMS amb carpetes + ACL | ✅ | En curs (`documents_core`). |
| Versionat | ✅ | Ja al disseny. |
| Signatura electrònica | 🔌 | Signaturit/Docusign/Validated ID. Crític per `practice` i `workshop_maker`. |
| OCR | 🔌 | Mindee/Textract (vegeu doc 06 §6.2). |
| Tags + cerca text complet | ✅ V1.5 | pg_trgm + pgvector. |
| Plantilles de documents (mail merge) | 🟡 D | Pressupostos, consentiments, contractes. |
| Escaneig DNI/passaport per registre | 🟡 D-bis | `lodging` regulació hostatgeria. OCR + DMS sensible. |
| Compartició externa amb expiració | ✅ V1.5 | `share_links` ja previstos. |
| Portal client per consultar docs | 🟡 V2 | Magic link, vegeu doc 04 §4.13. |

---

## 8.6 Bloc Facturació / Diners

| Funcionalitat | Decisió | Comentari |
|---|---|---|
| Subscripcions del SaaS | ✅ V1 | Stripe (intern, Tier 1). |
| Pressupostos al final-client | ✅ B | Reusant `Project` + `project_lines`. PDF generat. |
| Factures al final-client | 🟡 E | Integració > propi. Si propi: mínim viable + delegació a Verifactu. |
| Cobrament online (link de pagament) | 🔌 V2 | Stripe Connect / Redsys / Bizum. |
| Comptabilitat doble partida | ❌ | Mai. Integració amb Holded/Quipu/Sage. |
| Conciliació bancària | ❌ | Mai. |
| Llibres oficials / SII / Verifactu / TicketBAI | 🔌 | **Crític a Espanya 2026+**, obligatori per certs trams. Delegar a 3r. |
| Multi-divisa | 🟡 V2 | Si arriba demanda B2B internacional. |
| Taxa turística | 🔌 V2.5 | Addon `tourist_tax` per `lodging`. |
| Notes de crèdit / abonaments | 🔌 | Via integració facturació. |

---

## 8.7 Bloc Comunicació

| Funcionalitat | Decisió | Comentari |
|---|---|---|
| Email transaccional | ✅ V1 | Resend + plantilles + BYOS. |
| Email màrqueting massiu | 🔌 | Mailchimp/Brevo. |
| SMS | 🔌 V1.5 | Twilio fallback recordatoris. |
| WhatsApp Business | 🔌 V1.5 | BSP (360dialog/Twilio). Vegeu doc 06 §6.4. |
| Centraleta / VoIP | ❌ | No és el nostre joc. |
| Helpdesk / tickets | 🟡 V2 | Si arriba demanda; abans no. |
| Inbox unificat per Contact | ✅ V1.5 | Vista, no taula nova. |
| Resposta automàtica IA a missatges | 🟡 V3 | Suggeriment, mai enviament autònom. |
| Plantilles per arquetip + i18n | ✅ V1 | Vegeu doc 03 §3.6. |

---

## 8.8 Bloc Analytics

| Funcionalitat | Decisió | Comentari |
|---|---|---|
| Dashboards per arquetip | ✅ V1 | Predefinits, no configurables (vegeu doc 07 §7.12 anti-patró). |
| KPIs operatius | ✅ V1.5 | No-show rate, cites/setmana, hores, occupancy (`lodging`), tickets/dia (`hospitality`). |
| Constructor de reports custom | ❌ V1 | Vistes SQL exposades als plans alts si cal. |
| BI extern (Metabase, Looker) | 🔌 | PostgREST / read replica per plans Enterprise. |
| Alertes proactives ("ahir vas tenir 3 no-shows") | 🟡 V2 | Generades per IA brief diari. |
| Comparativa amb mitjana del sector | 🟡 V3 | Privacy-preserving aggregation (anonim). Demanat sovint, fins ara no l'ha fet ningú bé. |

---

## 8.9 Bloc Govern / Compliance

| Funcionalitat | Decisió | Comentari |
|---|---|---|
| Audit logs | ✅ V1 | Ja en marxa. Vegeu protocol a `copilot-instructions.md`. |
| Backups i restore | ✅ V1.5 | Snapshot diari + restore self-service per al tenant (V2). |
| RGPD: consentiments, dret oblit, exportació | ✅ V1 | Bàsic obligatori. |
| 2FA per usuari | ✅ V1.5 | Supabase ja ho permet, exposar al UI. |
| Passkeys | 🟡 V2 | Tendència forta, baixa fricció. |
| SSO empresarial (SAML/OIDC) | ❌ V1 | No target. Possible V3 per Enterprise. |
| Roles d'admin de la startup | ✅ V1 | admin-portal. |
| DPA repository per integracions | ✅ V1.5 | Vegeu doc 06 §6.10. |
| Pista d'auditoria criptogràfica (hash chain) | 🟡 V3 | Si calgués per certificacions. |

---

## 8.10 Específic per arquetip — què mereix una columna pròpia

### `field_service`
| Funcionalitat | Decisió |
|---|---|
| Worklog amb geo + cronòmetre | ✅ V1 |
| Multi-stop diari (rutes optimitzades) | 🔌 V2 (Maps) |
| Pressupost ràpid des del lloc | ✅ B (project_lines + IA opcional) |
| Cobrament al lloc (link Bizum/Stripe) | 🔌 V2 |
| Signatura del client al mòbil (conformitat) | 🔌 V1.5 |

### `practice`
| Funcionalitat | Decisió |
|---|---|
| Expedient (records) | 🟡 D (`clinical`/`legal`/`coaching` declinable) |
| Recordatoris dobles (24h+2h) | ✅ V1.5 |
| Consentiments signats | 🔌 D |
| Receptes / prescripcions | 🟡 V3 (només si demanda mèdica) |
| Vinculació tutor↔menor / tutor↔animal | ✅ V1 (camps a Contact) |

### `hospitality`
| Funcionalitat | Decisió |
|---|---|
| Mapa de taules amb estat | 🟡 D |
| Reserva amb prepagament | 🔌 V2 (Stripe link) |
| No-show penalty (cobrament) | 🟡 V3 |
| Plats del dia / carta lleugera | ❌ V1 (POS extern és l'autoritat) |
| Llista d'espera walk-in | 🟡 D |

### `lodging` *(V2 — esborrany, vegeu doc 03 §3.6)*
| Funcionalitat | Decisió |
|---|---|
| Booking multi-dia amb bloqueig Asset | ✅ V1.5 (calendari) |
| Check-in / Check-out workflow | 🟡 D-bis |
| Estat habitació (clean/dirty/maintenance) | 🟡 D-bis (realtime) |
| Channel manager (Booking/Airbnb) | 🔌 V2.5 |
| Registre viatgers + escaneig DNI | 🟡 D-bis |
| Càlcul taxa turística | 🔌 V2.5 |
| Tarifes estacionals | 🟡 D-bis |
| Comunicació pre-arrival (instruccions, codi pany) | 🟡 D-bis |

### `workshop_maker`
| Funcionalitat | Decisió |
|---|---|
| Catàleg de producte propi amb SKU | ✅ B |
| Variants/configurador | 🟡 V2 (atributs a metadata; taula `catalog_variants` si demanda) |
| Fitxa tècnica i fotos del producte | ✅ B |
| Asset "venut" al client | 🟡 D (`assets.contact_site_id` ja existeix al DDL; UI d’alta d’equips pendent) |
| Manteniments preventius programats | 🟡 D (`maintenance_plans` + assignacions polimòrfiques; **no** RRULE a calendar_events) |
| Garanties amb data de fi | ✅ B (camp a assets) |
| Albarans de lliurament | 🟡 D (PDF d'un Project `type='delivery'`) |
| Treball mixt taller + camp en una mateixa comanda | ✅ V1 (Tasks amb `location_id` o `contact_site_id`) |
| Recanvis (B2B amb stock dedicat) | 🟡 V3 |

### `appointment_walkin` *(V2)*
| Funcionalitat | Decisió |
|---|---|
| Cua walk-in en realtime | 🟡 D |
| "Qui ha atès" visible al ticket | 🟡 D |
| Comissions per professional | 🟡 V3 |
| Foto del resultat (perruqueria, estètica) abans/després | ✅ V1 (DMS) |

---

## 8.11 El que típicament s'oblida i no oblidem

Llista d'elements que els ERP/CRM grans tenen (perquè han evolucionat 20
anys) i que els nous SaaS sovint obliden. Aquí els fixem com a part del
contracte amb l'usuari:

### Bàsics no negociables

- ✅ **Importació inicial des d'Excel/CSV**. Sense això un autònom no
  migra. V1 obligatori.
- ✅ **Soft delete + paperera amb retenció 30 dies**. La gent s'equivoca.
- ✅ **Undo** d'accions destructives (toast amb 30s).
- ✅ **Mode demo / dades d'exemple** activable per provar abans
  d'introduir res real.
- ✅ **Mode "pausa" del tenant** (vacances, baixa temporal) sense perdre
  dades ni cobrar.
- ✅ **Exportació total** abans de baixar-se de la subscripció
  (anti-lock-in com a feature de confiança, no com a protecció legal).

### Ergonomia del dia a dia

- ✅ **Multi-zona horària per usuari** (no només per tenant) —
  recepcionista a Canàries d'una clínica de Barcelona.
- ✅ **Multi-idioma a les plantilles de comunicació** (ja parcialment).
- ✅ **Notificacions priortitzades** (tres categories: crític, important,
  informatiu). Vegeu doc 07 §7.12.
- ✅ **Estat "draft offline"** per Contacts creats sense connexió.
- ✅ **Reorganitzar bottom nav** per usuari/rol (ítem fixat preferit).

### Robustesa

- ✅ **Idempotència universal** per operacions client (`client_op_id`).
- ✅ **Audit complet** de canvis de cicle de vida (vegeu copilot-instructions).
- ✅ **Health check públic** per status page.
- 🟡 **Status page pública** amb incidents (V1.5).
- 🟡 **Backups self-service**: restore d'un Contact / Project esborrat
  per error sense haver de cridar suport (V2).

### Comercial / suport

- ✅ **Mode "impersonate"** de l'admin-portal per debug (auditat).
- ✅ **Notes internes per tenant** des de l'admin-portal (no visibles).
- 🟡 **In-app messaging** (Intercom-light) per onboarding (V2).
- 🟡 **Changelog visible** dins del producte (V1.5).
- 🟡 **NPS / feedback in-app** trimestral (V2).

### Anti-lock-in (com a feature de confiança)

- ✅ **Esquema obert documentat**: el tenant pot consultar via SQL/API
  les seves dades reals, no només una vista cosmètica.
- ✅ **Exportació total a ZIP** (CSV per taula + DMS arxius).
- ✅ **Política de retenció clara** post-cancel·lació (90 dies, després
  esborrat hard).

---

## 8.12 El que **explícitament** queda fora

Cal dir-ho clar perquè ningú vingui a demanar-ho amb sorpresa:

- ❌ **Comptabilitat doble partida**.
- ❌ **MRP / planificació de producció**.
- ❌ **Inventari amb lots, sèries, multi-magatzem complet**.
- ❌ **Workflow engine configurable per usuari**.
- ❌ **Dashboard builder**.
- ❌ **Email màrqueting massiu / automation flows**.
- ❌ **Lead scoring / sales forecasting**.
- ❌ **Avaluacions de personal / OKR / 1:1s**.
- ❌ **Helpdesk amb SLA i escalats** (mòdul light V2 si demanda).
- ❌ **POS físic** (en l'autoritat del Square/Sumup/Verifone).
- ❌ **EAM/CMMS profund** (només manteniment preventiu lleuger).
- ❌ **PMS hoteler complet** (només els fonaments per `lodging` petit).
- ❌ **HIS / EMR mèdic regulat** (només expedient lleuger via `clinical` addon).

Per cada un d'aquests, la resposta és **integració amb el rei del
nínxol**, no implementació pròpia.

---

## 8.13 Decisions a tancar

1. **Quin nivell de "import wizard" V1?**: només CSV simple amb mapeig
   manual de columnes? *(Recomanació: sí, amb plantilla descarregable
   per arquetip + verticals top.)*
2. **Soft delete vs hard delete per defecte?**: tot soft amb paperera
   30d? *(Recomanació: sí, excepte audit_logs i comunicacions enviades.)*
3. **Política d'undo**: 30s als toasts, o sempre via paperera?
   *(Recomanació: ambdós; toast immediat + paperera per recuperació
   diferida.)*
4. **Mode "pausa" tenant**: cobrem reduit o no cobrem? *(Recomanació:
   plan "pause" 50% durant 3 mesos màxim, després data archive.)*
5. **Quan oferim "BYO Postgres"** (tenant porta el seu Postgres)? Mai V1.
   Possible Enterprise V3 si arriba demanda regulatòria.
6. **In-product changelog**: bloc del propi producte o pàgina externa?
   *(Recomanació: pàgina externa indexable + banner in-product per
   features rellevants.)*
