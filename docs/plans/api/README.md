# API Rest

> **Estat:** pla a nivell de prompts d'ideació, **cap fase dissenyada ni implementada**.
> **Relacionat:** [`docs/plans/mcp_server/`](../mcp_server/README.md) (pla d'enginyeria complet per al MCP Server, també 0% implementat).

## Consideracions estratègiques (2026-09-16)

1. **Maduresa relativa.** El MCP Server ja té un pla d'enginyeria complet (threat model, DDL, fases MCP-0…12, criteris Go/No-Go) tot i que 0% implementat. Aquest document d'API/Webhooks és encara a nivell de prompts d'ideació, sense DDL ni fases concretes.
2. **No duplicar infraestructura de seguretat.** API keys hashed, aïllament per `tenant_id`/RLS, rate limiting en capes, kill switch i `audit_logs` s'han de dissenyar **una sola vegada** i reutilitzar-se tant per al MCP com per a l'API REST. No construir dues piles d'auth independents.
3. **Ordre de prioritat recomanat.** Primer el MCP Server (tools read-only, epic MCP-7), reutilitzant-lo després com a base per a una capa REST prima per a integracions ERP/BI/scripts. Motiu: el perfil objectiu (administratius/programadors de PIME fent *vibe coding* amb agents IA) treu més valor immediat d'un connector MCP que d'una API que exigeix escriure client HTTP.
4. **No és un bloquejador de producció ara mateix.** El roadmap actual ([`platform-roadmap-prioritat-2026.md`](../platform-roadmap-prioritat-2026.md)) marca Employees, Public Portal i Time Attendance com a bloquejadors funcionals previs. Obrir un canal d'accés extern abans que el *core* de dades estigui tancat arrisca a trencar contractes d'API contínuament.
5. **Seguretat i estabilitat encara per demostrar.** Ni l'API ni el MCP estan implementats; cap dels dos es pot considerar "segur i estable" fins que es completin les fases de disseny (threat model, RLS, rate limit, sandbox) i es passi per un canary/Go-No-Go, tal com ja preveu el pla MCP a [`04-acceptance-and-gates.md`](../mcp_server/04-acceptance-and-gates.md).
6. **Quan es reprengui aquest pla**, el prompt següent ja demana explícitament reutilitzar la infraestructura del MCP Server (claus API, RLS, rate limit, audit) en lloc de dissenyar-la de nou.

---

Aquí tens la proposta de prompt detallat per generar el pla d'implementació de l'API B2B. Manté el mateix rigor tècnic que l'anterior i posa un èmfasi especial en la seguretat multi-tenant i l'alineació d'aquesta API amb el futur de la IA.

Copia i enganxa el text següent a la teva IA:


Actua com un Arquitecte de Programari Expert, especialista en el disseny d'APIs RESTful B2B i entorns SaaS Multi-Tenant.

Tinc una aplicació SaaS Multi-Tenant i Multi-Site recolzada per una base de dades PostgreSQL. Fins ara, el frontend s'ha comunicat amb el backend mitjançant crides internes autenticades per l'usuari final. Ara, vull dissenyar un pla d'implementació per crear una API REST pública B2B que permeti als nostres clients (tenants) integrar els seus propis sistemes (ERPs, eines BI, scripts de tercers) amb les seves dades a la nostra app.

Aquest pla ha de ser agnòstic respecte a la infraestructura exacta (tant pot ser implementat amb Express/Node.js clàssic, com amb entorns Serverless tipus Firebase Functions o Supabase Edge Functions), però ha d'abordar els reptes clàssics d'aquests entorns.

A partir d'aquests requisits, genera un pla d'implementació complet, estructurat en fases, i accionable:

1. Autenticació B2B i Gestió de Claus API
Dissenya l'esquema de base de dades per emmagatzemar les API Keys dels tenants de forma segura (ús de hashes com bcrypt/Argon2 en lloc de text pla).

Proposa com s'ha de dissenyar el middleware d'autenticació que interceptarà la capçalera Authorization: Bearer <API_KEY>, validarà el hash, i resoldrà el tenant_id corresponent.

Defineix els endpoints necessaris per al panell d'administració on l'usuari (Owner/Manager) podrà crear, llistar, revocar i assignar permisos (scopes) a aquestes claus.

2. Aïllament Multi-Tenant (Seguretat Crítica)
Com garantim que el tenant_id resolt pel middleware s'apliqui a totes les consultes cap a la base de dades de forma ineludible?

Proposa patrons segurs per a l'accés a dades (ja sigui mitjançant la injecció forçada del tenant_id a les clàusules WHERE en l'accés tradicional via SQL/ORM, o bé utilitzant polítiques de Row-Level Security (RLS) en PostgreSQL).

3. Arquitectura, Enrutament i Protecció
Defineix l'estructura d'enrutament (ex: /api/v1/elevators).

Proposa una estratègia sòlida de Rate Limiting i protecció contra abusos per evitar que un client esgoti el connection pool de PostgreSQL o la quota de processament del servidor.

Defineix un format d'error estàndard per a les respostes (ex: codis HTTP adequats, estructura JSON per a les validacions i excepcions).

4. Sinergia amb la IA (De l'API B2B al Function Calling)
Aquesta API REST B2B ha de servir també com la base per a les "Tools" del nostre futur sistema de Function Calling d'IA interna (OpenAI, Anthropic).

Proposa com documentar i definir aquesta API utilitzant l'estàndard OpenAPI (Swagger) de manera que es pugui exportar aquest JSON d'especificació i injectar-lo directament als models d'IA, maximitzant la reutilització de codi.

5. Entorn de Proves (Sandbox) i Experiència de Desenvolupador (DX)
Per oferir una API professional i segura, és imprescindible que els desenvolupadors dels nostres clients puguin fer proves sense risc de contaminar les dades de producció.

Gestió de Claus Duals: Proposa com implementar un sistema a l'estil Stripe, on el tenant generi parells de claus diferenciades (ex: prefixos sk_live_... i sk_test_...) i com el middleware ha de reaccionar davant de cadascuna.

Aïllament de Dades (El patró "Shadow Tenant"): Dissenya l'estratègia per aïllar completament les dades de prova a PostgreSQL. Avalua i desenvolupa l'enfocament de crear un "Tenant a l'ombra" (un tenant_id secundari i invisible vinculat al tenant principal) perquè l'API en mode test escrigui i llegeixi d'allà, evitant haver d'afegir columnes booleanes tipus is_test a totes les taules de l'aplicació.

Cicle de Vida de l'Entorn Sandbox: Dissenya els mecanismes necessaris (endpoints interns) perquè l'usuari pugui fer un "Reset" del seu entorn de proves, eliminant en cascada tota la brossa generada i tenint l'opció de repoblar-lo amb dades llavor (seed data) per facilitar les proves d'integració.

Visibilitat a la UI: Proposa com el frontend actual hauria de gestionar aquest "Shadow Tenant" (ex: un interruptor global de "Mode Prova" a la capçalera de l'app) per permetre als administradors visualitzar l'estat de les seves integracions de prova.

6. Reutilització de la Infraestructura del MCP Server (No-Duplicació)
Ja tenim (o estem dissenyant en paral·lel) un servidor MCP amb autenticació OAuth 2.1 per a usuaris i API keys hashed per a integracions S2S (`mcp_live_...` / `mcp_test_...`), aïllament multi-tenant via RLS, rate limiting en 3 capes (WAF/edge, store distribuït, quotes per tenant a BD) i `audit_logs` de cicle de vida. Documenta a `docs/plans/mcp_server/`.

Proposa explícitament com aquesta API REST B2B pot **reutilitzar la mateixa taula de claus, el mateix middleware de resolució de tenant i el mateix motor de rate limiting/kill switch** en lloc de crear una segona pila d'autenticació i seguretat en paral·lel. Indica quines parts són genuïnament noves (rutes REST, contracte d'errors HTTP, OpenAPI) i quines s'han d'importar tal qual del MCP.

Si us plau, retorna el pla organitzat en fases (Fase 0: Alineació i reutilització amb la infraestructura MCP existent, Fase 1: Seguretat i API Keys, Fase 2: Core i Aïllament SQL, Fase 3: Estandardització i Endpoints Base, Fase 4: Sinergia IA/OpenAPI, Fase 5: Sandbox i DX), incloent recomanacions d'esquemes SQL per a la taula de claus API i pseudocodi o TypeScript genèric per a l'estructura del middleware.




1. Fes una Prova de Concepte (PoC) amb un sol mòdul
No intentis generar l'API de cop per a tots els mòduls. Tria'n només un que sigui senzill però representatiu, per exemple, Empleats.

Dissenya l'endpoint segur (GET /api/v1/employees).

Assegura't que el filtre WHERE tenant_id = X funciona perfectament.

Crea la definició JSON de l'eina (get_employees) que mapegi exactament cap a aquest endpoint o funció.

2. Connecta-ho al teu Xat Local
Com que ja tens l'arrel del teu servei d'IA muntat (generateWithProvider), injecta aquesta nova eina get_employees a la crida de l'IA.

Obre la teva app en local, ves al xat i demana-li: "Fes-me una llista dels empleats actius".

Observa com l'IA s'atura, crida la teva funció SQL, i et retorna la resposta ben redactada.

3. Estandarditza abans d'escalar
Quan aconsegueixis que aquest cicle complet (Usuari -> IA -> Tool -> SQL -> IA -> Usuari) funcioni bé amb els Empleats, hauràs creat un patró. A partir d'aquí, aplicar-ho a DMS, Equips o Sites serà simplement replicar aquest patró ("copiar i enganxar" l'estructura base i canviar la taula SQL). Fes tot això abans de pensar en muntar entorns de staging o producció.

Això et permetrà validar l'arquitectura abans de comprometre-t'hi massa. De tots els mòduls que ja tens fets (Empleats, DMS, etc.), quin creus que té més sentit utilitzar com a "conillet d'índies" per provar aquesta primera integració d'API + Tool Calling?











# Webhooks


Aquí tens la proposta de prompt detallat perquè la teva IA generi un pla d'arquitectura complet per al sistema d'integracions. Aquest prompt està dissenyat per tractar tant l'enviament d'esdeveniments cap a fora (Webhooks) com la sincronització bidireccional amb sistemes de tercers (el connector de Holded), mantenint l'enfocament agnòstic i de màxima seguretat multi-tenant.

Copia i enganxa el text següent a la teva IA:



Actua com un Arquitecte de Programari Expert, especialista en Arquitectures Orientades a Esdeveniments (Event-Driven) i Integracions B2B en entorns SaaS.

Tinc una aplicació SaaS Multi-Tenant i Multi-Site recolzada per una base de dades PostgreSQL. Actualment el "Core" (Tenants, Sites, Usuaris, Empleats, DMS) ja està establert. L'arquitectura backend és serverless (Supabase Edge Functions).

Vull dissenyar un pla d'implementació complet per a dos nous mòduls d'integració:

Sistema de Webhooks (Outbound): Per permetre als tenants subscriure's a esdeveniments de la nostra app (ex: employee.created, document.uploaded) i rebre'ls als seus propis servidors.

Connectors a ERPs (Iniciant amb Holded): Per sincronitzar dades de negoci (com factures del DMS o empleats) entre la nostra app i l'ERP Holded del tenant.

Genera un pla d'implementació tècnic, escalable i estructurat en les següents fases:

1. Arquitectura de Webhooks (Outbound)
Captura d'Esdeveniments: Proposa com interceptar els canvis de dades (ex: a través de triggers de PostgreSQL, change data capture (CDC), o a nivell d'aplicació / ORM) per generar l'esdeveniment sense bloquejar la resposta a l'usuari.

Cues i Reintents (Reliability): Com dissenyar un sistema de reintents amb backoff exponencial (evitant el processament síncron) i com gestionar els errors definitius (Dead Letter Queue). Proposa enfocaments agnòstics (ex: utilitzant taules PostgreSQL com a cua, o serveis Pub/Sub).

Seguretat i Firmes: Dissenya l'estratègia per firmar els payloads (ex: HMAC amb SHA-256) perquè el client pugui verificar que el Webhook prové autènticament de la nostra aplicació. Quins esquemes SQL necessitem per guardar els webhook_endpoints i els seus secrets per tenant?

2. Connector d'ERP: Holded (Inbound/Outbound)
Gestió de Credencials de Tercers: Proposa un esquema de base de dades segur per guardar les claus d'API de Holded associades a cada tenant_id (simètric a com guardem les claus de la IA).

Estratègia de Sincronització: Dissenya els fluxos per enviar dades a Holded (ex: quan es puja una factura al DMS) i per rebre/llegir dades de Holded. Proposa si és millor un enfocament basat en esdeveniments (reaccionar al moment) o tasques programades (Cron jobs / Batch processing) tenint en compte els Rate Limits típics de les APIs d'ERPs.

Emmagatzematge d'IDs Externs (Mapping): Com hem de relacionar els IDs de la nostra base de dades (ex: employee_id = 123) amb els IDs únics de Holded (holded_contact_id = abc) sense contaminar innecessàriament les taules del Core? (Ex: Taula polimòrfica d'external_mappings).

3. Aïllament Multi-Tenant en Integracions
Detalla com assegurar que el procés en segon pla que sincronitza dades amb Holded utilitza exclusivament la clau de Holded del Tenant corresponent i només llegeix/escriu dades d'aquell Tenant.

4. Panell de Control UI i Monitoratge
Quins endpoints REST (o funcions) necessitarem perquè el tenant pugui: configurar els seus Webhooks, introduir la seva API Key de Holded, i veure un log d'errors si la sincronització amb Holded falla o si un Webhook dóna error 500 reiteradament?

Si us plau, retorna el pla detallat amb recomanacions d'esquemes SQL clau (taules per a Webhooks, Credencials ERP, Logs d'esdeveniments, Mapeig d'IDs) i pseudocodi o TypeScript genèric per a l'estructura del worker o funció que executa les tasques asíncrones.





Com a desenvolupador podré provar el funcionament amb Holded sense pagar subscripció?

**Sí, pots provar-ho sense pagar, però amb un matís important sobre com funcionen els seus plans.**

La realitat de l'API de Holded és la següent:

* L'accés a l'API **no està disponible en el seu pla gratuït permanent (Free)**. Per poder generar una *API Key*, la documentació oficial especifica que has de tenir un pla de pagament actiu.
* **La solució per a tu:** Pots crear un compte i aprofitar la seva **prova gratuïta de 14 dies**, la qual no requereix introduir cap targeta de crèdit.

Durant aquesta finestra de 14 dies, tindràs accés total a l'API i podràs configurar l'entorn ideal per al teu desenvolupament local de la següent manera:

### 1. Activa el Compte Demo (Sandbox)

Mai facis proves d'integració directament sobre el compte principal, encara que estigui buit. Holded té un **entorn de proves (Sandbox)** integrat.

* S'hi accedeix des del menú superior esquerre (on hi ha el nom del compte) seleccionant *Cambiar cuenta > Acceder a la cuenta demo*.
* Aquest entorn et permet carregar dades de prova (*seed data*) automàticament, com factures i usuaris ficticis, de manera que tindràs IDs de contactes i documents amb què jugar des del minut u.
* Si un *Webhook* o una petició `POST` del teu codi es descontrola i embruta les dades, pots anar a la configuració i fer un **Reset complet de la demo** per començar de zero amb un entorn net.

### 2. Genera l'API Key

Un cop tinguis la prova de 14 dies activa, podràs anar al menú de *Configuración > Desarrolladores > Credenciales* per crear el teu API Token. Aquest token serà el que hauràs de posar com a capçalera d'autorització `Bearer` a les teves Cloud Functions per autenticar les crides HTTP.

---

**El meu consell estratègic:**
Atès que el rellotge dels 14 dies corre ràpid, **no et creïs el compte de Holded encara**. Acaba primer el *Core* a PostgreSQL, implementa l'esquema de la teva base de dades i deixa preparada l'estructura del codi de les teves *Edge Functions* o *Firebase Functions*. Obre el compte de Holded únicament quan ja només et quedi prémer el botó d'enviar per validar que els JSONs que escups s'estan creant correctament al seu ERP.





**Sí, rotundament.** Si vols que la teva API B2B tingui èxit i transmeti professionalitat, oferir un entorn de proves o *Sandbox* és gairebé obligatori. És un estàndard de la indústria impulsat per empreses com Stripe, Twilio i, com has vist, Holded.

Quan obres l'aplicació a integracions externes, els desenvolupadors dels teus clients estaran fent exactament el mateix que tu faràs amb Holded: llançar peticions HTTP amb dades falses per veure com respon el sistema, cometre errors d'enrutament i enviar JSONs mal formats. Si només els ofereixes l'entorn de producció, de seguida ompliran el seu mòdul d'Empleats o el seu DMS amb "Test 1", "Document Prova" i usuaris brossa, la qual cosa frustrarà els usuaris reals de la teva aplicació.

En la teva arquitectura multi-tenant amb PostgreSQL, implementar aquest *Sandbox* és més directe del que sembla. Aquí tens com estructurar-ho:

### 1. El patró de les Claus d'API duals

L'enfocament més elegant (i el més conegut pels desenvolupadors gràcies a Stripe) és proporcionar al client dues claus diferents:

* **Live Key:** Ex. `sk_live_8f3a2b...` (Escriu i llegeix dades reals).
* **Test Key:** Ex. `sk_test_9b1c4d...` (Escriu i llegeix només dades de prova).

Quan el teu *middleware* rep la petició, analitza el prefix de la clau i sap instantàniament en quin "mode" ha d'operar.

### 2. Aïllament de les dades a PostgreSQL

Tens dues vies principals per separar les dades de prova de les reals, i la segona és la més segura per al teu cas:

* **Via A (Columna Lògica - Menys Segura):** Afegir una columna boolean `is_test` o `environment` a totes les teves taules (Empleats, Documents). El risc és que un error en una clàusula `WHERE` o en les regles RLS podria fer que dades de prova apareguessin als panells de control de producció.
* **Via B (El "Shadow Tenant" - Altament Recomanada):** Atès que el teu *Core* ja està basat en un fort aïllament per `tenant_id`, la millor estratègia és que, quan un client es dona d'alta, el teu sistema creï **dos** registres a la taula `tenants`. Un per a la producció (ex: `tenant_id = 100`) i un "Tenant a l'ombra" per al Sandbox (ex: `tenant_id = 101`).
* A la taula de claus API, la `sk_test_...` apuntarà directament al `tenant_id = 101`.
* Això garanteix un aïllament total. L'estructura de la base de dades no canvia, el codi de les consultes SQL no es toca, i és impossible que les dades es barregin.
