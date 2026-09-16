# 05 — Forward-compat: contracte signat post-acceptació

> **Pla:** [`README.md`](./README.md)
> **Abast d'aquest document: NOMÉS disseny.** No s'obre cap epic d'implementació aquí (decisió QT-D6). L'objectiu és que les decisions preses a `01`-`04` no calgui reobrir-les quan s'implementi el contracte.

## 1. Per què no és un `commercial_documents`

`data.commercial_documents` (`doc_type IN ('quote','quote_amendment','delivery_note')`) és, per disseny (`commercial-flow/02-domain-model.md`), l'espina **comercial** del sistema: pressupost → ampliació → albarà, amb el seu propi cicle d'immutabilitat i numeració. Un **contracte** és un artefacte diferent: un document DMS generat i signat formalment, més proper al que ja fa `sign-document-router` per a documents de RRHH/legal.

**Decisió de disseny:** el contracte **no** afegeix un nou `doc_type` a `commercial_documents`. Es genera com a document del DMS (`data.documents`) via el motor de signatura ja existent.

## 2. Peces que ja existeixen i es reutilitzaran tal qual

| Peça | On | Rol en el contracte futur |
|------|-----|----------------------------|
| `data.document_templates` + `document_template_locales` | motor DMS | Nova categoria `category='contract'` (reservar el nom ara; **no sembrar contingut**) |
| `sign-document-router` (`action='sign'`\|`'generate_only'`\|`'sign_native'`) | `supabase/functions/sign-document-router/index.ts` | Orquestra la generació + firma del contracte |
| `data.signing_submissions` / `data.signing_events` | migració `20260522000001` | Cicle de vida de la firma del contracte |
| Firma nativa (`SignaturePad`, evidències IP/UA/geo) | `docs/plans/signing/plan-sistema-firma-propi.md` | Mecanisme de firma per a tenants sense DocuSeal |
| `_shared/automation/handlers/generate-document.ts` | motor d'automatització | Patró per disparar la generació automàticament en acceptar un pressupost |

**No cal inventar cap infraestructura nova de signatura.**

## 3. Per què el contracte de variables es dissenya genèric ara

El contracte de context definit a [`01-context-and-legal-content.md`](./01-context-and-legal-content.md) (`tenant`, `document`, `seller`, `buyer`, `lines`, `totals`, `legal`) **no conté cap paraula específica de "pressupost"**. Això és intencionat: quan s'implementi el contracte, les plantilles `category='contract'` podran consumir exactament els mateixos noms de camp, perquè les dades subjacents (client, línies de servei, imports) són les mateixes que ja té el pressupost acceptat.

## 4. Punts d'enganxament previstos (no crear ara)

- Columna futura `data.commercial_documents.contract_document_id uuid REFERENCES data.documents(id)`.
- Nou valor a `commercial_document_events.event_type`: `'contract_generated'` (el CHECK actual haurà d'ampliar-se quan arribi aquest epic).
- Trigger o automatització candidata: en inserir un event `accepted` sobre un `commercial_documents` amb `doc_type='quote'`, proposar (no executar automàticament sense confirmació humana, seguint el patró `propose_*` de la resta de l'aplicació) la generació del contracte amb `sign-document-router action='generate_only'` o `'sign_native'`.
- Categoria `category='contract'` a `document_templates`: **reservar el nom ara als comentaris de codi/documentació**, no crear encara plantilles ni migracions per a ella.

## 5. Què cal decidir quan s'obri aquest epic (fora d'abast ara)

- Si el contracte necessita firma qualificada (DocuSeal) o n'hi ha prou amb firma nativa segons el volum/import del pressupost.
- Si el contracte és obligatori per a tot pressupost acceptat o només configurable per tenant/sector.
- Com es referencia el pressupost original dins del contracte (número, hash de contingut `content_hash` ja existent a `commercial_documents`).
- Retenció i validesa legal del contracte generat (probablement més estricta que la del pressupost).

Aquestes preguntes **no es responen en aquest pla**; queden aquí perquè quan arribi el moment, l'epic corresponent no hagi de redescobrir per què el contracte de variables es va dissenyar genèric.

## 6. El contracte futur ja hereta un pipeline de firma provat

Amb QT-8/QT-9/QT-10 ([`06-phases-and-backlog.md`](./06-phases-and-backlog.md) § Fase 3, [`07-signing-integration.md`](./07-signing-integration.md)), els pressupostos i albarans passen a firmar-se amb el mateix motor natiu del DMS (`sign-document-router action=sign_native`, camps `<signature-field>`, Submission Hub). Això vol dir que quan s'obri l'epic del contracte, **no cal dissenyar cap flux de firma nou**: n'hi haurà prou amb afegir `category='contract'` i reutilitzar exactament el mateix pipeline ja demostrat amb pressupostos/albarans.

## 7. Nota: facturació fiscal futura (fora d'abast, no dissenyat)

`commercial-flow` ja deixa explícit que la **factura fiscal pròpia no es genera dins l'aplicació** (viu a l'ERP extern — Holded/Quipu, veure CF-17). Si en el futur es decideix generar factures pròpies, aquest pla ja ho deixa raonablement encaixat sense haver-ho dissenyat ara:

- Seguiria el mateix patró que el contracte (§1-3): no és un `commercial_documents` nou, sinó un document DMS separat generat a partir d'un albarà o pressupost ja tancat.
- El mateix contracte de variables (`tenant`/`document`/`seller`/`buyer`/`lines`/`totals`) ja té tot el que una factura necessita mostrar; només caldria una categoria `category='invoice'` de plantilla i, probablement, camps fiscals addicionals (sèrie, data de meritació) que avui no es dissenyen.
- **No s'obre cap epic ni es reserva cap nom de categoria per a això ara** — es documenta únicament perquè quan es plantegi, no calgui redescobrir que el contracte de variables ja ho suporta en un 90%.
