# Prompt: Estudi tècnic de Reviews Verificades, Perfil Públic del Tenant i Motor de Referral

Actua com el mateix Principal Engineer que ha treballat en els mòduls anteriors d'aquesta app. Mateix mètode: auditoria del codi real primer, decisions amb criteris explícits després, pla al final.

## Abast d'aquest encàrrec

Aquest prompt cobreix **dos blocs estretament lligats** que s'han de dissenyar junts, i **un tercer bloc separat** que s'ha d'estudiar independentment perquè és conceptualment diferent:

- **(1) Reviews de clients verificades**: un client només pot deixar una review vinculada a un servei/projecte real i tancat dins l'app, no una review oberta i anònima.
- **(2) Perfil públic del tenant**: una pàgina pública, generada automàticament, que mostra les reviews verificades i indicadors de confiança del tenant, pensada com a eina de captació.
- **(3, ESTUDI SEPARAT) Motor de referral entre clients propis**: un tenant convida els seus clients a recomanar-ne de nous, amb seguiment i possible incentiu.

**Descartat explícitament, no ho analitzis ni ho proposis**: cap directori públic multi-tenant ni marketplace de cerca entre els diferents clients de la plataforma. El perfil públic (2) és només del tenant individual, no un cercador global.

## Context legal (verifica sempre l'estat actualitzat; el bloc (3) hi té una implicació que sovint es passa per alt)

- El RDL 24/2021 (transposició de la Directiva UE 2019/2161) <cite index="51-1">obliga qualsevol empresa que ofereixi accés a reviews de consumidors a aclarir si garanteix que aquestes reviews han estat fetes realment per clients que han adquirit el bé o servei.</cite>
- La mateixa normativa <cite index="48-1">imposa també l'obligació d'indicar si les reviews han estat incentivades amb descomptes o altres beneficis,</cite> amb sancions <cite index="48-1">que poden arribar a un milió d'euros o el 4% de la facturació de l'empresa infractora.</cite> **Això afecta directament el bloc (3)**: si en algun moment un incentiu de referral s'acaba lligant a deixar una review (i no només a portar un client nou), aquella review passa a ser "incentivada" i s'ha de marcar com a tal. Cal que el disseny distingeixi clarament un referral (portar client nou) d'un incentiu per review, perquè no acabin barrejats sense voler.
- <cite index="46-1">La Ley de Servicios de Atención a la Clientela, aprovada pel Congrés el 13 de novembre de 2025 i pendent de ratificació final,</cite> introduirà <cite index="46-1">l'obligació de sistemes de verificació d'usuaris i un termini de 30 dies per revisar denúncies sobre reviews.</cite> Dissenya el flux de moderació/disputa tenint-ho en compte, encara que la llei no estigui 100% en vigor.

## FASE 0 (obligatòria): Auditoria del codi actual

- **Moment de "servei completat"**: identifica quina entitat i quin esdeveniment del sistema actual marca que un treball per a un client ha finalitzat (tancament d'un projecte, una tasca marcada com a feta, una factura marcada com a pagada, o cap d'aquestes si no existeix encara un concepte de "client" al model de dades). Això és crític: si no hi ha cap concepte de client/projecte client actual, digues-ho explícitament perquè canvia l'abast.
- **Existeix ja algun concepte de "client" del tenant** dins l'app (diferent del tenant mateix), amb dades de contacte (email, telèfon)? Si no, cal crear-lo com a prerequisit.
- **Capacitat de servir pàgines públiques**: confirma si l'arquitectura actual permet servir contingut no autenticat (una ruta pública) amb el mateix desplegament, o si això requereix una superfície nova (subdomini per tenant, aplicació separada). Revisa com es gestionen avui els dominis/subdominis per tenant, si n'hi ha.
- **Sistema d'enviament d'email/notificació existent**, reutilitzable per enviar la sol·licitud de review al client.

## 1. Bloc (1): Flux de sol·licitud i verificació de reviews

- Com es dispara la sol·licitud de review: automàticament quan es marca l'esdeveniment de "servei completat" identificat a la Fase 0, o manualment pel tenant.
- Mecanisme d'accés del client per deixar la review: recomana explícitament si cal un compte complet o n'hi ha prou amb un **enllaç d'un sol ús, temporal i vinculat a l'identificador del servei concret** (patró similar als tokens d'invitació ja dissenyats en altres mòduls), que és el que garanteix la verificació legal sense fricció per al client.
- Com queda enllaçada de manera immutable la review amb el registre del servei/projecte que la origina (perquè la verificació sigui demostrable si mai es qüestiona).
- Flux de resposta pública del tenant a una review i flux de disputa/denúncia (termini de 30 dies), incloent qui té permís intern per gestionar-ho (probablement un permís nou dins el sistema de permisos granulars ja existent, no un rol nou).

## 2. Bloc (2): Perfil públic del tenant

- Estructura de la pàgina pública (ruta pròpia dins el domini principal vs. subdomini per tenant) i implicacions de rendiment/cache, ja que és trànsit no autenticat i potencialment indexable per cercadors (SEO).
- Contingut que mostra: reviews verificades, mitjana, nombre de serveis completats. Deixa un punt d'extensió clar (no el dissenyis ara) per incorporar-hi més endavant indicadors d'altres mòduls ja construïts (per exemple, un futur "score de confiança" combinat), sense acoblar-hi ara la lògica d'aquells mòduls.
- Configuració per tenant: activar/desactivar el perfil públic, triar quina informació es mostra.
- Idioma de la pàgina pública: si cal contemplar-ho des d'ara donat que és cara al públic, o es deixa per a una iteració posterior (decisió, no obligació).

## 3. ESTUDI SEPARAT — Bloc (3): Motor de referral entre clients propis

Tracta aquest bloc de manera independent, amb el seu propi mini-pla de fases. No l'acoblis a la infraestructura de reviews del bloc (1) més enllà del que calgui per evitar duplicar el concepte de "client":

- Model de dades: codi de referral per client, seguiment de qui ha estat referit per qui, estat (pendent, convertit en client, recompensat).
- Tipus d'incentiu (descompte, comissió) i com es marca i es paga/aplica — sense assumir que existeix ja facturació automatitzada; confirma-ho a la Fase 0 si no s'ha fet abans.
- **Punt de control explícit**: si el disseny permet que un incentiu de referral depengui, encara que sigui parcialment, de deixar una review, marca-ho com a disseny prohibit o com a cas que obliga a activar la marca "review incentivada" del bloc (1). No barregis els dos incentius sota el mateix mecanisme sense aquest control.

## Format de resposta

Pla per fases per als blocs (1)+(2) junts, i un pla per fases separat per al bloc (3), cadascun amb el seu propi criteri de "fet". Si detectes que calen entitats prèvies que no existeixen avui (concepte de client, esdeveniment de servei completat), marca-ho com a prerequisit explícit abans de la Fase 1 de qualsevol dels dos plans.