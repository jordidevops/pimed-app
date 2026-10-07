# CF-28 — Decisions tancades (CS-D*)

> No reobrir sense entrada al registre del [`README.md`](./README.md).  
> Hereta CF-D*, CT-D* i el contracte CP-C, excepte el gate tècnic d'acord indicat a **CS-D8**.

## Domini

| ID | Decisió |
|----|---------|
| **CS-D1** | La unitat de negoci és `data.commercial_decision_requests`. No és una sessió de firma, un correu ni un event. |
| **CS-D2** | Una request apunta exactament a un target: `commercial_document_id` **xor** `agreement_version_id`. CHECK de base de dades, no només TypeScript. |
| **CS-D3** | `purpose`: `acceptance` per quote/amendment/agreement i `delivery_confirmation` per albarà. No existeix `rejection_signature`. |
| **CS-D4** | Estat request: `open \| accepted \| declined \| expired \| revoked \| superseded`. Només `open` es pot decidir. |
| **CS-D5** | Una sola request `open` per target, garantida amb dos índexs únics parcials (document i agreement version). |
| **CS-D6** | V1 té un sol signant responsable. N lliuraments poden apuntar a la request, però només hi ha un outcome. Multi-signatura és V2. |

## Snapshot i integritat

| ID | Decisió |
|----|---------|
| **CS-D7** | Crear una request fixa `snapshot_json`, `content_hash`, `rendered_document_id` i `document_version_id`. La pàgina pública no renderitza plantilles o files vives. |
| **CS-D8** | `separate_agreement`: l'oficina pot preparar l'acord des d'una quote `issued`; signar l'acord posa versió `signed`, acord actiu i quote origen `accepted` atòmicament. Això substitueix el gate as-built «quote accepted abans de prepare», però no crea acords automàticament. |
| **CS-D9** | `signed_quote`: s'accepta el document comercial; `separate_agreement`: només s'envia la versió d'acord. Prohibit demanar dues firmes pel mateix encàrrec. |
| **CS-D10** | Un canvi de snapshot, hash o versió exigeix una request nova; l'anterior passa a `superseded`. No es modifica una request oberta per apuntar a contingut nou. |
| **CS-D11** | La versió PDF acceptada queda al mateix `document_id` DMS que el render comercial; el PDF estampat és una nova `document_version`. |

## Lliuraments i tokens

| ID | Decisió |
|----|---------|
| **CS-D12** | Cada intent de lliurament viu a `data.commercial_decision_deliveries`: request, canal, destinatari, locale, status, idempotency key i timestamps. |
| **CS-D13** | Canal V1: `email \| portal \| presential \| whatsapp_portal_nudge`. Sense `copy_link`. `portal` no necessita bearer per decidir. WhatsApp només envia un deep link al customer portal (mai `/sign/:token` ni URL DocuSeal); si no hi ha grant portal viu, el canal queda deshabilitat o text sense URL. |
| **CS-D14** | Tokens públics aleatoris de 256 bits; només `token_hash` SHA-256 a base de dades. No apareixen a logs, metadata d'email ni events de negoci. |
| **CS-D15** | Reenviar crea delivery/token nou. L'anterior es pot mantenir o revocar explícitament; «Revocar tots» tanca els tokens actius sense esborrar evidència. El reenviament **no** retorna `raw_token` al tenant-portal. |
| **CS-D16** | La validesa efectiva és el mínim entre request, token i target. La comprovació és síncrona a resolve/apply; cron només materialitza `expired`. |
| **CS-D17** | Bearer link V1 és risc explícit per al **destinatari del correu** (rate limit, TTL, revocació, log d'accés). El tenant **no** és portador deliberat de l'URL. |

## Apply i concurrència

| ID | Decisió |
|----|---------|
| **CS-D18** | Tots els camins criden `data.apply_commercial_decision_request`; cap trigger, webhook o UI escriu directament l'estat comercial. |
| **CS-D19** | Ordre de lock únic: request → target comercial/agreement → projecte si cal recomputar. Prohibit adquirir-los en ordre diferent. |
| **CS-D20** | Apply fa compare-and-set `open → outcome`; si actualitza zero files torna el resultat existent. No hi ha last-write-wins. |
| **CS-D21** | La transacció valida target, tenant, content hash, status, caducitat i supersede; escriu outcome, event i projecció comercial. Cap HTTP, PDF, email ni notificació externa dins la transacció. |
| **CS-D22** | Idempotència externa: `client_op_id` per ordre del tenant/portal i event id del proveïdor. Idempotència no substitueix el lock; amb claus diferents la primera decisió també ha de guanyar. |
| **CS-D23** | `commercial_signing_intents` es conserva durant el strangler. El nou domini fa dual-write/adaptador; no es retira fins que `api.commercial_signing_hub` i els tests ja no en depenguin. |

## Outcomes comercials

| Target | Acceptar | Refusar |
|--------|----------|---------|
| Quote/amendment | `accepted`; recomputar autoritzat | `rejected` |
| Agreement version | `signed`; activar acord; acceptar quote origen | `declined`; quote origen continua no acceptada |
| Delivery note | `signed` | `rejected`, etiqueta UI «Disputat» |

| ID | Decisió |
|----|---------|
| **CS-D24** | Sessió nativa `declined` és diferent de `cancelled`. Client refusa = `declined`; tenant revoca/abandona = `cancelled`. |
| **CS-D25** | Albarà disputat queda exclòs al servidor de llistes/KPI `to_invoice`, `create_invoice_draft_from_delivery_notes`, saldos facturables i qualsevol acció equivalent. |
| **CS-D26** | Refús remot: motiu opcional. Refús registrat per oficina: motiu obligatori i copy «Resposta comunicada fora de PiMed». Cap refús demana pad. |
| **CS-D27** | Quote expirada o target anul·lat/substituït no es pot acceptar encara que el token no hagi expirat. |

## Evidència i privacitat

| ID | Decisió |
|----|---------|
| **CS-D28** | Outcome/evidència és append-only: request, outcome, via, actor declarat, principal portal, email, IP server-side, UA, hora, hash, provider refs i motiu. |
| **CS-D29** | La request pot projectar `decided_at`/`decided_via`, però l'evidència completa no es reescriu. |
| **CS-D30** | Justificant disponible per tenant i client: document, outcome, signant, timestamp, hash i proveïdor; sense exposar IP completa al client. |
| **CS-D31** | IP no es consulta a tercers com ipify; es captura al servidor. Informació Art. 13 a `/sign` i docs del portal. |
| **CS-D32** | Retenció de l'evidència segueix la del document comercial; tokens i intents de delivery expiren/purguen segons política separada. |

## Proveïdors

| ID | Decisió |
|----|---------|
| **CS-D33** | Firma nativa és default si `native_signing_enabled`; no consumeix crèdits. |
| **CS-D34** | DocuSeal només disponible si configurat i amb crèdits. Consum idempotent una vegada per submission creada, no per webhook. |
| **CS-D35** | Canviar de proveïdor revoca la sessió/submission activa anterior i crea un nou intent sobre la mateixa request/snapshot. Mai dos proveïdors actius alhora. |
| **CS-D36** | DocuSeal completed/declined entra pel mateix apply. El webhook no té lògica comercial paral·lela. |

## Correu i notificacions

| ID | Decisió |
|----|---------|
| **CS-D37** | Correu comercial s'envia al servidor via `api.enqueue_email`; `mailto:` només pot quedar com fallback de «Només entregar». |
| **CS-D38** | Cos del correu = resum segur + CTA, no HTML complet del document. PDF sense firma opcional: on per quote/acord, off per DN. |
| **CS-D39** | `idempotency_key = commercial-decision:{request_id}:delivery:{delivery_id}`. Reenviar crea un `delivery_id` nou. |
| **CS-D40** | Estat visible: queued/sent/failed. «Vist» només quan es resol l'enllaç; no píxel invisible de tracking. |
| **CS-D41** | Outcome crea notificació in-app idempotent i email opcional a l'emissor. Mai crea targetes a Avui. |

## Portal del client

| ID | Decisió |
|----|---------|
| **CS-D42** | Mòduls comercials del portal són opt-in: quotes/acords, albarans, factures. Off per defecte per tenants existents. |
| **CS-D43** | `share_only` permet links puntuals però no el catàleg comercial; el catàleg requereix mode `portal` i grant live. |
| **CS-D44** | Customer portal no usa PostgREST directe per dades comercials: BFF opac → Edge autenticada → RPC/projecció allowlistada. Cap `service_role` a Next.js. |
| **CS-D45** | Scope sempre per `tenant_id + client_account_contact_id = commercial.client_id`; principal no amplia el compte. |
| **CS-D46** | Principal nominatiu decideix. Bústia compartida pot decidir només declarant nom i càrrec del representant, guardats a evidència. |
| **CS-D47** | Portal mostra només documents emesos, snapshots i agregats. Prohibit drafts, notes internes, costos/marges, taules de pagaments crues o navegació DMS interna. |
| **CS-D48** | Factura: total, impostos, venciment, pagat, pendent, rectificatives i origen. Pagaments es projecten agregats; no hi ha cobrament online V1. |

## UX i compatibilitat

| ID | Decisió |
|----|---------|
| **CS-D49** | CTA principal en emesos: «Enviar per acceptar». «Només entregar PDF» és secundari. DMS/centre de signatures viuen sota «Més». |
| **CS-D50** | `/sign/:token` es manté. El resolver discrimina token DMS genèric i token comercial; la variant comercial no trenca el flux genèric. |
| **CS-D51** | Badges separen proveïdor (`Firma pròpia`/`DocuSeal`) i canal (`Remota`/`Presencial`). «Firmat digitalment» genèric desapareix de comercial. |
| **CS-D52** | Estat remot es refresca per focus + polling acotat mentre és open, o subscripció filtrada per request. Prohibit una subscripció global del tenant. |
| **CS-D53** | Feature flag tenant `commercial_decision_requests_enabled` governa el strangler. Toggles portal governen només exposició, no integritat del domini. |

## Escala

| ID | Decisió |
|----|---------|
| **CS-D54** | Llistes tenant/portal amb keyset pagination; cap `OFFSET` profund. Índexs comencen per claus d'igualtat (`tenant_id`, `client_id`, status) i acaben per cursor temporal/id. |
| **CS-D55** | Índex parcial per requests open i tokens actius; FKs de request/delivery/event indexades. No GIN sobre snapshot sense una query demostrada. |
| **CS-D56** | PDF, adjunts, correu i DocuSeal són cues/retries idempotents; apply ha de romandre curt. |
| **CS-D57** | Correlation id operatiu = `decision_request_id`; errors de resolver/apply/webhook/cua tenen log estructurat sense token ni PII innecessària. |

## Control d'enllaços de firma (plataforma)

| ID | Decisió |
|----|---------|
| **CS-D58** | La plataforma no exposa al tenant (UI **ni** API/`api.*`/Edge al JWT autenticat) l'URL o token en clar de firma/decisió de la **contrapart**. Lliurament: correu PiMed i/o portal del client. `raw_token`, `signing_url`, `signer_links`, `docuseal_signing_url` i URLs dins `signers` queden a server-side (`service_role` / cua d'email). Signant autenticat que és ell mateix pot completar la firma dins del flux de sessió, sense bearer compartible de tercers. |
| **CS-D59** | Actor `staff` al customer portal: només lectura. No pot acceptar/refusar/prepare-sign ni veure enllaços de firma (reforç Edge, no només UI). |
| **CS-D60** | Fallada d'email **no** autoritza mostrar l'URL al tenant. Només reintent d'enviament o suport. |

## Fora d'abast de decisions V1

- Validesa jurídica qualificada/eIDAS i certificats qualificats.
- Múltiples signants requerits.
- OTP/SMS.
- Recordatoris automàtics.
- Pagament online.
