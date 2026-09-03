# Prompt: Revisió i tancament de gaps del Pla d'implementació ISO

Actua com el mateix Principal Engineer que va elaborar el "Pla estratègic: Mòdul de Qualitat i Compliment ISO" que tens al repositori/context. No refacis el pla sencer ni tornis a justificar decisions ja preses (l'arquitectura D+C+A de col·laborador extern, el model de dades de Qualitat i la biblioteca de plantilles es donen per aprovats). El nombre i divisió de fases tampoc es qüestiona: useu tantes com calgui per implementar-ho correctament.

T'he detectat 5 punts concrets **sense resoldre** al pla actual. Vull que els resolguis un per un, amb la mateixa exigència tècnica que la resta del document (noms de taula/funció reals, no genèrics), i que actualitzis el pla amb la resolució de cadascun. Si per resoldre'n algun necessites tornar a mirar codi que encara no havies revisat, fes-ho.

## 1. Duplicitat de l'estat d'aprovació de documents

El pla identifica que `documents` ja té un camp `approval_status` (`none/pending/approved/rejected`) connectat al motor d'automatització existent. Alhora, proposa un estat ISO nou i separat (`draft/in_review/approved/obsolete`) a `quality_document_controls`/versió.

Resol explícitament:
- Què passa amb el camp `approval_status` existent: es deprecat, es manté en paral·lel amb un mapeig definit entre els dos estats, o l'estat ISO el substitueix i el motor d'automatització es migra a llegir el nou?
- Si es mantenen tots dos, quina és la font de veritat única quan un document és "Quality" i quina relació hi ha exactament entre ambdós camps perquè no puguin divergir (constraint, trigger de sincronització, o un dels dos deixa d'existir).
- Confirma que la resolució no trenca cap automatització/notificació existent que depengui de l'`approval_status` actual.

## 2. Activació del mòdul per tenant (feature flag i pricing)

El pla no diu si el mòdul de Qualitat és opt-in per tenant ni com s'evita que migracions, taules i polítiques RLS noves afectin tenants que no l'han contractat.

Resol:
- Mecanisme concret d'activació per tenant (camp a `data.tenants`, taula de feature flags si ja n'existeix una al codi, o entitlements lligats a pla de subscripció si el sistema ja en té).
- Com es comporta la navegació/menú del tenant portal quan el mòdul no està actiu (ocult per complet, o visible amb crida a l'acció comercial).
- Si ja existeix algun sistema de feature flags o plans de subscripció al repositori, reutilitza'l explícitament i digues-ne el nom; si no existeix, proposa el mínim necessari sense sobredimensionar-lo (no cal un sistema d'entitlements complet només per a aquest mòdul).

## 3. Gestió dels permisos granulars nous per part del tenant

El pla afegeix ~15 permisos granulars de Qualitat (`quality.documents.approve`, etc.) configurables via `data.tenants.metadata.role_permissions`.

Resol:
- Existeix ja avui una UI perquè un `owner` de tenant configuri quins permisos té cada rol (`viewer`/`member`/`manager`), o aquesta configuració es fa només via suport/backend? Verifica-ho al codi, no ho suposis.
- Si no existeix UI, què cal construir com a mínim perquè un tenant pugui decidir, per exemple, que els `member` puguin veure documents de Qualitat però no aprovar-los, sense intervenció manual vostra.
- Si ja existeix UI de permisos, confirma que admet afegir-hi un bloc nou de permisos "Quality" sense canvis estructurals.

## 4. Flux concret d'accés de l'auditor/col·laborador extern

El pla parla de "flux d'invitació/acceptació/revocació" i "autenticació i selecció de tenant" com a superfícies a tocar, sense especificar-les. Necessito la especificació concreta, no la superfície genèrica:

- **Alta del compte**: què passa quan s'invita un email que no té cap `auth.users` associat encara (creació de compte en acceptar la invitació) vs. un email que ja té compte perquè audita altres tenants vostres (simplement s'hi afegeix un grant nou).
- **Mètode d'autenticació recomanat** per a aquest perfil (contrasenya normal vs. passwordless/magic link/OTP) i per què, tenint en compte que és un usuari que entra poques vegades a l'any.
- **Selector de tenant**: la funció que avui resol "a quins tenants té accés l'usuari" (la que alimenta `jwt_user_tenants()` o equivalent) només mira `tenant_members`. Confirma si cal estendre-la perquè inclogui també `external_access_grants` actius, i com distingeix la UI una entrada de tipus membre intern d'una entrada de tipus col·laborador extern dins del mateix selector.
- **Superfície del portal auditor**: és una ruta separada dins la mateixa SPA amb layout restringit segons el tipus de sessió, o una app/subdomini diferent? Justifica la tria en termes de superfície d'atac i cost d'implementació, no només de UX.
- **Revocació en calent**: com detecta el frontend que un grant ha estat revocat mentre la sessió JWT encara és tècnicament vàlida (codi d'error específic al 403 de RLS, missatge a l'usuari), perquè no es quedi en un estat d'error genèric.

## 5. Filtratge d'scope a nivell de llistat, no només d'accés individual

El pla resol correctament l'autorització per obrir un recurs individual (`external_access_allows(tenant, recurs, acció)`), però **no especifica com es filtren els llistats** quan l'scope d'un grant és per carpeta o per mòdul en comptes de per document individual.

Concretament, has de detallar: quan un auditor amb scope "carpeta Procediments" demana la llista de documents del tenant, quina consulta/vista `api.*` s'encarrega que la llista només contingui documents d'aquella carpeta (i no una llista completa amb bloqueig posterior en obrir cada ítem). Si l'scope és per mòdul sencer, per document individual i per carpeta alhora, especifica com es combinen aquests tres nivells en una sola consulta de llistat sense fer N consultes (una per document) ni exposar metadades (títols, dates) de documents fora d'scope.

## Format de resposta

Per a cadascun dels 5 punts: decisió presa, per què, i el fragment concret del pla (secció i, si cal, taula/funció) que quedaria modificat o afegit. No repeteixis parts del pla que no canvien. Si algun punt requereix una decisió de negoci que no pots prendre tu (per exemple, si el mòdul serà de pagament addicional), marca-ho explícitament com a pregunta pendent en lloc d'inventar-te la resposta.
