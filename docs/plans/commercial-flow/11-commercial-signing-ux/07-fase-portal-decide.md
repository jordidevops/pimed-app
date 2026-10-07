# Fase 7 — Customer portal: pendents i decisió

> **Milestone portal:** CP-Db  
> **Prerequisits:** fases 2, 4 i 6  
> **Principi:** la sessió portal substitueix el bearer token, no el domini de decisió

## Objectiu

El client amb grant viu veu «Pendents de resposta» i accepta/refusa dins del portal. La mateixa request continua disponible per l'enllaç extern; first-wins garanteix un sol resultat.

## 7.1 Dashboard

Afegir a `apps/customer-portal`:

- comptador «Pendents de resposta»;
- targetes ordenades per `expires_at`, després created/id;
- tipus, número, tenant, total si visible, venciment;
- CTA «Revisar i respondre»;
- avisos «Caduca aviat» sense job de reminder V1.

El recompte ve de la projecció server-side; no descarrega tots els documents.

## 7.2 Autorització

Per obrir/decidir:

1. sessió BFF vàlida;
2. grant live per tenant + compte;
3. tenant/entitlement/toggle efectius;
4. request `open`;
5. `request.client_account_contact_id` = compte del grant;
6. target encara vàlid.

### Principal nominatiu

- nom/email venen del principal resolt;
- el client confirma càrrec/representació si aplica;
- no pot sobreescriure la identitat principal amb una altra persona.

### Bústia compartida

- pot veure els documents del compte;
- per decidir exigeix nom i cognoms + càrrec de la persona que actua;
- l'evidència conserva principal `shared_mailbox` i actor declarat;
- copy clar «Estàs actuant en nom de {compte}».

No afegir rols client a `tenant_members`.

## 7.3 UI de decisió

Reutilitzar el component de presentació de fase 4:

- mateix snapshot i PDF;
- mateix copy per tipus;
- mateixa accessibilitat;
- sense token a URL.

### Acceptar nativa

- checkbox d'autoritat;
- `SignaturePad`;
- POST al BFF;
- BFF → Edge amb credential interna;
- Edge resol request + principal i inicia/completa sessió nativa server-side;
- apply via request;
- justificant al portal.

### Refusar

- confirmació + motiu opcional;
- sense pad;
- apply `declined`;
- justificant/outcome visible.

### DocuSeal

*(F8 tall 3 — 2026-10-07)*

- request provider DocuSeal → portal CTA «Continuar a DocuSeal» (`provider_continue_available`);
- BFF `continue_docuseal` → edge `bridge_docuseal_pending_decision` → URL només a sessió grant (CS-D59);
- retorn al portal amb polling acotat fins webhook;
- refús portal sense pad també amb provider DocuSeal;
- no simular acceptació local.

## 7.4 Superfície Edge

Ampliar `resolve-customer-portal-commercial` o crear endpoint dedicat:

```text
list_pending_decisions
get_pending_decision
accept_pending_decision
decline_pending_decision
```

Body del browser no és autoritat per:

- tenant/account/principal;
- target/hash/import/provider;
- actor email nominatiu.

`client_op_id` es minta al BFF/servidor i es conserva per retry.

Rate limit per sessió/principal/request.

## 7.5 Carreres i frescor

Casos obligatoris:

- portal accepta mentre link refusa;
- oficina revoca mentre portal és obert;
- target superseded mentre el formulari és obert;
- dues pestanyes portal;
- submit retry després de timeout.

Resposta:

- apply retorna outcome real;
- UI no mostra «èxit acceptat» si va guanyar decline/revoke;
- invalidar summary, list i detail;
- polling només mentre request open.

## 7.6 Notificacions

Outcome des del portal:

- notifica tenant com qualsevol altra via;
- opcionalment envia còpia/justificant al principal;
- no envia email duplicat si apply ja estava resolt;
- operation log amb principal/grant/request id, sense signature image.

## Fitxers

- `apps/customer-portal/app/dashboard/page.tsx`
- components/nav/locales del customer portal
- `apps/customer-portal/lib/resolver.ts`
- BFF routes comercials noves
- `resolve-customer-portal-commercial`
- shared snapshot/decision UI si és reutilitzable sense acoblar apps
- settings/toggles de fase 6

## Proves

### Seguretat

- named principal no pot actuar com un altre;
- shared mailbox exigeix nom/càrrec;
- account/tenant mismatch;
- grant revoked;
- toggle/kill-switch;
- body target forjat;
- BFF secret absent/incorrecte;
- cap `service_role` al bundle Next.

### Concurrència

- link vs portal;
- office vs portal;
- doble tab;
- retry mateixa operation;
- request expirada durant formulari.

### UX

- pendent → revisar → acceptar/refusar → justificant;
- mòbil/keyboard/ca/es/en;
- invoice/other read pages continuen accessibles;
- shared mailbox copy comprensible.

## DoD

- [x] Pendents visibles amb recompte. *(2026-10-07 — tall 1: `list_pending_decisions` + dashboard)*
- [x] Mateix snapshot que `/sign`. *(allowlist + PDF BFF + pad natiu)*
- [x] Acceptació nativa dins portal. *(2026-10-07 — tall 3 + review `00018`: prepare → stamp → strangler; edge rellegeix status)*
- [x] Refús sense pad. *(2026-10-07 — tall 2: `apply_customer_portal_pending_decision` → via `portal`)*
- [x] Identitat nominativa/shared auditada. *(00018: named_person ignora `signer_name` del body)*
- [~] First-wins reflectit correctament. *(edge/UI ja no inventen outcome; UAT doble canal a F9)*
- [~] Notificació tenant idempotent. *(apply existent; còpia justificant opcional diferida)*
- [~] Accept sense sessió nativa prèvia (send). *(encara cal `sign_native` abans; crear sessió des del portal diferit)*

## Rollback

Desactivar capability de decisió manté portal read-only. Requests continuen decidibles per `/sign` o oficina.
