# Canal de denúncies

El **canal de denúncies** (també anomenat **canal intern d'informació**) és un mecanisme perquè treballadors i, en alguns casos, altres persones relacionades amb l'empresa (proveïdors, autònoms, candidats, etc.) puguin comunicar de manera confidencial possibles infraccions o irregularitats.

És una mesura de **compliment normatiu (compliance)**, no un sistema de queixes comercials ni d'atenció al client.

---

# Per què existeix?

El seu objectiu és que qualsevol persona pugui informar sobre situacions com:

* corrupció
* frau
* assetjament laboral
* assetjament sexual
* discriminació
* conflictes d'interès
* incompliments normatius
* delictes econòmics
* vulneracions del codi ètic
* altres irregularitats greus

L'empresa ha de gestionar aquestes comunicacions amb garanties de confidencialitat i, quan sigui possible, protegint la persona informant davant de represàlies.

---

# Quan és obligatori?

De manera simplificada a Espanya:

* Empreses de **50 o més treballadors** han de disposar d'un canal intern d'informació.
* També hi ha organitzacions i sectors regulats que poden estar obligats encara que tinguin menys de 50 treballadors.

Per això, la vostra plataforma hauria de mostrar un missatge com:

> Segons la mida i l'activitat de l'empresa, revisa si has d'implantar un canal intern d'informació.

I evitar afirmar que és obligatori sense conèixer totes les circumstàncies.

---

# Què no és?

Molta gent ho confon amb:

❌ Bústia de suggeriments

❌ Formulari de contacte

❌ Servei d'atenció al client

❌ Gestor de reclamacions

És un procediment legal amb requisits específics.

---

# Com pot ajudar la vostra plataforma?

Aquí hi ha diverses opcions.

## Opció 1. Només ajudar a implantar-lo (la que recomanaria inicialment)

La plataforma podria:

* detectar que probablement aplica;
* generar la política del canal;
* generar el procediment intern;
* generar els nomenaments dels responsables;
* recordar les revisions;
* indicar serveis externs compatibles.

És la solució amb menys responsabilitat jurídica.

---

## Opció 2. Oferir el canal complet

La vostra aplicació podria incorporar un mòdul específic.

Per exemple.

```
Canal intern d'informació

Nova comunicació

Categoria

○ Assetjament

○ Frau

○ Compliment normatiu

○ Conflicte d'interès

○ Altres

Es permet l'anonimat? (segons la configuració)

Adjuntar proves

Enviar
```

Després hi hauria un gestor intern.

```
Cas #2026-004

Estat

Investigació

Responsable

...

Data límit

...

Documents

...

Historial
```

Aquesta opció és molt més complexa perquè implica gestionar terminis, confidencialitat, permisos molt restrictius, conservació de la informació i altres obligacions procedimentals.

---

# El DMS hi encaixa perfectament

Ja teniu un generador documental.

Podeu generar:

* Política del canal intern.
* Procediment de gestió.
* Nomenament del responsable.
* Actes d'investigació.
* Informe final.
* Resolució.
* Registre d'actuacions.

Això és molt útil per a assessories.

---

# El Portal del Treballador

Com que ja teniu RRHH, el Portal del Treballador podria tenir:

```
Compliment

Canal intern d'informació

Vols comunicar una possible irregularitat?

[Accedir]
```

Sense haver de buscar un correu electrònic.

---

# Automatitzacions

Quan el tenant arriba a 50 treballadors.

La plataforma podria crear automàticament una tasca:

```
Revisar obligació d'implantar un canal intern d'informació.
```

No afirmar que és obligatori.

Només avisar.

---

# Web pública

Si el tenant genera una web amb la vostra plataforma.

Podria afegir:

```
/whistleblowing

o

/canal-intern
```

Accessible des de l'exterior.

En alguns casos és útil perquè també puguin comunicar incidències altres persones relacionades amb l'empresa, com proveïdors o col·laboradors.

---

# El que probablement faria jo

No començaria desenvolupant un sistema complet de denúncies. En canvi, ho estructuraria en tres nivells de maduresa:

### Nivell 1 – Preparació (MVP)

* Detectar quan probablement aplica.
* Generar tota la documentació necessària.
* Checklist d'implantació.
* Recordatoris.

### Nivell 2 – Integració

* Enllaçar amb una solució especialitzada externa si el client ja en té una.
* Registrar que el canal està implantat.
* Mantenir la documentació i les evidències.

### Nivell 3 – Mòdul propi

Només quan la plataforma estigui madura.

Inclouria:

* recepció de comunicacions;
* expedients;
* permisos molt granulars;
* anonimat (si es configura);
* terminis;
* evidències;
* traçabilitat completa;
* notificacions;
* informes.

---

## Des del punt de vista de producte

Aquesta funcionalitat encaixa molt bé dins del que abans comentàvem com a **Centre de Governança Empresarial** o **Centre de Compliment**, però la tractaria com un **mòdul premium**. La majoria de microempreses no el necessitaran immediatament, mentre que per a empreses que superin determinats llindars de plantilla o operin en sectors regulats pot ser un element molt valuós.

A més, és una funcionalitat que pot interessar especialment a **assessories, consultores de compliance, despatxos laboralistes i vivers d'empreses**, perquè els permet oferir als seus clients una solució integrada, amb documentació, seguiment i, eventualment, un canal operatiu, tot dins de la mateixa plataforma que ja utilitzen per gestionar el dia a dia.
