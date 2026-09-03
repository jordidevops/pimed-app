# Prompt: Estudi d'incorporació del mòdul de Transparència Retributiva

Actua com el mateix Principal Engineer que ha treballat en el Mòdul de Qualitat ISO d'aquesta app. Reutilitza el mateix mètode: primer auditoria del codi real, després decisions amb criteris explícits, i només al final un pla d'implementació. No proposis codi encara.

## Context legal (marc, no la implementació final)

La Directiva (UE) 2023/970 de transparència retributiva havia de transposar-se a l'ordenament espanyol com a molt tard el 7 de juny de 2026. **A data d'avui, Espanya encara no l'ha transposada**; el Ministeri de Treball segueix en fase d'adequació tècnica i el text definitiu del Reial Decret espanyol no existeix. Això vol dir que has de **dissenyar per als requisits coneguts de la Directiva de manera configurable**, no codificar regles rígides d'una norma espanyola que encara no existeix. Quan la transposició espanyola es publiqui, el sistema ha de poder-se ajustar per configuració, no per canvi d'esquema.

Elements coneguts de la Directiva que el disseny ha de contemplar (verifica sempre l'estat legal actualitzat abans d'assumir cap xifra o data com a definitiva, ja que pot haver canviat):

- Informació de banda salarial abans/durant el procés de selecció, i prohibició de preguntar l'historial retributiu al candidat.
- Dret de qualsevol treballador a sol·licitar i rebre, en un termini raonable i com a màxim dos mesos, informació sobre el seu nivell retributiu individual i els nivells mitjans retributius desglossats per sexe de categories que facin la mateixa feina o una d'igual valor.
- Obligacions de report periòdic sobre bretxa retributiva per a empreses per sobre de determinats llindars de plantilla, escalonades en el temps segons la mida.
- Avaluació retributiva conjunta obligatòria quan es detecta una bretxa no justificada superior al 5% i no es corregeix en sis mesos.
- Espanya ja té com a base el Real Decreto 902/2020 (registre retributiu i auditoria retributiva), que la nova norma reforça, no substitueix.

## FASE 0 (obligatòria): Auditoria del codi actual

No donis per fet res sobre el que ja existeix. Verifica al codi:

- **Existeix ja algun concepte de retribució/salari** al model de dades (camp a `employees`, mòdul de nòmines, integració externa amb una gestoria de nòmines)? Si no existeix cap dada salarial avui, digues-ho explícitament: és un gap de disseny des de zero, no una ampliació.
- **Categories professionals / llocs de treball**: existeix ja alguna estructura de "categoria", "lloc", "nivell" a `employees` o a un mòdul d'RRHH, necessària per agrupar "mateixa feina o d'igual valor"?
- **Recompte de plantilla per tenant**: hi ha ja una manera fiable de saber quants empleats actius té un tenant (necessari per aplicar els llindars de 100/150/250 treballadors)?
- **Sistema de permisos actual** (el mateix que vas auditar per al mòdul ISO): confirma si avui cap rol (`owner`/`manager`) té ja accés a dades sensibles de RRHH, i com està protegit.
- **Sistema de tickets/sol·licituds** ja existent a l'app (si n'hi ha algun de genèric, per exemple el motor de CAPA/no conformitats del mòdul de Qualitat) que es pugui reutilitzar per al flux de "sol·licitud d'informació retributiva amb SLA de 2 mesos", en comptes de construir-ne un de nou des de zero.

## 1. Sensibilitat i accés a la dada (el punt crític d'aquest mòdul)

La dada salarial individual és, amb diferència, la dada més sensible que gestionarà l'app fins ara — més que la documentació ISO. Resol amb el mateix rigor que vam exigir per a l'auditor extern:

- Quin rol/permís concret pot veure retribucions **individuals** (probablement ha de ser un permís propi i restrictiu, no heretat automàticament d'`owner` o `manager` per defecte, encara que aquests rols el puguin tenir assignat).
- Com es calculen i exposen **mitjanes agregades per categoria i sexe** sense exposar mai la dada individual a algú que només té dret a veure la mitjana (per exemple, quan un empleat sol·licita "el nivell mitjà retributiu de la meva categoria desglossat per sexe", el sistema li ha de poder respondre sense que ningú hagi de consultar manualment els salaris de tothom).
- Registre d'auditoria de qui ha consultat dades salarials individuals i quan (igual que vau exigir per a l'accés extern de l'auditor ISO).
- Si convé aïllar aquesta dada en un esquema/mòdul propi amb RLS específica encara més restrictiva que la resta de mòduls, o n'hi ha prou amb el sistema de permisos granulars ja dissenyat per a Qualitat.

## 2. Impacte en el model de dades

Determina quines entitats calen i com s'enllacen amb `employees` i amb la categorització professional existent (o la que calgui crear):

- Registre retributiu (retribució per empleat, categoria, període).
- Bandes salarials per lloc/categoria (per a ofertes de feina i per a l'obligació d'informar abans de contractar).
- Sol·licituds d'informació retributiva d'un empleat (amb data de sol·licitud, termini legal de resposta, data de resposta, resultat).
- Detecció i seguiment de bretxa retributiva no justificada (>5%) i el seu procés d'avaluació conjunta.
- Configuració per tenant dels llindars i obligacions aplicables segons plantilla (perquè quan es publiqui la norma espanyola definitiva, els llindars es puguin ajustar sense canvi d'esquema).

## 3. Funcionalitat diferencial: transparència voluntària anticipada

Independentment de si el tenant hi està obligat per mida, dissenya l'opció que un tenant **act1vi voluntàriament** la transparència retributiva (bandes salarials visibles en ofertes, informe de bretxa públic) com a eina de marca ocupadora, abans que la llei l'hi obligui. Especifica:

- Com es marca un tenant com a "transparència activada voluntàriament" davant d'"obligat per llei".
- Què es fa visible externament (per exemple, en una pàgina pública de l'empresa o en integració amb un mòdul d'ofertes de feina, si existeix) i què es queda intern.

## 4. Pla d'execució

Divideix-ho en tantes fases com calgui (no hi ha un nombre fixat). Per a cada fase, indica objectiu, entitats/fitxers principals i criteri de "fet". Si detectes que aquest mòdul depèn de decisions o entitats que hauria de resoldre abans un mòdul d'RRHH més bàsic (que potser encara no existeix), digues-ho explícitament com a prerequisit en comptes d'assumir que ja hi és.

## Format de resposta

Respon únicament amb el pla. Si el codi actual no té cap base d'RRHH/retribució (és a dir, si aquest mòdul parteix de zero i no d'una ampliació), digues-m'ho clarament al principi de la resposta, perquè això canvia l'abast real de la feina respecte als altres mòduls que ja hem planificat.