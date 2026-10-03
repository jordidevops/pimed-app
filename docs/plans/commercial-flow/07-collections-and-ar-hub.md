# 07 — Hub d'Albarans (CF-26)

> **Pla:** [`README.md`](./README.md) · backlog [`04-phases-and-backlog.md`](./04-phases-and-backlog.md) · execució [`EXECUTION.md`](./EXECUTION.md) · estat [`STATUS.md`](./STATUS.md)
> **Estat (2026-10-03):** implementació tècnica del hub + 11 forats. Types regenerats amb CF-27. **UAT navegador pendent.**
> **Evolució producte:** el hub Comercial viu a `/sales` — pla tancat [`09-sales-comercial/`](./09-sales-comercial/README.md) (CF-27). Aquest 07 queda com a històric/spec CF-26 (albarans).

## Estat: fet / pendent

### Fet (codi al repo)

| Àmbit | Què |
|-------|-----|
| Hub | `/delivery-notes` (oficina), redirect `/cobraments`, alias nav `cobraments` → `delivery_notes` |
| Superfícies | Llista global; pestanya client; OS → Entregar (embedded) + resum de compte |
| Emissió progressiva | `commercial_issue_source_lines`; protect delivered; preview d’emissió |
| Saldos FIFO | `data.delivery_balances`; `issued_at` amb `clock_timestamp()` als DN |
| Resum OS | `get_project_delivery_summary` també mostra bestreta **sense** DN actiu |
| Llistat | `list_delivery_notes_page` acota balances als `project_id` candidats (abans del filtre/LIMIT) |
| Factura externa | `external_invoices` 1..N DN mateix client; cobrament a factura |
| Rectificació | `rectify_delivery_note(..., p_line_patches)`; preview només lectura; UI única `RectifyDeliveryNoteDialog` |
| Permisos UI | `isOffice` només factura / cobrar factura / rectificar; Cobrar DN + Signar al camp |
| CTA camp | `collect_invoice` només oficina; camp: «Pendent a factura — oficina» sense enllaç al hub |
| Comprovant | saldos via `get_delivery_note_collection_detail` |
| Legacy | preflight `list_delivery_note_legacy_conflicts`; remediació **manual** `remediate_legacy_duplicate_delivery_notes` |
| Gate backfill | `000005` fa `RAISE` si `invoice_ref_cross_client` |
| Proves | SQL `cf26_hub_fixes_tests.sql`, `rectify_delivery_note_tests.sql`; TS `collect_invoice` / camp no navega |
| Migracions | `20261216000001`…`000008` |

### Desviació documentada (vs pla de correcció)

El pla de fix demanava `RAISE` també amb `multiple_active_delivery_notes` al backfill. **No s’aplica:** després de CF-26 els DN progressius múltiples són legítims i bloquejarien resets/push amb dades reals. El preflight + remediació manual cobreixen els **clones** legacy.

### Pendent (respecte a aquest tall / pla Albarans)

| Ítem | Notes |
|------|-------|
| UAT navegador | ✅ 2026-10-03: camp cobrar DN+comprovant; oficina facturar (`F-2026-0019`) + Rectificar (preview/bloqueig sobrant); fix draft sense línies (`000010`) |
| Regenerar `database.types.ts` | ✅ fet amb CF-27 |
| Prova SQL explícita del `RAISE` cross-client a `000005` | Cobert per lògica a la migració; falta assert dedicat al suite |
| **CF-25-b** | Períodes d’acord al hub — [`07b`](./07b-albara-out-of-scope.md) |
| Compositor de quantitats en emetre DN **nou** | V2 — [`07b`](./07b-albara-out-of-scope.md) |
| Factura fiscal (Verifactu), Holded/Quipu API | Fora d’abast — [`07b`](./07b-albara-out-of-scope.md) |
| Crèdit post-rectify | Fora d’abast — [`07b`](./07b-albara-out-of-scope.md) |

### Següent pla (substitueix l’evolució del hub)

**CF-27 — Comercial `/sales`:** ✅ tancat — factures natives, ledger d’allocations, sèries/exercicis, gestoria, export ZIP. Detall: [`09-sales-comercial/`](./09-sales-comercial/README.md) · [`LOG`](./09-sales-comercial/IMPLEMENTATION-LOG.md).

---

## Per què existeix

El punt de control de facturació i cobrament és l'albarà, no l'ordre. Una ordre pot tenir diversos albarans progressius. La factura fiscal es fa fora de PiMed i agrupa un o més albarans del mateix client.

| Superfície | Rol |
|------------|-----|
| `/delivery-notes` | Oficina: tots els albarans i les factures externes |
| Pestanya Albarans del client | La mateixa llista, filtrada pel client |
| OS → Entregar | Llista filtrada per l'ordre + resum; Cobrar DN i Signar al camp |
| `/quotes` | Només pressupostos i ampliacions |

`/cobraments` redirigeix a `/delivery-notes` i conserva la consulta de l'URL. Un menú desat amb l'id `cobraments` es llegeix com a `delivery_notes`. El hub global és només oficina (`isOffice`).

## Qui pot fer què

| Acció | Camp (OS) | Oficina |
|-------|-----------|---------|
| Emitir / Signar albarà | Sí | Sí |
| Cobrar DN **no** facturat | Sí | Sí |
| Registrar factura / Cobrar factura | No | Sí |
| Rectificar | No (diàleg compartit a llista/panell) | Sí |
| Obrir `/delivery-notes` | No (redirigeix a home) | Sí |

Si el pendent està només a DN facturats: oficina veu CTA `collect_invoice` → hub amb `surface=invoices`. El camp veu «Pendent a factura — oficina» sense enllaç al hub.

## Emissió progressiva

El pendent d'una línia és la quantitat de l'ordre menys la suma de les quantitats ja posades en albarans actius (`issued`, `signed`, `accepted`) amb el mateix `source_project_line_id`. Emetre un albarà només fotografia aquest pendent. No es trien quantitats al modal.

No es pot esborrar una línia ja albaranada ni baixar-ne la quantitat per sota del ja entregat (`project_line_already_delivered`). Es poden afegir línies o apujar quantitats.

`issued_at` d'un albarà usa `clock_timestamp()` perquè dos DN a la mateixa transacció no empatin al FIFO.

## Saldos

Els saldos es calculen en llegir (`data.delivery_balances`), sense llibre d'imputacions.

- Les bestretes d'un pressupost o ampliació acceptats s'apliquen al primer albarà actiu, i el sobrant al següent. L'ordre és `COALESCE(issued_at, created_at), id`.
- Sense albarà actiu, `get_project_delivery_summary` encara mostra el pool de bestreta (i `unapplied` = pool); cobrat/pendent = 0.
- Amb albarans, el pool ve de `delivery_balances` (no es recalcula amb una segona fórmula).
- El llistat del hub acota `delivery_balances` als `project_id` candidats **abans** del filtre de cobrament i del `LIMIT`.
- Es cobra l'albarà mentre no estigui facturat. Després, Cobrar viu a la factura i es reparteix entre els seus albarans, del més antic al més nou.

## Rectificació

Flux en una TX: cancel·lar → aplicar `p_line_patches` (quantitat OS; mínim = ja entregat en altres DN actius) → emetre substitut amb `supersedes_id`.

- UI: un sol diàleg (`RectifyDeliveryNoteDialog`) amb preview de lectura (`preview_rectify_delivery_note`) — no escriu.
- Els cobraments es queden a l'original i compten al substitut. Si la suma heretada supera el total nou → `rectify_payments_exceed_total`.
- No es poden afegir ni esborrar línies via rectify; només patches de quantitats de línies que ja eren al DN.

## Factura externa i legacy

PiMed no emet factura fiscal. `data.external_invoices` guarda número, data, total i, si cal, un PDF. Uneix 1..N albarans del mateix client. El número és únic per empresa.

En **reset** (migració `000005`), el backfill fa `RAISE` si hi ha `invoice_ref_cross_client` (el número és únic per tenant). Els albarans progressius múltiples són vàlids i no bloquegen el backfill.

Ops: `list_delivery_note_legacy_conflicts` + `remediate_legacy_duplicate_delivery_notes` (dry-run per defecte) cancel·la **clones** antics només quan les línies coincideixen amb el DN més recent. Si hi ha dubte, no tocar.

## Què veu el client (comprovant)

- Albarà sense factura: total, bestreta aplicada, cobrat i pendent (o «Pagat»). Font: `get_delivery_note_collection_detail` (no la pàgina sencera).
- Albarà facturat: «Inclòs a la factura F-…». El pendent és de la factura.
- Albarà rectificat: «Substituït per A-…» i no es reenvia.
- El PDF emès no porta saldos.

## Fora d'aquest tall

Resum d’una línia: factura fiscal (Verifactu), triar quantitats en emetre (V2), llibre persistent d’imputacions, saldos a favor després de rectificar, permís nou de facturació, períodes d’acord (CF-25-b) i API de Holded o Quipu.

**Explicació de cada punt** (què vol dir, què fa PiMed ara, per què queda fora): [`07b-albara-out-of-scope.md`](./07b-albara-out-of-scope.md).
