# Prompt: Estudi d'integració amb eines de facturació certificada (Verifactu) per a autònoms i pimes petites

Actua com el mateix Principal Engineer que ha treballat en els mòduls anteriors d'aquesta app. Mateix mètode: auditoria del codi real primer, decisions amb criteris explícits després, pla al final.

## Objectiu i límit estratègic (no ho oblidis en cap decisió)

L'objectiu és que un autònom amb poca facturació o una pime petita pugui **emetre factures compatibles amb Verifactu des de la nostra app**, sense que nosaltres esdevinguem l'emissor certificat. **La nostra app mai ha de generar, signar o declarar ella mateixa el registre de facturació legal.** Sempre ha de ser un tercer ja certificat (l'eina gratuïta de l'AEAT, Holded, o un altre proveïdor amb declaració responsable pròpia) qui emet i certifica la factura; nosaltres orquestrem la UX i, com a molt, sincronitzem les dades resultants per a visibilitat de tresoreria. Si en algun moment del disseny sembla que estem duplicant, alterant o generant nosaltres mateixos el registre legal de la factura, és un error de disseny greu — atura't i digues-ho explícitament en comptes de continuar.

## FASE 0 (obligatòria, i aquesta vegada té dues parts: codi + recerca externa)

**Part de codi:**
- Existeix avui algun concepte de "factura" o "facturació" al model de dades actual, encara que sigui bàsic? Si existeix, quin abast té i com s'enllaça amb clients/projectes/serveis (reutilitza el que ja vas identificar al mòdul de reviews sobre el "servei completat").
- Existeix ja algun patró d'integració amb serveis externs via API/OAuth al codi (credencials de tercers, tokens, webhooks entrants) que es pugui reutilitzar com a base, en lloc de dissenyar-ne un de nou.
- Com es xifren/protegeixen avui credencials sensibles de tercers si ja n'hi ha cap cas similar (per exemple, claus d'API d'algun altre servei extern ja integrat).

**Part de recerca externa (verifica l'estat actual, no assumeixis res del que sàpigues per entrenament):**
- Quina capacitat real d'integració (API pública, webhooks, documentació per a desenvolupadors, condicions d'accés/preu de l'API) ofereix **Holded** per crear factures i rebre'n els esdeveniments (creada, pagada, etc.) de manera programàtica. Confirma si Holded ja disposa de declaració responsable Verifactu pròpia.
- Quina capacitat d'integració té **l'eina gratuïta que l'AEAT preveu oferir** a autònoms i negocis petits: és una API, un portal web sense API, o un formulari pensat només per a ús manual/ocasional? Això determina si és viable una integració real o només un flux manual assistit.
- Si hi ha altres proveïdors certificats amb API pública i condicions accessibles per a un volum baix de facturació (pensat per al perfil d'autònom/pime petita), llista'ls breument com a alternativa, sense comprometre's encara a integrar-los tots.

## 1. Decisió d'arquitectura d'integració

Amb el que trobis a la Fase 0, avalua i recomana, amb criteris explícits (esforç d'implementació, cost, robustesa, dependència d'un sol proveïdor), entre aquests patrons, que no són excloents:

- **(A) Redirecció/incrustació**: l'usuari surt (o s'incrusta en un iframe/webview si el proveïdor ho permet) cap a Holded/AEAT per emetre la factura, i tornem a rebre només una notificació o consulta posterior de l'estat. Mínim esforç, mínima integració real.
- **(B) Creació des de dins de la nostra UI via API**: l'usuari omple les dades de la factura a la nostra app, i nosaltres cridem l'API del proveïdor certificat perquè sigui ell qui la generi i la certifiqui, mostrant el resultat (número, estat, PDF) a la nostra interfície. Millor UX, més esforç i més dependència de l'API externa.
- **(C) Sincronització passiva**: la factura s'emet completament fora de la nostra app (per exemple, via l'eina AEAT), i nosaltres només n'importem les dades (manualment via pujada d'un fitxer, o via API si n'hi ha) per alimentar el dashboard de tresoreria. Cap capacitat d'emissió des de dins, només visibilitat.

Recomana quin patró (o combinació, per exemple (B) per a Holded si té bona API i (C) com a via manual per a qui fa servir l'eina AEAT) té més sentit per al perfil d'usuari objectiu (autònom de poca facturació / pime petita), tenint en compte que aquest perfil valora sobretot **simplicitat i cost baix**, no funcionalitat avançada.

## 2. Model de dades i seguretat

- Entitat per emmagatzemar la connexió d'un tenant amb el seu proveïdor de facturació triat (tipus de proveïdor, credencials/tokens xifrats, estat de la connexió).
- Entitat de "factura sincronitzada" (referència externa, estat, import, data, client/servei associat del nostre sistema), diferenciada clarament d'un registre de facturació legal — és una **còpia de lectura** amb finalitat de visibilitat interna, no el document legal.
- Com es vincula una factura sincronitzada amb l'esdeveniment de "servei completat" ja identificat al mòdul de reviews, per tancar el cercle (servei fet → factura emesa via el proveïdor → visible al dashboard de tresoreria).
- Qui, dins el tenant, pot connectar/desconnectar el proveïdor extern i veure les dades de facturació (permís restrictiu, reutilitzant el sistema de permisos granulars ja dissenyat, no un rol nou).

## 3. Gestió de múltiples proveïdors (no acoblar-se només a Holded)

Encara que Holded sigui la primera opció prevista, dissenya la integració amb una capa d'abstracció (un "adaptador" per proveïdor) perquè afegir l'eina AEAT o un altre proveïdor certificat en el futur no obligui a refer la integració des de zero. No sobredimensionis això: n'hi ha prou amb una interfície comuna clara, no cal un sistema de plugins complex per a només dos o tres proveïdors previstos.

## 4. Comunicació clara del límit de responsabilitat a l'usuari

Especifica com es comunica al tenant, dins la mateixa interfície, que **qui emet i certifica legalment la factura és el proveïdor extern connectat**, no la nostra app — perquè no hi hagi confusió sobre qui és responsable en cas d'inspecció d'Hisenda.

## Format de resposta

Pla per fases (tantes com calguin). Comença explícitament amb els resultats de la recerca externa sobre Holded i l'eina AEAT abans de proposar cap arquitectura, ja que la viabilitat real de cada patró (A/B/C) depèn directament d'això. Si alguna de les dues eines no té API real disponible avui, digues-ho clarament i ajusta la recomanació en conseqüència en lloc de proposar una integració que no és tècnicament possible ara mateix.