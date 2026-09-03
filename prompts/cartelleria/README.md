La **cartelleria obligatòria** és el conjunt de cartells, avisos i informació que una empresa està obligada a exhibir en un lloc visible, ja sigui per als treballadors, per als clients o per al públic en general. Les obligacions varien segons el país, la comunitat autònoma, el sector d'activitat i les característiques de l'empresa.

És un bon exemple d'una funcionalitat que la vostra plataforma podria gestionar sense convertir-se en un assessor legal.

## Com ho enfocaria a la vostra app

En lloc de dir:

> "Has de tenir aquest cartell."

Diria:

> "Segons el perfil de la teva empresa, és probable que necessitis revisar la cartelleria següent."

Cada element tindria:

* Què és.
* Quan aplica.
* Per què és necessari.
* Qui l'ha de veure.
* Una plantilla descarregable si és possible.
* Possibilitat de marcar-lo com a instal·lat.
* Data de verificació.

Per exemple:

| Cartell                           | Aplica                              | Visible per           |
| --------------------------------- | ----------------------------------- | --------------------- |
| Horari comercial                  | Comerços                            | Clients               |
| Fulls de reclamacions disponibles | Comerços oberts al públic           | Clients               |
| Prohibició de fumar               | Espais afectats per la normativa    | Tothom                |
| Videovigilància                   | Si hi ha càmeres                    | Tothom                |
| Aforament màxim                   | Quan la normativa ho exigeix        | Clients               |
| Sortida d'emergència              | Locals amb requisits de seguretat   | Tothom                |
| Extintors                         | Senyalització obligatòria           | Treballadors i públic |
| Primers auxilis                   | Segons PRL                          | Treballadors          |
| Pla d'evacuació                   | Determinats centres de treball      | Treballadors          |
| Igualtat / Protocol d'assetjament | En funció de la normativa aplicable | Treballadors          |

---

## Alguns exemples habituals a Espanya

### 1. Fulls de reclamacions

Moltes activitats obertes al públic han d'informar que disposen de fulls de reclamacions.

La vostra app podria:

* indicar si probablement aplica;
* generar el cartell informatiu (quan el model sigui oficial o personalitzable);
* recordar-ne la revisió.

---

### 2. Videovigilància

Si el tenant activa un mòdul de control d'accessos o indica que té càmeres, la plataforma podria detectar-ho.

Automàticament:

> Sembla que utilitzes videovigilància. Revisa si necessites instal·lar el cartell informatiu corresponent.

A més, podria generar el registre intern associat dins del DMS.

---

### 3. Prohibició de fumar

En molts locals és obligatori mostrar el cartell corresponent.

No és una funcionalitat espectacular, però suma en la percepció de rigor.

---

### 4. Prevenció de riscos laborals

Si hi ha treballadors:

* senyalització d'emergència;
* primers auxilis;
* vies d'evacuació;
* ús obligatori d'EPI (quan correspongui).

La plataforma podria tenir una checklist de verificació.

---

### 5. Horari comercial

En moltes activitats és obligatori mostrar l'horari des de l'exterior.

La plataforma podria generar-lo automàticament a partir dels horaris configurats al sistema.

---

### 6. Accessibilitat

En alguns casos:

* accessibilitat;
* aforament;
* desfibril·lador.

La plataforma podria recordar aquests requisits quan siguin aplicables.

---

## Com encaixa amb el vostre DMS

El DMS és especialment adequat perquè molts d'aquests elements són documents o cartells que es poden generar automàticament amb les dades del tenant.

Per exemple:

```
Cartell de videovigilància

Empresa:
{{tenant.name}}

Responsable:
{{tenant.legal_name}}

Contacte:
{{tenant.email}}

Data:
{{today}}
```

O un cartell d'horari comercial:

```
Horari

Dilluns:
09:00 - 13:30
16:00 - 20:00

...
```

Quan el tenant modifica els horaris, el cartell es pot regenerar automàticament.

## Una funcionalitat diferenciadora

Jo aniria un pas més enllà amb un **inventari de compliment físic del local**. A més dels cartells, inclouria altres elements verificables, com ara:

* Extintors (ubicació i data de la propera revisió).
* Farmaciola.
* Senyalització d'emergència.
* Pla d'evacuació.
* Cartelleria obligatòria.
* Fulls de reclamacions.
* Certificats visibles (si escau).
* Assegurança de responsabilitat civil exposada (quan sigui habitual al sector).

Cada element podria tenir un estat (*Pendent*, *Instal·lat*, *Revisat*), una data de comprovació i, fins i tot, una fotografia com a evidència.

## Important des del punt de vista legal

Aquí és on la vostra plataforma pot destacar sense assumir responsabilitats indegudes:

* **No** afirmar que un requisit és obligatori en tots els casos.
* Basar les recomanacions en el perfil de l'empresa (sector, ubicació, nombre de treballadors, etc.).
* Indicar sempre que la normativa pot variar segons l'activitat i la jurisdicció.
* Permetre que l'assessoria o el propi tenant marqui un element com a "No aplica" o "Verificat".

Això converteix la cartelleria en una funcionalitat de **governança i compliment operatiu**, no en un servei d'assessorament jurídic. És un enfocament molt coherent amb l'objectiu de la vostra plataforma de ser una eina rigorosa i útil per al dia a dia de les pimes.
