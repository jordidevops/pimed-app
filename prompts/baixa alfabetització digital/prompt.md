# Prompt: Estudi d'accés per a treballadors amb baixa alfabetització digital i barrera idiomàtica

Actua com el mateix Principal Engineer que ha treballat en els mòduls de Qualitat ISO, Transparència Retributiva i Accessibilitat/Discapacitat/RGPD d'aquesta app. Mateix mètode: auditoria del codi real primer, decisions amb criteris explícits després, pla al final.

## Distinció important respecte al prompt d'Accessibilitat anterior

Aquest encàrrec **no és el mateix problema** que l'accessibilitat WCAG/legal ja estudiada (Ley 11/2023, discapacitat). Aquí el problema no és una discapacitat reconeguda, és:

- **Baixa alfabetització digital**: treballadors que no han fet servir mai (o gairebé) apps de gestió, formularis web, o interfícies amb menús/pestanyes.
- **Barrera idiomàtica**: castellà o català no és la seva primera llengua, i sovint no hi ha temps ni pressupost per traduir tota la interfície a totes les llengües que puguin parlar.
- **Context d'ús**: sovint personal de construcció, hostaleria o comerç, que treballa des del mòbil personal, potser amb connectivitat dolenta (obra, magatzem, exterior), i que no s'asseu mai davant d'un ordinador durant la jornada.

No barregis aquest disseny amb el d'accessibilitat per discapacitat, encara que alguns principis (llenguatge senzill, menys passos, contrast) se solapin. El públic objectiu i les solucions tècniques són diferents (aquí el problema clau és **canal d'accés i idioma**, no adaptació d'interfície per a lectors de pantalla).

## FASE 0 (obligatòria): Auditoria del codi actual

- Quin suport d'internacionalització (i18n) existeix avui a l'app: llengües disponibles, com es gestionen les traduccions (fitxers estàtics, servei extern, generades manualment), i qui les manté al dia quan hi ha canvis de producte.
- Quines funcionalitats fa servir avui un empleat de base (no gestor): fitxatge/registre horari, assignació de tasques, comunicació d'incidències, signatura/acceptació de procediments. Identifica-les totes, ja que són el punt de partida real del que cal simplificar.
- Si existeix ja alguna app mòbil nativa, PWA, o només interfície web responsive. Confirma el comportament en condicions de connectivitat dolenta o intermitent (hi ha cap mecanisme de treball offline o de reintent, o tot falla si no hi ha xarxa?).
- Si hi ha ja alguna integració amb canals externs de missatgeria (WhatsApp, SMS, email transaccional) per a qualsevol flux.

## Context legal rellevant (no és el focus principal, però condiciona el disseny)

El registre horari (fitxatge) és obligatori per llei a Espanya per a tots els treballadors, independentment del seu nivell d'alfabetització digital. Si una part de la plantilla no pot fer servir el sistema perquè la interfície els resulta inaccessible, l'empresa pot acabar recorrent a mètodes en paper no fiables, que és exactament el risc legal que el registre horari digital hauria d'eliminar. Aquest argument s'ha d'incloure com a justificació de negoci del disseny, no com una anàlisi legal detallada (això ja es cobreix en altres mòduls).

## 1. Decisió de canal d'accés

Analitza, amb criteris explícits (cost, fiabilitat, privacitat, esforç d'implementació, adequació a baixa alfabetització), com a mínim aquestes opcions, i recomana'n una o una combinació:

- **WhatsApp Business API** com a canal principal per a fitxatge, notificació d'incidències i recepció d'avisos, aprofitant que és l'app que aquest col·lectiu ja sap fer servir. Analitza també la implicació RGPD de dependre d'un tercer (Meta) com a encarregat del tractament per a comunicacions que poden incloure dades laborals, i si cal un contracte d'encarregat de tractament específic.
- **IVR / veu** (trucada o missatge de veu) per a treballadors amb dificultats de lectura, especialment per a comunicació d'incidències de seguretat.
- **PWA minimalista offline-first**, pensada per a un únic flux (fitxar entrada/sortida, reportar incidència) amb el mínim de passos possible, sense necessitat d'aprendre navegació complexa.
- **SMS** com a xarxa de seguretat quan no hi ha ni dades mòbils ni WhatsApp disponible.

## 2. Traducció i idioma

No proposis "traduir la interfície a X idiomes" com a única solució (no escala: sempre faltarà un idioma). Estudia:

- Traducció dinàmica assistida per IA dels textos que l'empleat ha de llegir/signar (procediments, avisos, missatges d'incidència), mantenint sempre l'original en la llengua legal de referència (castellà/català) com a versió vinculant, i la traducció com a suport de comprensió.
- Ús de pictogrames/icones i missatges de veu com a alternativa a text traduït per a les accions més freqüents (fitxar, reportar).
- Com es garanteix que una traducció automàtica d'un procediment de seguretat no indueixi a error (risc real si es tradueix malament una instrucció de seguretat) — proposa un mecanisme de revisió o d'avís que és una traducció assistida, no oficial.

## 3. Disseny d'interacció mínima

- Defineix el disseny d'un flux de fitxatge o de reportar incidència reduït al mínim absolut de passos i sense dependre de saber navegar per menús (per exemple, un únic missatge o botó, no un formulari).
- Especifica com s'autentica aquest usuari de manera prou segura sense dependre d'una contrasenya que oblidarà o no sabrà gestionar (codi PIN curt, verificació per número de mòbil, biometria del dispositiu).

## 4. Impacte en el model de dades i integracions

- Com s'enllaça un missatge rebut per WhatsApp/SMS/veu amb l'`employee` corresponent i amb el registre horari o d'incidències ja existent, sense duplicar lògica de negoci (el canal és una entrada nova, no un sistema paral·lel).
- Quina infraestructura d'integració (webhook, cua de missatges) cal per rebre i processar missatges entrants d'aquests canals.

## Format de resposta

Pla per fases (tantes com calguin). Per a cada fase, objectiu, decisió tècnica concreta i criteri de "fet". Si alguna decisió (per exemple, contractar WhatsApp Business API) implica un cost recurrent o un contracte amb un tercer, marca-ho explícitament com a decisió de negoci pendent, no la donis per aprovada.