Les **obligacions fiscals** són totes les declaracions, pagaments, llibres registre i comunicacions que una empresa o un autònom ha de presentar davant de l'Administració tributària al llarg de l'any.

Per a la vostra plataforma és un dels àmbits més interessants perquè **no cal fer la comptabilitat ni presentar impostos** per aportar molt valor. Podeu convertir-vos en el sistema que recorda, organitza i prepara la informació.

---

# Un exemple

Un autònom crea una empresa a la vostra plataforma.

Durant els primers mesos no sap:

* quins impostos ha de presentar;
* quan els ha de presentar;
* què necessita per preparar-los.

La plataforma podria mostrar:

```text
Aquestes són les obligacions que probablement s'apliquen a la teva empresa.

✔ IVA trimestral

✔ Retencions

✔ Resum anual

✔ Declaració censal

...
```

No diu:

> Has de presentar això.

Sinó:

> Revisa aquestes obligacions amb la teva assessoria.

---

# Quines obligacions existeixen?

Depèn de molts factors.

Per exemple:

* forma jurídica;
* règim fiscal;
* activitat;
* si té treballadors;
* si fa importacions;
* si factura a altres països;
* etc.

Per això la plataforma hauria de calcular-les a partir del perfil del tenant.

---

# Què pot fer la vostra plataforma?

## 1. Perfil fiscal

Quan es crea el tenant.

Es pregunta:

* És autònom o societat?
* Té treballadors?
* Està subjecte a IVA?
* Té recàrrec d'equivalència?
* Exporta?
* Importa?
* Factura a la UE?

A partir d'aquí.

Es genera una llista de possibles obligacions.

---

## 2. Calendari fiscal

Aquest és probablement el més útil.

Per exemple.

```text
Agost

No hi ha obligacions

Octubre

IVA

Retencions

Pagament fraccionat

Gener

Resums anuals

...
```

Amb notificacions.

---

## 3. Preparació de documentació

No cal presentar els impostos.

Només preparar.

Per exemple.

La plataforma ja coneix:

* factures
* despeses
* clients
* proveïdors

Pot generar:

* informes
* exportacions
* resums

Per a l'assessoria.

---

## 4. Estat de preparació

```text
IVA 3T

Factures emeses

✔

Factures rebudes

✔

Despeses pendents

2

Tot preparat

95%
```

Això ajuda molt.

---

## 5. DMS

Guardar:

* declaracions presentades;
* justificants;
* cartes d'Hisenda;
* certificats;
* notificacions;
* models signats.

Tot centralitzat.

---

## 6. Automatitzacions

15 dies abans.

Crear tasca.

Avisar.

Compartir documentació amb l'assessoria.

---

# Integració amb altres mòduls

## Facturació

Ja teniu:

* clients;
* pressupostos;
* factures.

Podeu calcular moltes dades.

---

## Despeses

Les despeses es relacionen automàticament.

---

## DMS

Guardar:

* models;
* justificants;
* notificacions;
* certificats.

---

## Portal de l'assessoria

L'assessoria podria veure.

```text
Empresa

IVA

Preparació

92%

Documentació pendent

2 factures
```

Sense haver de demanar-les per email.

---

# El que faria diferent

No crearia un mòdul anomenat:

> Fiscalitat

Crearia un:

## Centre Fiscal

Amb quatre blocs.

### Calendari

Properes obligacions.

---

### Preparació

Quina informació falta.

---

### Documentació

Tot ordenat.

---

### Estat

Percentatge de preparació.

---

# Una funcionalitat diferencial

La majoria dels programes només et recorden que arriba el dia 20.

Vosaltres podeu anar molt més enllà.

Per exemple.

```text
Falten 18 dies per a la liquidació trimestral.

Encara no has registrat:

• 3 factures de compra

• 1 abonament

• 2 justificants de despesa

Vols avisar la teva assessoria?
```

Això és molt més útil.

---

# Una altra idea molt potent

Si la vostra plataforma té un **portal per a assessories**, podríeu implementar un flux de treball col·laboratiu:

1. El client registra la seva activitat diària (factures, despeses, cobraments...).
2. La plataforma verifica si hi ha informació pendent o incoherent.
3. Quan tot està preparat, el client prem **"Enviar a l'assessoria"**.
4. L'assessoria rep tota la documentació estructurada, en lloc de rebre una carpeta plena de PDFs o fotografies.

Aquest flux redueix molt el temps administratiu i és un argument comercial molt fort davant de les assessories.

## La meva recomanació d'arquitectura

No intentaria substituir un programa de comptabilitat ni un programari de presentació d'impostos. És un àmbit molt regulat i amb canvis freqüents.

En canvi, crearia un **Centre Fiscal** orientat a la col·laboració, amb quatre pilars:

* **Coneixement**: identificar les obligacions que probablement són aplicables segons el perfil de l'empresa.
* **Preparació**: comprovar que la informació necessària està completa i coherent.
* **Documentació**: custodiar declaracions, justificants, notificacions i certificats al DMS.
* **Col·laboració**: facilitar l'intercanvi d'informació entre el tenant i la seva assessoria.

Aquesta aproximació és molt coherent amb la resta de la plataforma: no substituïu l'assessor fiscal, sinó que li doneu eines perquè treballi més eficientment i perquè l'empresa tingui una millor organització i menys risc d'oblidar obligacions o documentació.
