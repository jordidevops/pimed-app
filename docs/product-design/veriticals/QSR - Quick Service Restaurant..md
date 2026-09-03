# Mancances

**Quan diria que NO (per ordre de gravetat):**

1. **Marge / % laboral** — vol saber si gasta massa en personal respecte al que ven (per franja). L’app té hores, no vendes ni TPV. Per a molts franquiciats això és “control horari car”, no eina de negoci. **Deal-breaker freqüent.**
2. **Primers 5 minuts** — si l’onboarding/demo fa olor d’electricista (Acme) i no hi ha pack restaurant, se’n va abans de provar el fitxatge.
3. **Drive-thru** — AUTO Service - a la Diagonal és el cor del negoci; si només és una zona amb un nom, nota que el producte no ha pensat en menjar ràpid.
4. **Si el comprador és la cadena** (no el franquiciat) — no hi ha model marca → N franquiciats. Descart immediat per a ells; per a Marc amb 2 locals, no.
5. **Propines** — gap real, però secundari a ES/CAT en QSR.

“Tipatge drive-thru/daypart” volia dir exactament els punts 2–3: l’app *permet simular-ho amb noms*, però **no ho entén com a estructura del negoci** (ni informes per franja, ni canal auto nadiu).




**POS** = *Point of Sale* (punt de venda).

És el sistema de **caixa / TPV** on es registren les comandes i els cobraments: pantalles de cuina, tickets, targetes, total del dia, etc. Exemples: Square, SumUp, Revo, el TPV de la pròpia cadena.

En el context del pla:
- El **POS** sap quant s’ha **venut** (€).
- PiMed sap quant ha **treballat** la gent (hores).
- El **% laboral** uneix les dues coses: cost de personal ÷ vendes del POS.


**Marge / % laboral** = *(cost de personal ÷ vendes) × 100*, idealment per local i per franja (dinar, sopar…).  
Avui PiMed té el numerador a mitges (hores) i **zero denominador** (vendes). No cal convertir-se en un TPV; cal una via neta d’entrar vendes i calcular.

## Què cal tenir

| Peça | Origen possible |
|------|-----------------|
| **Hores** | Ja les teniu (`time_punches` / resums diaris) |
| **€ de personal** | Hores × cost/hora (salari configurat) o import importat de nòmina |
| **€ de vendes** | TPV, caixa, CSV, o entrada manual |

Sense vendes, només pots dir “hem treballat X hores”, no “anem al 28%”.

## Camins de solució (del més lleuger al més pesat)

### 1) MVP manual / CSV (setmanes, no mesos)
El director o l’admin entra **vendes del dia** (o puja un CSV) per local: data, import, opcionalment franja.

- Informe: `cost_estimat / vendes` per dia i local  
- Cost estimat = hores aprovades × `cost_hora` de l’empleat (o mitjana del rol)

**Pros:** no depens del TPV; desbloqueja la conversa amb Marc.  
**Contres:** disciplina d’entrada; franges cal definir-les (mapar torns → daypart).

Això encaixa amb el posicionament: *no som el TPV; som qui uneix personal + un número de vendes*.

### 2) Import diari des del TPV (Tier-3, el camí “de veritat”)
Webhook o sync nocturn Square / SumUp / Revo / etc.: **totals de vendes per local i dia** (després per franja si l’API ho dona).

- PiMed = font de veritat del **temps**  
- TPV = font de veritat de les **vendes**  
- PiMed només guarda agregats (`site_id`, `date`, `daypart?`, `sales_amount`), no tickets línia a línia

**Pros:** % laboral automàtic; Marc deixa l’Excel.  
**Contres:** cada TPV és un projecte; cal mapping local↔caixa.

### 3) Via ERP (Holded, etc.)
Si el client ja factura/tanca al dia a Holded, importar **ingressos del local** (o compte analític) com a proxy de vendes.

**Pros:** un sol pont per qui ja viu a Holded.  
**Contres:** sovint més lent i menys granular que el TPV (franges difícils).

### 4) El que NO cal fer (i mataria el focus)
- Reconstruir un POS / carta / comandes  
- Sincronitzar cada ticket en temps real  
- Competir amb el TPV en caixa

La doc ja ho deixa clar: el POS físic és autoritat externa.

## Disseny de producte mínim (recomanat)

1. **`sales_snapshots`** (o similar): `tenant_id`, `site_id`, `business_date`, `daypart` (opcional), `amount`, `source` (`manual` \| `csv` \| `sumup` \| …).  
2. **Cost laboral del període** a partir de resums d’assistència × cost/hora (cal tenir cost a empleat o rol).  
3. **Vista “Labor %”**: per local, dia, setmana; filtre per franja quan hi hagi daypart.  
4. **Alertes senzilles**: “ahir Diagonal > 35%” (objectiu configurable per local).

Les **franges** (punt 2 del gap) aquí deixen de ser cosmètica: sense daypart a vendes i a hores, el % només és diari.

## Ordre pragmàtic de entrega

| Fase | Què | Valor per al franquiciat |
|------|-----|---------------------------|
| **A** | Vendes manuals/CSV + cost/hora + informe % diari/local | Demo i prova de 30 dies creïble |
| **B** | Dayparts consistents (torns + vendes) | “El dinar del dissabte va al 40%” |
| **C** | 1 integració TPV (la més usada pel segment) | Deixa de ser “control horari” |
| **D** | Objectius i alertes per local | Gestió proactiva del marge |

## Criteri de producte

- Si voleu **guanyar franquiciats QSR ara**: Fase A+B desbloqueja el deal-breaker sense trencar “no som un TPV”.  
- Si només feu hores perfectes i zero vendes: seguireu sent compliment laboral excel·lent i **eina de marge feble**.

En resum: solució = **connectar (o deixar entrar) € de vendes** i dividir pel **cost de personal que ja podeu derivar de les hores**; no cal ser la caixa.





**Drive-thru** (servei amb auto) no es “arregla” només afegint un valor a un enum. Cal que l’app **entengui** que aquell local té un canal de venda diferent, amb personal, horaris i mètriques pròpies.

## Què vol el franquiciat

A la Diagonal no és “una zona més”:

- Hi ha **finestra / carril** amb gent assignada
- El **pic** (dinar/sopar) demana cobertura específica
- De vegades l’horari del DT ≠ horari de sala
- Vol informes del tipus: “qui ha estat al DT”, “estem curts al DT el dissabte”

Avui només podeu posar una `location` que es digui “Servei amb auto” (`outdoor`) — útil per geo/fitxatge, **cec** per al negoci.

## Nivells de solució

### 1) MVP de producte (ràpid, alt impacte percetiu)

Sense ser un mòdul nou enorme:

| Canvi | Efecte |
|-------|--------|
| Tipus d’ubicació o etiqueta `drive_thru` (o `service_channel` a `sites` / `locations`) | L’UI i els filtres saben què és |
| Rol operatiu nadiu o pack: `drive_thru` / “Finestra” | Coverage i planificador parlen el mateix idioma |
| Checklist / estació lligada a la zona DT | Obertura/tancament del carril |
| Informe senzill: hores i slots filtrats per zona DT | Deixa de ser “nom inventat” |

Amb això, el seed BurgerVista deixa de ser un adhesiu i passa a ser un **concepte del producte**.

### 2) Model operatiu (el que realment tanca el gap)

Pensar el DT com a **canal del local**, no només com a habitació:

```text
Site Diagonal
  ├── canal lobby (sala + mostrador)
  └── canal drive_thru (carril + finestra)
```

Cada canal pot tenir:

- Horari d’obertura propi (`calendar_business_hours` o equivalent per canal)
- Demanda de cobertura pròpia (min. 1 finestra a dinar/sopar)
- Ubicació(ns) + estació de fitxatge
- Opcional: objectiu de personal / alertes “DT sense cobertura”

Això encaixa amb el que ja teniu (`locations`, `work_roles`, `coverage_demands`, `shift_slots.location_id`) — cal **empaquetar-ho i tipar-ho**, no reinventar el motor de torns.

### 3) El que NO cal (de moment)

- Sensors de cua, temps de servei, pantalles de cuina del carril  
- Integració amb el TPV del DT  
- Simular tot el flux de comanda al carril  

Això és ops de cadena / POS. PiMed pot ser excel·lent en **qui ha d’estar a la finestra i quan**, sense ser el sistema de comandes.

## Ordre pragmàtic

| Fase | Què | Valor |
|------|-----|--------|
| **A** | `location` tipada / flag `is_drive_thru` + rol pack + filtres a planificador i coverage | Demo QSR creïble |
| **B** | Horari de canal (DT vs sala) + coverage recurrent “DT dinar/sopar” | Planificació realista |
| **C** | Informe hores/cost per canal (+ % laboral si hi ha vendes per canal) | Gestió del local Diagonal |
| **D** | (Opcional) mètriques externes de cua/temps — només si el segment ho demana | Diferenciació avançada |

## Criteri

- **Solució mínima bona:** tipar el canal + usar-lo a rols, coverage, slots i informes.  
- **Solució incompleta:** només una zona amb nom bonic (el que faríeu al seed sense canvi de producte).  
- **Overkill:** construir el POS del drive-thru.

En una frase: el drive-thru es soluciona tractant-lo com a **canal operatiu del local** (tipus + personal + horari + cobertura + informe), no com a decoració d’ubicació.