# 05 — Contracte post-acceptació (substituït)

> **Pla original:** [`README.md`](./README.md) · epics QT [`06-phases-and-backlog.md`](./06-phases-and-backlog.md)
> **Estat 2026-09-27 (CT-0):** el disseny transaccional d’aquest document **està substituït**. Implementar [`../commercial-agreements/pla-pressupost-contracte-acords.md`](../commercial-agreements/pla-pressupost-contracte-acords.md) (prefix **CT-**). **No reobrir QT.**

QT-D6 (2026-09-16) deixava aquí només disseny: un PDF DMS `category='contract'` després d’acceptar un pressupost, columna `commercial_documents.contract_document_id`, event `contract_generated`, i una automatització en l’event `accepted`. Això **no s’ha d’implementar**.

## 1. Què mana ara

Dos fluxos, triats pel tenant i per encàrrec (`formalization_mode`):

| Flux | Què és el «contracte» | Què no fer |
|------|------------------------|------------|
| `signed_quote` | El pressupost emès i acceptat/signat (`client_accept`). Mateix snapshot, una firma. | No crear cap fila d’acord en acceptar |
| `separate_agreement` | `data.commercial_agreements` (`kind='specific'` a V1) + versió immutable + segona firma. El pressupost acceptat és **annex** (`doc_number` + `content_hash` + PDF). | No enviar-lo sol en `accepted`; l’oficina confirma «Preparar contracte» |

Detall de taules, RPCs, UI, proves, fora d’abast i continuació (CF-21 / CF-22): el pla CT.

## 2. Prohibit (antic QT-D6)

- `commercial_documents.contract_document_id` com a únic enllaç al PDF de contracte.
- Nou `doc_type` `contract` a `commercial_documents`.
- Trigger o job que, en `accepted`, generi un PDF amb clàusules que el client no ha tornat a firmar.
- Categoria DMS `category='contract'` per a aquest acord (xoca amb contractes laborals). La plantilla V1 és `category='commercial_agreement'`.
- Rols `client_accept` / `client_reject` al PDF de l’acord. L’acord firma amb `client` (i `issuer` opcional).
- Tocar `buildCommercialDocumentHtml` o ampliar els tokens congelats de [`01-context-and-legal-content.md`](./01-context-and-legal-content.md) §2.1. L’acord té context i validació propis.

## 3. El que d’aquest doc encara és vàlid

- El context Liquid de pressupost (`tenant` / `document` / `seller` / `buyer` / `lines` / `totals`) es va dissenyar genèric (QT-D8). L’acord el **reutilitza com a dades del snapshot acceptat**, més un bloc `agreement` / `source_quote`. No es reobre §2.1.
- La firma és el motor natiu ja provat amb pressupostos (QT-9/10): `sign-document-router action=sign_native`. No s’inventa un motor nou.
- **Factura fiscal pròpia segueix fora** (CF-17: ERP extern). Un acord no crea `factura` ni un cron de facturació fiscal. Si algun dia hi ha PDF de factura, serà un epic apart (`category='invoice'`), no aquest.

## 4. Glossari (no barrejar)

| Terme | Què és |
|-------|--------|
| **Pressupost acceptat** | `commercial_documents` `quote` en estat acceptat. En `signed_quote`, és el contracte de l’encàrrec. |
| **Acord comercial** | `commercial_agreements`. Només quan hi ha contracte formal separat o, més endavant, vigència/marc/obra. |
| **Règim `contractual`** | `projects.commercial_regime`: B2B / menys bloquejos de consum. **No** vol dir que existeixi un acord. |
| **Contracte laboral** | `employment_contracts` / DMS de RRHH. Fora d’aquest epic. |
| **Pla de manteniment** | Genera OS. No és l’acord comercial (inclosos, preu, caducitat). Això és CF-21, després del nucli CT. |
