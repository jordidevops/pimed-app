# Flux comercial — Pla mestre d'execució

> **Rol:** única font de veritat de l'ordre d'implementació i del treball pendent
> **Creat:** 2026-09-10
> **Pla:** [`README.md`](./README.md) · estat per epic: [`STATUS.md`](./STATUS.md)
> **Fase activa:** *Cap epic obert.* **CF-18** tancat tècnicament (PDF de marca; signatura formal 📦). Següent: gate Tall 2 → Tall 3.
> **Anterior:** **CF-18** PDF de marca — veure [`STATUS.md`](./STATUS.md)
> **Deute:** Gate Tall 1 → Tall 2 (UAT observada) diferit; CF-16 UAT offline real pendent; Stripe i connector Holded/Quipu diferits; signatura formal de documents comercials diferida; conversió Gotenberg no es prova al TAP

## Disciplina

1. Llegir aquest fitxer i [`STATUS.md`](./STATUS.md) a l'inici de cada conversa d'implementació.
2. Treballar **només** la fase activa, o un ítem de backlog acordat explícitament.
3. En tancar un epic: marcar-lo a STATUS, afegir línia al changelog i avançar la fase activa aquí.
4. Mentre no hi hagi producció, **preferir editar la migració font** abans d'afegir fixups additius.
5. Cap epic es dona per fet sense la comprovació corresponent de [`05-acceptance-and-gates.md`](./05-acceptance-and-gates.md).
6. Si una decisió de [`README.md`](./README.md) § «Decisions tancades» s'ha de reobrir, es documenta abans de tocar codi.

## Ordre real

| Ordre | Epic | Estat | Nota |
|------:|------|-------|------|
| 1 | **CF-0** Vocabulari i unitats | ✅ | |
| 2 | **CF-1** Guardrails de dades | ✅ | |
| 3 | **CF-2** Línies al mòbil / UX OS | ⚠️ | Estabilització tècnica verda; UAT humana pendent |
| 4 | **CF-3** Servei habitual | ✅ | Apply + CRUD Catàleg |
| 4b | **CF-23** Servei + checklist | ✅ | Bridge + apply + default a crear OS |
| — | *Gate: recorregut bàsic de camp provat* | ⚠️ | Avançat per petició explícita |
| 5 | **CF-4** Documents comercials base | ⚠️ | Schema + RPCs + panell mínim |
| 6 | **CF-5** Pressupost | ⚠️ | Mode client Veure; falta signatura dit |
| 7 | **CF-6** Renúncia al pressupost | ✅ | QuoteWaiverDialog |
| 8 | **CF-7** Import autoritzat | ✅ | UX close-out |
| 9 | **CF-8** Revisió de desviacions | ✅ | CloseOutDeviationsCard |
| 10 | **CF-9** Ampliació de pressupost | ✅ | CTA tancament |
| 11 | **CF-10** Albarà | ⚠️ | Emissió; falta signatura |
| 12 | **CF-11** Compartició i PDF simple | ✅ | Print/HTML + share sheet |
| 13 | **CF-12** Cobrament simple | ✅ | Diàleg + comprovant |
| — | *Gate Tall 1 → Tall 2* | ⚠️ | Deute UAT (autònom + oficina); diferit |
| 14 | **CF-13** Separació tècnic i oficina | ✅ | Llindar + RPC + UI proposar/aprovar |
| 15 | **CF-14** Historial al client | ✅ | Resum Contacte + tab Pressupostos |
| 16 | **CF-15** Secció Pressupostos | ✅ | `/quotes` + cerca + crear/duplicar |
| 17 | **CF-16** Offline d'actuals | ⚠️ | Implementat; UAT offline real pendent |
| 18 | **CF-17** Cobraments avançats | ✅ | Parcials/saldo; Stripe i Holded API 📦 |
| 19 | **CF-18** Render amb plantilles | ✅ | PDF de marca via camí propi; signatura formal 📦 |
| — | *Gate Tall 2 → Tall 3* | ❌ | Qualitat de dades d'execució |
| 20 | **CF-19** Costos privats | ❌ | |
| 21 | **CF-20** Rendibilitat | ❌ | |
| 22 | **CF-21** Manteniment contractual | ❌ | |
| 23 | **CF-22** Obra i instal·lació | ❌ | |

---

## Fase tancada: CF-15 Secció Pressupostos

Fet: RPC `search_commercial_documents`, pàgina `/quotes`, entrada al sidebar, filtres (tipus/estat/dates/caducitat/import), Veure/Enviar, **crear** (tria d’ordre oberta + `issue_commercial_document`) i **duplicar** (reemissió via `reissue_commercial_quote` per terminals). Prova SQL a `supabase/tests/commercial_flow_cf15_search_quotes_tests.sql`.

## Fase tancada tècnicament: CF-16 Offline d'actuals

Implementació completada: ledger immutable i RPCs idempotents, outbox Dexie amb dependències i recuperació de crash, snapshots per rehidratar l'OS, actuals/materials optimistes, coordinador multi-cua i tancament local amb `local_pending` / `action_required` / sincronitzat.

«Emissió diferida» és la sincronització d'actuals i tancament. **No crea cap albarà**; l'usuari l'emet manualment online quan el projecte ja consta tancat al servidor.

CF-16 es manté ⚠️ fins superar la UAT offline real definida a `05-acceptance-and-gates.md`. S'obre CF-17 per petició explícita, com el gate Tall 1 → CF-13.

## Fase tancada: CF-17 Cobraments avançats

Fet: cap de sobrecobrament a `record_payment`, `FOR UPDATE` per projecte, bestretes sobre pressupost acceptat, `payment_link` amb referència, camp text `external_invoice_ref`. Proves SQL a `supabase/tests/commercial_flow_cf17_partial_payments_tests.sql` i unitàries de saldo/CTA.

**Fora d'abast (📦):** Stripe Checkout/webhooks/Connect, connector API Holded/Quipu.

## Fase tancada: CF-18 PDF de marca

Fet: `document_template_id` / `rendered_document_id`, RPC `link_commercial_rendered_document` (membre de camp), HTML de marca des del snapshot (locale + logo), edge `render-commercial-document` (Gotenberg síncron o cua service_role), UI de vista/share amb PDF online, pendent, HTML de recanvi i enllaç DMS.

**Fora d'abast (📦):** signatura formal, DOCX, enllaç públic, wizard `DocumentOrchestrator`. TAP SQL no converteix HTML a PDF.

---

## Registre de treball

Cada epic tancat afegeix aquí una entrada amb data, abast real i desviacions respecte del pla.

| Data | Epic | Què s'ha fet | Què ha quedat pendent |
|------|------|--------------|-----------------------|
| 2026-09-10 | CF-0 | km, chips, Esborrany, Imports | — |
| 2026-09-10 | CF-1 | Migració CHECK, client_op_id, permís pricing | Regenerar types TS |
| 2026-09-10 | CF-2 | Targetes mòbils | — |
| 2026-09-10 | CF-3 | Apply + CRUD «Serveis habituals» al Catàleg | — |
| 2026-09-10 | CF-4…CF-5 | Schema + apply + panell | Signatura dit |
| 2026-09-10 | CF-6 | QuoteWaiverDialog | Signatura amb el dit |
| 2026-09-10 | CF-7…CF-9 | Desviacions + ampliació al close-out | — |
| 2026-09-10 | CF-11 | Vista mode client, print/HTML, WhatsApp/correu/native/QR, RPC `sent` | Enllaç públic token (Tall 2) |
| 2026-09-10 | CF-12 | CollectPaymentDialog + PaymentReceiptSheet | Parcials avançats / Stripe (CF-17) |
| 2026-09-14 | CF-2 primera reestructuració | OS en 3 fases + CTA peu + estat final + xip pendent | No va passar l’acceptació funcional |
| 2026-09-14 | CF-2 estabilització UX | Workflow monotònic, tabs canònics, CTA sense overlay, reemissió i Entregar ordenat; unitàries/E2E/SQL verdes | Gate observat amb usuaris reals |
| 2026-09-14 | CF-23 | `pricing_template_checklists` + apply + default create | — |
| 2026-09-14 | Gate Tall 1 | — | UAT diferida; s’obre Tall 2 amb CF-13 |
| 2026-09-14 | CF-13 | Llindar, RPC office gate, proposar/aprovar UI, i18n | UAT Tall 1 segueix deute |
| 2026-09-14 | CF-14 | Resum comercial a fitxa client + tab Pressupostos | Cerca global `/quotes` (CF-15) |
| 2026-09-14 | CF-15 | `/quotes`, RPC cerca, filtres, Veure/Enviar | Crear/duplicar des de la secció |
| 2026-09-14 | CF-15 deute | Crear (picker OS) + duplicar (reemissió) a `/quotes` | — |
| 2026-09-15 | CF-16 | Ledger/RPC idempotent, outbox i coordinador multi-cua, snapshots, actuals/materials i tancament local honest | UAT offline real en mòbil |
| 2026-09-15 | CF-16 P2 | Transients retryables, stop tenant-scoped, material sense worklog fallit, CTA synced honest, checklist sense bucle, materials locals al close-out | UAT offline real en mòbil |
| 2026-09-16 | CF-17 | Cobrament parcial honest, cap de saldo, bestretes, ref. factura text | Stripe / connector ERP 📦 |
| 2026-09-16 | CF-18 | HTML de marca + edge Gotenberg/DMS + enllaç RPC (membre) + UI PDF/pendent | Signatura formal 📦; TAP sense conversió PDF |
| 2026-09-16 | Follow-up | Carpetes client a `/documents`, dates al pressupost, Activitat OS via events, Descartar, avís de preus, «Cobrat» només amb pagaments | — |
| 2026-09-16 | Follow-up | PDF comercial no esborrable al DMS; enllaç de tornada al pressupost i a l’OT | — |
