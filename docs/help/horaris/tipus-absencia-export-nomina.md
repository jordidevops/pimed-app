# Tipus d'absència i codis d'export per a nòmina

Aquest document explica la secció **«Tipus d'absència i codis export»** de la configuració de control horari: per a què serveix, com configurar-la i com es reflecteix a l'export de nòmina (CSV, A3, Sage).

## Visió general

PiMed gestiona absències i IT amb **tipus interns** (`vacation`, `it_common`, `bereavement`, etc.). El programa de nòmina de l'empresa (A3, Sage, PayFit o un altre) sol esperar **codis propis** per a cada concepte d'absentisme.

La configuració de codis d'export fa de **pont** entre ambdós mons:

| A PiMed | Al fitxer d'export |
|---------|-------------------|
| Tipus d'absència aprovat/actiu en un dia | Columnes `absence_export_code`, `absence_parent_key`, `absence_subtype_key` |
| Nom visible per a l'usuari (CA/ES) | `absence_type_name` |
| Si és IT | `is_it` |

**No canvia** qui pot demanar absències, com s'aproven ni com es pinten al calendari laboral. Només afecta la **sortida cap a nòmina**.

## On es configura

| Pantalla | Ruta |
|----------|------|
| **Configuració → Control horari** | `/settings/attendance-control` → secció **Tipus d'absència i codis export** |

Només **propietaris i gestors** del tenant poden editar els codis o crear subtipus nous.

L'export de dades es fa des de **Fitxatges / revisió nòmina** → **Export nòmina** (CSV genèric o perfil A3/Sage configurat a la mateixa pàgina de control horari).

---

## Conceptes

### Família (`parent_key`)

Agrupació de primer nivell, pensada per informes i connectors:

| Família | Exemples de tipus |
|---------|-------------------|
| **Vacances** | `vacation` |
| **Assumptes personals** | `personal_days` |
| **Família** | defunció, matrimoni, hospitalització familiar… |
| **Permisos** | permís mèdic parcial, reducció de jornada… |
| **IT / Baixa** | IT comuna, accident laboral, maternitat/paternitat… |
| **Compensació** | (reservat per a futurs tipus de compensació) |
| **Altres** | tipus no classificats |

### Subtipus (`subtype_key`)

Variant concreta dins la família. Per als tipus de **sistema**, el subtipus coincideix amb la clau interna (`vacation`, `it_maternity`, etc.). El tenant pot crear **subtipus propis** (p. ex. un permís del conveni col·lectiu).

### Codi d'export (`export_code`)

Codi curt (fins a 12 caràcters) que surt al CSV i que podeu mapar al concepte del vostre software de nòmina. **Cada tenant pot sobreescriure** el codi per defecte sense canviar el tipus legal de sistema.

---

## Codis per defecte (tipus de sistema)

Valors inicials després de la migració; podeu personalitzar-los:

| Tipus (clau interna) | Família | Codi export |
|----------------------|---------|-------------|
| `vacation` | Vacances | **VA** |
| `personal_days` | Personal | **AP** |
| `bereavement` | Família | **DF** |
| `marriage` | Família | **MA** |
| `family_hospitalization` | Família | **HF** |
| `family_emergency` | Família | **UF** |
| `partial_medical_personal` | Permisos | **MP** |
| `partial_medical_company` | Permisos | **MC** |
| `reduced_hours` | Permisos | **RJ** |
| `it_common` | IT | **IT** |
| `it_work_accident` | IT | **ITA** |
| `it_maternity` | IT | **ITN** |
| `it_parental` | IT | **ITP** |
| `it_menstrual` | IT | **ITM** |

Els codis són **orientatius**: han d'alinear-se amb el que espera el vostre gestor de nòmina o el conveni. Consulteu el vostre assessor laboral abans de tancar el mes.

---

## Com es veu a l'export CSV (diari)

Per cada fila de dia i empleat, si hi ha una absència amb estat `approved`, `active` o `closed`, l'export inclou entre d'altres:

| Columna | Contingut |
|---------|-----------|
| `absence_type_name` | Nom visible (CA/ES) |
| `absence_export_code` | Codi configurat (p. ex. `VA`, `IT`) |
| `absence_parent_key` | Família (`vacation`, `it`, …) |
| `absence_subtype_key` | Subtipus (`vacation`, `it_maternity`, …) |
| `absence_status` | Estat de la sol·licitud |
| `is_it` | `1` si el tipus està marcat com a IT |
| `payroll_action` | `absence_ok` si el dia es considera cobert per absència |

L'export **no marca** els dies com a exportats ni bloqueja el mes: és només lectura per preparar la nòmina.

### Perfils A3 / Sage

A **Control horari → Perfils d'export nòmina** podeu definir columnes que llegeixin `absence_export_code` o conceptes agregats (`it_days`, `absence_days`). Vegeu el spike tècnic `docs/plans/checkin/spike-d3-a3-sage-payroll-export.md` per a exemples de mapping.

---

## Crear un subtipus propi del tenant

1. A **Tipus d'absència i codis export**, clic a **Afegir subtipus**.
2. Trieu la **família** (p. ex. Permisos).
3. Indiqueu **nom visible**, **clau de subtipus** i **clau interna** (identificador únic, sense espais; p. ex. `permis_formacio`).
4. Assigneu el **codi d'export** que demani el vostre connector (p. ex. `PF`).

El nou tipus apareixerà a les sol·licituds d'absència del tenant un cop actiu. No substitueix els tipus legals de sistema: és una extensió per al vostre conveni o política interna.

---

## Relació amb altres parts del producte

| Funcionalitat | Relació amb codis d'export |
|---------------|----------------------------|
| **Absències** (`/attendance-mgmt/absences`) | Aquí es demanen i aproven; l'export llegeix el tipus aprovat del dia. |
| **Calendari laboral** (`leave` al calendari) | Override de planificació; **no** és el mateix que una absència a `employee_absences`. L'export d'absències ve de registres d'absència/IT, no del `day_type = leave` del calendari. |
| **Revisió nòmina** (fitxa empleat / fitxatges equip) | Mostra el mateix `absence_export_code` que sortirà a l'export. |
| **IT des de fitxa empleat** | Els tipus IT porten família `it` i el codi configurat (p. ex. `IT`, `ITA`). |

---

## Flux recomanat (gestor de nòmina)

1. **Abans del primer tancament de mes:** revisar codis d'export amb el gestor de nòmina o consultoria laboral.
2. **Durant el mes:** aprovar absències i IT com sempre.
3. **Al tancament:** exportar període (diari o agregat) i importar/mapar al software extern.
4. **Si el conveni canvia:** actualitzar només el codi d'export del tipus afectat; no cal recrear absències passades.

---

## Preguntes freqüents

### Canvio el codi d'export d'un tipus. Afecta absències ja registrades?

Sí, **en el sentit de l'export**: l'export resol el codi **en el moment de generar el fitxer**, a partir de la configuració actual del tenant. Les absències històriques no canvien de tipus, només el codi que surt al CSV.

### Per què hi ha família i subtipus si ja tinc el codi?

- La **família** agrupa per informes i futurs connectors (p. ex. comptar tots els dies IT).
- El **subtipus** distingeix variants (IT maternitat vs IT comuna) quan el codi d'export és el mateix o quan el connector demana dos nivells.
- El **codi d'export** és el que acostuma a importar-se directament a A3/Sage.

### El meu A3 no reconeix `VA`. Què faig?

Editeu el codi d'export del tipus **Vacances** al valor que A3 esperi per a aquell concepte variable (p. ex. el codi del conveni). Opcionalment creeu un perfil d'export que mapi `absence_export_code` a la columna del fitxer destí.

### Puc desactivar un tipus d'absència des d'aquí?

No. Aquesta pantalla només gestiona **taxonomia i codis d'export**. L'activació de tipus i regles legals (`requires_document`, dies màxims, etc.) es fa en altres fluxos de configuració d'absències.

---

## Referències tècniques (implementació)

| Recurs | Descripció |
|--------|------------|
| `docs/plans/checkin/plan-monthly-close-approval.md` (§C1) | Pla de producte |
| `docs/plans/checkin/spike-d3-a3-sage-payroll-export.md` | Connectors A3/Sage |
| Migració `20260912000001_track_c1_absence_taxonomy_export.sql` | Esquema i RPCs |
