# Prompt: Pla d'implementació del Mòdul de Qualitat i Compliment ISO

Actua com un **Principal Engineer** expert en arquitectura de sistemes SaaS multi-tenant i com a **consultor de compliment normatiu ISO** (9001 Qualitat, amb visió que el disseny sigui extensible a 14001 i 45001).

## Context de negoci

Volem un "Mòdul de Qualitat i Compliment ISO" amb dos objectius, per aquest ordre d'importància:

1. **Facilitar l'obtenció i manteniment del certificat.** Un auditor de l'entitat certificadora ha de poder revisar remotament, dins l'app, la traçabilitat documental, els procediments, les no conformitats i els registres del tenant, minimitzant la visita física.
2. **Aportar valor encara que el tenant no vulgui certificar-se.** El control de versions, les aprovacions, el registre de no conformitats i els indicadors de qualitat han de millorar el dia a dia de qualsevol tenant, certifiqui's o no.

No donis per fet cap decisió d'arquitectura de rols abans d'hora: forma part del que t'he de demanar que analitzis i decideixis amb criteris explícits (secció 2).

## FASE 0 (obligatòria abans de proposar res): Auditoria del sistema actual

Analitza el codi i documenta, breument però amb precisió:

- **Model de dades actual**: entitats de tenant, usuaris, departaments/equips, tasques, i com es garanteix l'aïllament multi-tenant (tenant_id, esquemes separats, RLS, etc.).
- **Sistema d'autenticació i rols**: confirma si els permisos actuals (`owner`, `manager`, `member`, `viewer`) són **per rol** o admeten ja algun tipus d'assignació **per usuari**. Aquest punt és crític: no ho donis per suposat, verifica-ho al codi.
- **Sistema de gestió documental**: com funciona el versionat de documents, qui pot aprovar/publicar versions, si hi ha ja un concepte d'estat (esborrany/en revisió/aprovat/obsolet).
- **Sistema de plantilles**: com es defineixen les plantilles que la plataforma ofereix, com les clona un tenant, i si el resultat clonat queda enllaçat a la plantilla origen (per exemple, per detectar quan una plantilla s'actualitza).
- **Patró existent d'accés extern**, si n'hi ha algun (per exemple, si ja s'ha pensat com donar accés a una gestoria). Si no existeix cap patró, digues-ho explícitament.

## 1. Decisió d'arquitectura de rols i permisos (RBAC) — amb criteris, no amb solució imposada

Actualment tenim `owner`, `manager`, `member`, `viewer`, aplicats **per rol** (no per usuari), i com a mínim dos casos d'ús d'accés extern semblants:

- Un **gestor/gestoria** extern al tenant, amb accés parcial a l'app.
- Un **auditor/consultor ISO**, extern, amb accés de només lectura/revisió a documentació i registres, possiblement a diversos tenants alhora (un mateix auditor pot auditar diversos clients de la plataforma).

Vull que **analitzis i recomanis, justificant el trade-off**, entre aquestes opcions (o una combinació):

- **(A)** Ampliar `viewer` amb un sistema de permisos granulars per funcionalitat/mòdul (encara caldria decidir si per rol o per usuari).
- **(B)** Migrar (totalment o només per aquest cas) a permisos **per usuari** amb overrides sobre el rol base, i quin cost/risc té aquesta migració donat el disseny actual.
- **(C)** Crear un rol nou dedicat (p. ex. `external_auditor` o `external_collaborator`) amb un abast (*scope*) restringit per definició, en lloc de dependre de permisos ad-hoc.
- **(D)** Un patró **genèric de "Col·laborador Extern"** reutilitzable tant per gestoria com per auditor ISO (i futurs casos: assessoria legal, mútua, etc.), amb atributs com: tenant(s) als quals té accés, abast (mòduls/documents concrets vs tot el tenant), nivell (només lectura / comentaris / edició), caducitat de la invitació, i revocació.

Independentment de l'opció triada, el disseny ha de resoldre:

- Una identitat externa (auditor) pot necessitar accedir a **múltiples tenants** sense trencar l'aïllament de dades entre ells.
- L'accés ha de ser **temporal i revocable** (durada de l'auditoria, o de la relació amb la gestoria).
- Cal **registre d'activitat** de què ha vist/comentat l'usuari extern (important per a la credibilitat davant l'entitat certificadora i per a RGPD).
- L'auditor ha de poder deixar **troballes/observacions/no conformitats** sense poder modificar la documentació original del tenant.

## 2. Impacte en el model de dades

Determina quines entitats noves calen i com s'enllacen amb les existents (no com a mòdul aïllat):

- Metadades ISO sobre documents existents (mapeig a clàusules de la norma, propietari del document, propera revisió programada).
- No conformitats / accions correctives i preventives (CAPA), amb origen (auditoria interna, auditoria externa, incidència de client, etc.), responsable i termini.
- Auditories internes (planificació, execució, resultats).
- Revisió per la direcció (management review).
- Registre de riscos i oportunitats, amb representació de **matriu de riscos** (probabilitat × impacte).
- Objectius de qualitat i el seu seguiment (KPIs amb evolució temporal).
- Competència i formació de personal, amb **matriu de polivalència** (empleat × habilitat/procés, amb estat: capacitat / en formació / pot formar altres).
- Evidències (adjunts, enllaços a tasques/registres ja existents a l'app).
- Historial d'accessos i accions dels usuaris externs (auditor/gestor).
- Estat de publicació dels documents (esborrany / en revisió / aprovat / obsolet) i qui té permís d'aprovar-lo, integrat amb el sistema de versioning ja existent.

## 3. Plantilles específiques ISO

Proposa com aprofitar el sistema de plantilles ja existent per oferir una **biblioteca de plantilles ISO 9001** (procediments obligatoris, política de qualitat, manual de qualitat, matriu de riscos, pla d'auditoria interna, etc.), versionades igual que la resta de plantilles, i com fer el seguiment de quins documents del tenant deriven de quina plantilla i versió.

## 4. Pla d'execució per fases (Vibe Coding Roadmap)

Divideix-ho en 4 fases accionables. Per a cada fase indica: objectiu, entitats/fitxers principals a tocar, i criteri de "fet".

- **Fase 0**: Decisió d'arquitectura de permisos (resultat de la secció 1) i disseny de l'esquema de dades base. Sense aquesta fase resolta, no es comença a programar.
- **Fase 1**: Motor documental ampliat (metadades ISO, mapeig a clàusules, plantilles ISO).
- **Fase 2**: Gestió de no conformitats/CAPA, riscos (amb matriu), objectius de qualitat (KPIs) i formació (amb matriu de polivalència). Inclou checklists d'auditoria interna amb disseny mobile-first (ús des de tablet/mòbil en planta).
- **Fase 3**: Arquitectura d'accés extern (patró unificat auditor/gestoria): invitacions, abast, caducitat, aïllament multi-tenant, registre d'activitat.
- **Fase 4**: Portal de l'auditor i dashboard de compliment (estat de preparació per a certificació, auditories internes, revisió per la direcció).
- **Fase 5 (opcional, valor per a tenants que parteixen de zero)**: Assistent d'onboarding (wizard) que, a partir de dades bàsiques del tenant (missió, visió, mapa de processos), generi l'esquelet inicial del Manual de Qualitat i cloni les plantilles ISO rellevants automàticament.

## Format de resposta

Respon únicament amb el pla estratègic (incloent la teva recomanació justificada per a la secció 1). No generis codi. Si algun punt de la Fase 0 (auditoria del codi actual) et deixa dubtes bloquejants sobre el sistema de permisos actual, fes les preguntes necessàries abans de proposar la solució de RBAC.
