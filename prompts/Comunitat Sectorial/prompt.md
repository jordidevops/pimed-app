# Prompt: Estudi de Comunitat Sectorial i Biblioteca Compartida entre Tenants

Actua com el mateix Principal Engineer que ha treballat en els mòduls anteriors d'aquesta app. Mateix mètode: auditoria del codi real primer, decisions amb criteris explícits després, pla al final.

## La tensió central d'aquest mòdul (llegeix-ho abans de dissenyar res)

Tot el que s'ha construït fins ara a l'app parteix d'un principi no negociable: **aïllament estricte de dades entre tenants**. Aquest mòdul és el primer que trenca aquest principi **de manera deliberada i controlada**: l'objectiu és que tenants d'un mateix sector/arquetip puguin veure contingut d'altres tenants (consells, plantilles) que ells mateixos han decidit compartir. Això no és un relaxament accidental de l'aïllament, és una **superfície nova i explícita de dades compartides**, que ha de conviure sense contaminar mai la resta del sistema (que segueix sent estrictament privat per tenant). Qualsevol disseny que faci "una mica pública" una taula que avui és privada per defecte és un error greu — la publicació ha de ser sempre un acte explícit i deliberat del tenant, mai una exposició per omissió.

## Dos blocs diferents, no un de sol

- **(1) Comunitat/fòrum sectorial**: preguntes, consells, ajuda mútua entre tenants del mateix sector, tant sobre com fer la seva feina (el seu ofici) com sobre com fer servir l'app.
- **(2) Biblioteca compartida de recursos**: plantilles de documents, checklists, models de pressupostos, contractes, butlletins/albarans i articles de magatzem que un tenant decideix compartir amb el seu sector.

Tracta'ls per separat, encara que comparteixin la mateixa base d'agrupació per "vertical/arquetip" i el mateix criteri de moderació. El (2) és una extensió natural del sistema de plantilles i gestió documental ja existent; el (1) és una funcionalitat nova de tipus fòrum/comunitat que no té equivalent actual al codi.

## FASE 0 (obligatòria): Auditoria del codi actual

- **Existeix ja algun concepte de "vertical", "sector" o "arquetip" de tenant** al model de dades? Si no existeix, cal crear una taxonomia (encara que sigui bàsica al principi) com a prerequisit de tot el mòdul.
- **Sistema de plantilles i gestió documental** ja construït (el que la plataforma ofereix per clonar, i el versioning de documents): confirma si es pot reutilitzar l'estructura per al bloc (2), afegint-hi un nivell nou "compartit entre tenants del mateix sector" a més dels nivells ja existents (plantilla oficial de la plataforma / document privat del tenant).
- **Existeix avui alguna superfície de l'app que ja llegeixi dades entre tenants** (encara que sigui d'administració interna)? Si la resposta és no, confirma-ho explícitament, perquè significa que cal dissenyar tota la capa d'accés entre tenants des de zero, amb molta cura de no reutilitzar per error patrons d'RLS pensats per a dades sempre privades.

## 1. Agrupació per vertical/arquetip

- Com es classifica un tenant dins un vertical (selecció manual a l'onboarding, o classificació posterior). Si cal, un tenant pot pertànyer a més d'un vertical?
- Com es decideix qui veu què: tots els tenants del mateix vertical veuen tot el contingut compartit d'aquell vertical, o hi ha subgrups (per exemple, per zona geogràfica) per evitar que contingut massa genèric o massa irrellevant satururi tenants amb realitats molt diferents dins del mateix vertical ampli.

## 2. Bloc (1): Comunitat/fòrum

- Model bàsic de contingut (preguntes/respostes, o publicacions lliures amb comentaris) — recomana el més senzill que resolgui el cas d'ús, no un fòrum complet amb totes les funcionalitats típiques de dia u.
- **Identitat de qui publica**: amb nom del tenant/persona (construeix reputació, i podria enllaçar-se en el futur amb el sistema de confiança ja dissenyat per a reviews), o amb pseudònim (facilita que algú es queixi amb franquesa d'una funcionalitat de l'app o comparteixi un dubte sense exposar el seu negoci). Recomana quina opció (o si totes dues, diferenciant contingut "sobre el meu ofici" de contingut "sobre l'app") té més sentit.
- Separa explícitament, encara que visualment puguin conviure al mateix espai, els temes **sobre l'ofici del sector** (útil per a l'equip de producte només com a senyal indirecte) dels temes **sobre l'app mateixa** (útils com a canal real de feedback de producte — val la pena que aquests arribin d'alguna manera a l'equip, no que quedin només enterrats en un fòrum).

## 3. Bloc (2): Biblioteca compartida de recursos

- Flux de "promoure" un document/plantilla privat del tenant a compartit: qui ho pot fer (permís restrictiu dins el sistema de permisos ja existent), i si passa per algun tipus de revisió abans de fer-se visible a la resta del sector.
- **El punt més crític d'aquest bloc, resol-lo amb el mateix rigor que altres punts sensibles ja tractats en mòduls anteriors**: molts dels documents esmentats (pressupostos, contractes, albarans) **contindran per naturalesa dades reals de clients del tenant que els comparteix** (noms, preus pactats, adreces). Cal un mecanisme, no només una recomanació, que ajudi a detectar i eliminar aquesta informació abans de publicar-la (per exemple, detecció automàtica de patrons de dades personals/comercials al contingut abans de permetre la publicació, amb avís explícit al tenant que ho comparteix). No n'hi ha prou amb confiar que el tenant ho farà bé manualment.
- Llicència d'ús del contingut compartit: què pot fer un altre tenant amb una plantilla que ha rebut (editar-la lliurement dins la plataforma, sí; revendre-la o exportar-la fora, no) — deixa-ho definit encara que sigui de manera senzilla.
- Reutilització de l'estructura de versioning ja existent perquè una plantilla compartida i després actualitzada pel seu autor pugui notificar (opcionalment) els tenants que ja la fan servir.

## 4. Moderació (dimensiona-la al que és realista per a un equip petit)

- Mecanisme mínim de denúncia/reportar contingut inapropiat, spam, o competència deslleial dins del fòrum.
- No proposis un sistema complex de moderació automàtica de dia u; defineix el mínim viable (revisió manual per l'equip + límits de freqüència de publicació) i deixa la moderació automatitzada més sofisticada com a millora futura si el volum ho justifica.

## 5. Permisos

- Qui dins d'un tenant pot publicar al fòrum o promoure contingut a la biblioteca compartida (probablement un permís concret dins el sistema granular ja existent, no un rol nou — mantén la coherència amb la resta de mòduls).
- Confirma que la lectura del contingut compartit no requereix cap permís especial més enllà de pertànyer a un tenant actiu del vertical corresponent.

## Format de resposta

Pla per fases (tantes com calguin), amb els blocs (1) i (2) diferenciats. Marca com a prerequisit explícit la taxonomia de verticals/arquetips si no existeix avui, ja que sense això no es pot començar cap dels dos blocs. Assenyala explícitament a cada fase si es toca la capa de dades compartides entre tenants, perquè aquesta és la part que exigeix més revisió de seguretat abans de donar-la per tancada.