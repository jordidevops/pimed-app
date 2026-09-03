# Prompt: Estudi d'Accessibilitat, Discapacitat Laboral i RGPD

Actua com el mateix Principal Engineer que ha treballat en els mòduls de Qualitat ISO i Transparència Retributiva d'aquesta app. Mateix mètode: primer auditoria del codi real, després decisions amb criteris explícits, i només al final un pla d'implementació.

**Important abans de començar**: aquest encàrrec conté **tres coses diferents que no s'han de barrejar** perquè tenen naturalesa i abast diferents. Tracta-les com a blocs separats, encara que al final es puguin planificar juntes:

- **(A) Que l'app en si mateixa sigui accessible** (accessibilitat digital pròpia — afecta el vostre frontend, no és una funcionalitat per al tenant).
- **(B) Ajudar el tenant a complir les seves obligacions com a empresari respecte a treballadors amb discapacitat** (quota de reserva, mesures alternatives, bonificacions de Seguretat Social).
- **(C) Com es tracten al sistema les dades de discapacitat/salut**, que són una categoria especial de dades segons l'RGPD i requereixen un tractament diferent de qualsevol altra dada que ja gestioneu (inclosa la retributiva).

## Context legal (marc, verifica sempre l'estat actualitzat abans de donar per definitiva cap xifra)

**(A) Accessibilitat digital de l'aplicació:**
La Ley 11/2023, que transposa la Directiva (UE) 2019/882 (European Accessibility Act), <cite index="22-1">juntament amb el Real Decreto 193/2023, és en vigor des del 28 de juny de 2025 per a productes i serveis digitals nous.</cite> <cite index="21-1">Els nous productes/serveis han de complir WCAG (2.1 AA com a base, segons UNE-EN 301 549); els que ja existien al mercat tenen de marge fins al 2030,</cite> però com que aquesta app es manté en desenvolupament actiu, qualsevol funcionalitat nova hauria de tractar-se com a "nova" a efectes pràctics. <cite index="27-1">Els incompliments es qualifiquen com a lleus, greus o molt greus, amb multes de 301€ fins a 1.000.000€.</cite> Això no és un mòdul per al tenant — és una exigència sobre el vostre propi codi de frontend.

**(B) Quota de reserva i mesures alternatives:**
<cite index="30-1">Segons l'article 42.1 de la Ley General de los Derechos de las Personas con Discapacidad (Real Decreto Legislativo 1/2013), les empreses de 50 o més treballadors han de tenir com a mínim el 2% de la plantilla amb certificat de discapacitat (grau igual o superior al 33%).</cite> <cite index="36-1">Per exemple: de 50 a 99 treballadors, 1 lloc reservat; de 100 a 149, 2; i així successivament.</cite> Les empreses que no arribin a la quota poden sol·licitar una **declaració d'excepcionalitat** i aplicar **mesures alternatives** (contractació mercantil amb Centres Especials d'Ocupació, donacions, etc.) regulades pel RD 364/2005.

**(C) RGPD/LOPDGDD:**
La dada de discapacitat (i, en general, qualsevol dada de salut, com les que apareixeran també en un futur mòdul de Seguretat i Salut en el Treball / ISO 45001) és una **categoria especial de dades (article 9 RGPD)**: requereix base jurídica específica (no n'hi ha prou amb l'interès legítim genèric), minimització, i mesures de seguretat reforçades, més restrictives que les que ja heu dissenyat per a dades retributives.

## FASE 0 (obligatòria): Auditoria del codi actual

- **Per al bloc (A)**: audita el frontend actual (components, ús de HTML semàntic, atributs ARIA, navegació per teclat, contrast de color, formularis) i digues, honestament, en quin punt de partida esteu — no assumeixis que ja compliu res. Si feu servir un sistema de components/design system, indica si ja incorpora consideracions d'accessibilitat o s'ha de revisar component a component.
- **Per als blocs (B) i (C)**: reutilitza el que ja vas trobar (o no trobar) al mòdul de Transparència Retributiva sobre el model d'`employees`. Confirma si ja existeix algun camp relacionat amb discapacitat, salut, o categoria especial de dades, i si el sistema té avui **algun** mecanisme per marcar una dada com a "categoria especial" amb tractament diferenciat, o si tot es guarda igual que qualsevol altra dada de RRHH.
- Confirma si ja existeix (del mòdul de Transparència Retributiva) un mecanisme de recompte de plantilla per tenant, reutilitzable aquí per calcular la quota de reserva del 2%.

## 1. Bloc (A): Pla d'accessibilitat digital pròpia

No és un mòdul de negoci, és una disciplina d'enginyeria transversal. Defineix:

- Com s'audita l'estat actual (eines automàtiques + revisió manual) i quin nivell de conformitat (WCAG 2.1 AA com a mínim) es fixa com a objectiu.
- Com s'evita regressió: integració de comprovacions d'accessibilitat al procés de desenvolupament (linting, tests automatitzats, revisió de components nous), no una auditoria puntual que caduca l'endemà.
- Si cal publicar una **declaració d'accessibilitat** pública (pràctica habitual i sovint exigida en aquest tipus de normativa) i on encaixaria dins l'app.

## 2. Bloc (B): Model de dades i seguiment de la quota de reserva

- Entitat per registrar el certificat de discapacitat d'un empleat (grau, data de reconeixement, vigència) — vinculada a `employees`.
- Càlcul automàtic de la quota exigida segons plantilla del tenant (reutilitzant el recompte ja identificat) i seguiment de si es compleix.
- Registre de mesures alternatives aplicades (tipus, entitat/CEE amb qui es contracta, import, vigència) i de la declaració d'excepcionalitat, per si el tenant opta per aquesta via en lloc de contractació directa.
- Seguiment de bonificacions/reduccions de quota de la Seguretat Social associades a la contractació de persones amb discapacitat (tipus de contracte, període de bonificació, alertes de venciment).

## 3. Bloc (C): Tractament de dades de categoria especial (disseny reutilitzable, no ad-hoc)

Aquest és el punt que vull que resolguis amb més cura, perquè no és només d'aquest mòdul: també l'haureu de fer servir per a dades de salut en Seguretat i Salut en el Treball (ISO 45001) en el futur.

- Dissenya un mecanisme **genèric** per marcar i protegir "dades de categoria especial" (permisos encara més restrictius que els dissenyats per a retribució, base jurídica registrada per a cada dada d'aquest tipus, registre d'accessos).
- Especifica quina base jurídica es fa servir per emmagatzemar la dada de discapacitat (normalment obligació legal de l'ocupador per complint la quota, no consentiment: aclareix-ho i documenta-ho al disseny perquè no depengui d'un consentiment revocable per a una obligació legal).
- Defineix si aquesta dada necessita xifratge específic a nivell d'emmagatzematge, més enllà del que ja teniu per a la resta de dades.

## Format de resposta

Respon per blocs (A, B, C) diferenciats, cadascun amb el seu propi pla de fases (tantes com calguin). Indica explícitament qualsevol reutilització o dependència amb el que ja es va dissenyar al mòdul de Transparència Retributiva, per no duplicar feina d'infraestructura de RRHH bàsica.