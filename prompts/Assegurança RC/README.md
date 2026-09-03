L'**Assegurança RC** és l'**Assegurança de Responsabilitat Civil**. Serveix per cobrir els danys personals, materials o econòmics que una empresa o un professional pugui causar a tercers en l'exercici de la seva activitat.

És una de les recomanacions que una assessoria fa molt sovint als nous negocis, perquè un sol incident pot tenir un cost molt elevat.

---

# Un exemple senzill

Un electricista està treballant a casa d'un client.

Per error provoca un curtcircuit que crema part de la instal·lació.

La reclamació és de 18.000 €.

Si disposa d'una assegurança RC adequada, normalment serà l'asseguradora qui assumeixi la cobertura dins dels límits de la pòlissa.

---

# Altres exemples

## Un lampista

Trenca una canonada.

Inunda el pis inferior.

---

## Una empresa de neteja

Es fa malbé un terra de marbre molt car.

---

## Un informàtic

Esborra accidentalment dades d'un client.

---

## Una empresa de reformes

Cau una rajola sobre un vehicle.

---

## Una botiga

Un client rellisca perquè el terra estava mullat.

---

## Un fotògraf

Fa caure una càmera sobre un convidat durant un casament.

---

Tots aquests són casos típics de responsabilitat civil.

---

# És obligatòria?

Depèn.

No existeix una obligació general perquè totes les empreses tinguin una assegurança de responsabilitat civil.

Però sí que hi ha moltes activitats on és:

* obligatòria per llei;
* exigida pel col·legi professional;
* requerida per un contracte;
* imprescindible per treballar amb administracions públiques o grans empreses.

Per exemple, és habitual que sigui exigida o molt recomanable en activitats com:

* instal·lacions elèctriques;
* construcció;
* enginyeria;
* arquitectura;
* sanitat;
* activitats esportives;
* escoles;
* determinades activitats industrials.

---

# Com ho enfocaria a la vostra plataforma

No diria mai:

> "Has de contractar una assegurança."

Diria:

> Segons la teva activitat, revisa si necessites una assegurança de responsabilitat civil.

És una diferència important des del punt de vista legal.

---

# Funcionalitats interessants

## 1. Detectar quan probablement aplica

La plataforma coneix:

* CNAE
* sector
* tipus d'activitat
* nombre de treballadors
* si treballa a domicili
* si visita clients
* si manipula equips
* etc.

Pot mostrar:

```text
Recomanació

La vostra activitat acostuma a disposar d'una assegurança de responsabilitat civil.

Reviseu-ho amb la vostra assessoria o corredoria.
```

---

## 2. Gestió documental

El DMS podria guardar:

* pòlissa
* rebuts
* certificats
* condicions particulars
* ampliacions
* certificats per clients

Tot classificat.

---

## 3. Control de venciments

Això és molt útil.

```
Assegurança RC

Renovació

14/03/2027

Dies restants

38
```

Amb notificacions automàtiques.

---

## 4. Cobertures

Sense entrar en assessorament.

Simplement registrar.

Per exemple:

* Companyia asseguradora
* Número de pòlissa
* Capital assegurat
* Franquícia
* Data d'inici
* Data de renovació
* Contacte del mediador

---

## 5. Vincular-la a l'activitat

Imagina una empresa instal·ladora.

El quadre de compliment podria mostrar:

| Element                  | Estat                 |
| ------------------------ | --------------------- |
| Prevenció de riscos      | ✅                     |
| Control horari           | ✅                     |
| RC professional          | 🟡 Revisió recomanada |
| Vehicles                 | ✅                     |
| Certificats instal·lador | ✅                     |

---

# Integració amb altres mòduls

Aquí és on la vostra plataforma pot aportar molt valor.

### CRM

Quan un client demana:

"Envieu-nos el certificat de responsabilitat civil."

La plataforma el troba immediatament al DMS i permet enviar-lo.

---

### DMS

Emmagatzema:

* pòlissa
* rebuts
* certificats
* renovacions

---

### Automatitzacions

30 dies abans del venciment.

Crear tasca.

Enviar notificació.

Avisar l'assessoria.

---

### Portal de l'assessoria

L'assessoria podria veure:

```
Empresa

Assegurança RC

Caduca en 18 dies
```

I contactar el client abans que caduqui.

---

# Una idea que encaixa molt bé amb la vostra filosofia

En lloc de crear un mòdul específic d'"Assegurances", crearia un **Registre d'Actius de Compliment** (*Compliance Assets*), on l'assegurança RC seria un dels molts elements que l'empresa ha de mantenir vigents.

Per exemple:

| Actiu                                | Estat                |
| ------------------------------------ | -------------------- |
| Certificat digital                   | ✅ Vigent             |
| Assegurança RC                       | 🟡 Caduca en 30 dies |
| Llicència d'activitat                | ✅ Vigent             |
| Certificat d'instal·lador            | ✅ Vigent             |
| Contracte de manteniment d'extintors | 🔴 Caducat           |
| Certificat energètic                 | ✅ Vigent             |

Tots aquests elements comparteixen el mateix patró: tenen un document associat, una data de vigència, un responsable, recordatoris i, sovint, una renovació periòdica. Això us permet reutilitzar la mateixa infraestructura de DMS, notificacions i automatitzacions en lloc de crear mòduls independents per a cada tipus d'obligació. Aquesta aproximació és escalable i molt atractiva per a assessories, perquè centralitza el seguiment de tots els elements de compliment de l'empresa en un únic lloc.
