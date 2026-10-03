# Fase 6 — Fitxes amb ruta, badges i render de factura

> **Ordre:** 6 · **Depèn de:** 1A, 1B, 2, 4 · **Recomanat:** 3, 5  
> **Índex:** [`README.md`](./README.md)

## Objectiu

Cada albarà i cada factura tenen URL canònica compartible. Estats etiquetats. Una sola CTA de cobrament per context. PDF/Enviar de factura operatiu.

## Rutes de detall

- [x] `/sales/delivery-notes/:id` — pàgina pròpia (no overlay a `/delivery-notes`).
- [x] `/sales/invoices/:id` — pàgina pròpia.
- [x] Redirect `?view=<id>` → `/sales/…/:id`.
- [x] Enllaços creuats: DN → factura; factura → cada DN (+ OS).
- [ ] Overlay `CommercialDocumentView` només context OS/client; oficina «Obrir fitxa» → ruta.

## Capçalera albarà

Badges **etiquetats** (mai un sol «Pendent» ambigu):

| Dimensió | Valors UI |
|----------|-----------|
| Conformitat / document | Pendent de signatura, Signat, … |
| Facturació | Per facturar, En esborrany, Facturat (enllaç), Rectificat |
| Cobrament | Pendent de cobrar, Parcial, Cobrat |

Accions:

- [ ] Enviar, Signar, Rectificar (oficina / permís)
- [ ] **Cobrar** només si no hi ha link factura actiu
- [ ] Si facturat: enllaç a factura (no Cobrar DN)

## Capçalera factura

- [ ] Número, sèrie, data, client, exercici
- [ ] Document + cobrament + revisió + export (etiquetes)
- [ ] Línies amb traça a DN/línia origen
- [ ] Llista DN/OS enllaçats
- [ ] Desglossament cobraments: bestreta | DN previ | via factura
- [x] Accions: Cobrar factura, PDF (`renderCommercialDocumentPdf`), Anul·lar (si permès); Enviar / ref. externa manual parcial
- [ ] Gestoria: Revisar / Demanar canvis / veure lots (sense Cobrar/Anul·lar)

## Regla d’una sola CTA de cobrament

| Context | Acció primària |
|---------|----------------|
| DN sense factura | Cobrar albarà |
| DN amb factura activa | Anar a factura |
| Fitxa factura issued amb remaining > 0 | Cobrar factura |
| Llista | Menú fila; no dos botons Cobrar alhora |

## Render PDF

- [ ] Categoria plantilla `invoice` (com quote/DN)
- [ ] HTML fallback `buildCommercialDocumentHtml` labels factura
- [ ] Context edge `render-commercial-document` + smoke test
- [ ] No exposar PDF/Enviar fins smoke verd

## i18n

- [ ] Claus ca/es/en per tots els estats i ajudes de modal/fitxa.

## Proves

- [ ] Deep link fitxa funciona amb usuari oficina i gestoria (read).
- [ ] Badge «Pendent» sol no apareix sense dimensió.
- [ ] Smoke render invoice.
- [ ] TS: una sola CTA segons estat.

## DoD

- [x] Fitxes compartibles en producció local (rutes + badges etiquetats + cobrament/anul·lar factura).
- [x] Enllaços DN↔factura bidireccionals.
- [x] Checklist actualitzat (PDF invoice via edge existent; smoke UAT encara operatiu).