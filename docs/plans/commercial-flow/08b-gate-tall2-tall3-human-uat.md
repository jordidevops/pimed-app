# Gate Tall 2→3 — Passada humana (UAT dades)

> **Propòsit:** guia **pas a pas** perquè una persona (o parella tècnic + oficina) repliqui la UAT de qualitat de dades i pugui tancar el deute residual del gate.
> **Pla pare:** [`08-gate-tall2-tall3.md`](./08-gate-tall2-tall3.md) · criteris [`05-acceptance-and-gates.md`](./05-acceptance-and-gates.md) · ordre [`EXECUTION.md`](./EXECUTION.md)
> **Smoke ja fet (no substitueix això):** E2E `apps/tenant-portal/tests/gate-tall2-tall3-uat.spec.ts` (online O1–O4, O6–O7 × 2 OS).
> **Creat:** 2026-10-05

---

## 1. Què cal demostrar

| # | Demostració | Obligatori? |
|---|-------------|-------------|
| A | Online: hores, materials, despeses (`is_billable` + `paid_by`), PVP + cost, reload sense pèrdua | Sí |
| B | Online: close-out amb **km** (O5) | Sí (deute actual) |
| C | Offline mòbil: materials/actuals + sync sense duplicats; despesa offline falla clar (F1–F6) | Recomanat (tanca també deute CF-16) |
| D | Repetir A (+ B) en **≥2 OS** i en **≥2 dies** diferents | Sí per marcar el gate ✅ |

Quan A–D passin sense bugs bloquejants: actualitzar [`08`](./08-gate-tall2-tall3.md), [`05`](./05-acceptance-and-gates.md), [`STATUS.md`](./STATUS.md) i la fila del gate a [`EXECUTION.md`](./EXECUTION.md) a ✅.

---

## 2. Actors i comptes (seed local)

Escenari preferit: **dos rols** (Riera). Alternativa: un sol usuari owner (Volt).

### 2.1 Preferit — Riera Instal·lacions (tècnic + oficina)

| Rol | Persona | Email | Contrasenya | Dispositiu |
|-----|---------|-------|-------------|------------|
| Tècnic (member) | Hèctor | `hector@riera-instal.com` | `Test1234!` | Mòbil Chrome / PWA (ample ~390) |
| Oficina (owner/manager) | Gina | `gina@riera-instal.com` | `Test1234!` | Escriptori |

- Tenant: **Riera Instal·lacions** (`10000000-0000-0000-0000-000000000004`)
- Al login, selecciona l’organització **Riera Instal·lacions** si el selector ho demana.

### 2.2 Alternativa — Volt Serveis (un sol actor)

| Rol | Persona | Email | Contrasenya |
|-----|---------|-------|-------------|
| Owner (fa de tècnic i oficina) | Alice | `alice@acme-corp.com` | `Test1234!` |

- Tenant: **Volt Serveis** (`10000000-0000-0000-0000-000000000003`)
- Vàlid per A/B; per C millor mòbil real igualment.
- Nota: Alice veu cost (té `commercial.costs.view`); no prova el tall «member sense cost».

### 2.3 Entorn

1. App tenant-portal en local o staging (p. ex. `http://127.0.0.1:4173` o el `npm run dev` habitual).
2. Supabase local amb seed actual (`npx supabase db reset` si cal un estat net).
3. Full de resultats (còpia §8) obert abans de començar.
4. Anota **data, hora d’inici, IDs d’OS** a cada pas.

---

## 3. Dia 1 — Preparació (P1–P4)

| Pas | Qui | Què fer | Fet |
|-----|-----|---------|-----|
| P1 | Tots | Confirmar tenant (Riera o Volt) i els dos logins (o Alice) | ☐ |
| P2 | Oficina | Crear **2 OS** noves `work_order` + estat `active`, amb client i seu (Riera: un client seed; Volt: Constructora Meridian + seu) | ☐ |
| P3 | Tècnic | Obrir portal al **mòbil**; oficina a **escriptori** | ☐ |
| P4 | Qualsevol | Escriure al full: `OS-A = …`, `OS-B = …`, hora inici | ☐ |

### Com crear una OS (oficina o owner)

1. Anar a **Camp → Ordres** (`/field/orders`).
2. **Nova ordre**.
3. Omplir: nom (p. ex. `UAT gate Dia1 A`), tipus **Ordre de servei**, estat **Activa**, client + seu.
4. **Desar**. Copiar l’UUID de la URL (`/field/orders/<id>`).

Repetir per `UAT gate Dia1 B`.

---

## 4. Dia 1 — Passada online (OS-A) — O1…O7

Fes tot això a **OS-A**. Després, si vols, repeteix O1–O7 a **OS-B** el mateix dia (recomanat).

### O1 — Iniciar feina / fitxar (tècnic)

1. Login com a Hèctor (o Alice).
2. Obrir `OS-A` → pestanya **Fer**.
3. Prem **Iniciar feina** / **Iniciar visita** / **Reprendre feina** (el botó visible).
4. Accepta geolocalització si el navegador ho demana.
5. **Èxit:** es veu **Aturar** o **Temps en curs**; el timer avança.

### O2 — Material (tècnic)

1. A **Fer**, toca **Materials** (icona paquet).
2. Omple: nom `Cable UAT Dia1`, quantitat `2`, unitat `u`.
3. Prem **Afegir**.
4. **Èxit:** la fila apareix a la llista.

### O3 — Despesa amb flags (tècnic)

1. Toca **Despeses**.
2. Descripció: `Parking UAT Dia1`.
3. Import: `8,75` (o `8.75`).
4. Marca **Imputable al client**.
5. Qui paga: **Paga empleat**.
6. Prem **Afegir**.
7. **Èxit:** fila amb badges **Imputable** i **Paga empleat**.

### O4 — Aturar fitxatge (tècnic)

1. Prem **Aturar**.
2. **Èxit:** torna a aparèixer iniciar/reprendre; no hi ha error silenciós; el temps acumulat és coherent amb el rellotge (ordre de magnitud OK).

### O5 — Close-out amb km (tècnic) — deute actual

1. A la mateixa OS, busca l’acció de tancament (**Revisar i tancar** / flux de tancar visita a **Entregar** o CTA de peu, segons l’estat).
2. Al full de close-out / **Desviacions (imports)**:
   - Si hi ha camp **Km** / **Km reals**: introdueix un valor (p. ex. `12` o `12,5`).
   - Prem **Desar km** / **Aplicar** si cal.
3. Completa el tancament de la visita (confirma el diàleg).
4. **Èxit:**
   - La visita queda tancada / OS progressa sense error silenciós.
   - Als imports (o línia amb unitat `km`) es veu el km aplicat.
   - **No** s’ha creat un albarà només pel sync (l’albarà és manual després).

Si el flux no demana km (OS sense línia km al catàleg): anota-ho al full («sense línia km — afegir Desplaçament al catàleg / plantilla i repetir») i **no** marquis O5 com a PASS.

### O6 — Verificació oficina (Gina o Alice a escriptori)

1. Login oficina a la **mateixa** `OS-A` → **Fer** (o vista materials/despeses).
2. Comprova:
   - Material `Cable UAT Dia1` amb qty `2`.
   - Despesa `Parking UAT Dia1` amb badges imputable + paga empleat.
   - Temps / work log coherent.
3. Omple **PVP €** (p. ex. `25,50`) i **Cost €** (p. ex. `12,00`) al material.
   - Hèctor (member) **no** hauria de veure **Cost** (si proves Riera).
   - Gina/Alice **sí**.
4. Blur / desa i espera 1–2 s.
5. **Èxit:** PVP i cost es mantenen després de refresh.

### O7 — Reload sense pèrdua

1. Recarrega la pàgina (F5) a oficina.
2. Obre la mateixa OS en una **altra pestanya**.
3. **Èxit:** mateix material, mateixos imports PVP/cost, mateixa despesa; **cap duplicat**.

Marca al full: `OS-A Dia1: O1…O7 PASS/FAIL` + notes.

---

## 5. Dia 1 — Passada offline (F1–F6) — mòbil real

Fes-ho preferentment a **OS-B** (encara oberta) o a una tercera OS creada per offline.

| Pas | Acció | Criteri d’èxit | Fet |
|-----|-------|----------------|-----|
| F1 | Amb OS oberta a **Fer**, activa mode avió / talla Wi‑Fi+dades | UI honesta: pendent / «Sense xarxa»; **no** promet sync impossible | ☐ |
| F2 | Afegeix un material offline (p. ex. `Cable offline`) i/o actuals que CF-16 permeti | Apareix com a pendent local; un soft refresh **no** l’esborra | ☐ |
| F3 | Intenta afegir una **despesa** offline | Error clar **o** el formulari no ofereix desar; **cap** fila fantasma al servidor | ☐ |
| F4 | Si el producte ho permet: tanca visita offline | Estat tipus `local_pending` / pendent de sync; **cap** albarà creat | ☐ |
| F5 | Reactiva xarxa; espera drain o usa sync de dispositiu si n’hi ha | Una sola aplicació per operació; sense duplicats de material | ☐ |
| F6 | Obre dues pestanyes / reintenta Afegir el mateix material | Idempotència: no es creen dues files idèntiques no volgudes | ☐ |

Si F4 no està disponible a la teva build, marca «N/A — producte no ofereix tancament offline» i continua F5 amb les ops pendents de F2.

---

## 6. Dia 2 — Repetició (fiabilitat)

En un **dia natural diferent** (o ≥16 h després):

1. Crea **OS-C** (o reutilitza una OS activa neta).
2. Repeteix **O1–O7** (mínim online; offline F* si Dia 1 va fallar o va ser parcial).
3. Comprova que no hi ha regressions (mateixos criteris).

**Criteri de tancament del gate:** Dia 1 + Dia 2 amb ≥2 OS en total amb online PASS, i O5 + (idealment) F1–F6 sense bugs bloquejants.

---

## 7. Errors freqüents

| Símptoma | Què mirar |
|----------|-----------|
| No veig **Cost €** | Usuari sense `commercial.costs.view` (esperat a member). Usa Gina/Alice per O6. |
| No veig **PVP €** editable | Cal `commercial.pricing.edit` (manager/owner). |
| Despesa desa però sense badges | Revisa checkbox «Imputable» i select «Qui paga» **abans** d’Afegir. |
| O5 sense camp km | Falta línia/catàleg amb unitat `km` a l’OS; afegeix «Desplaçament» o equivalent i torna-ho a provar. |
| Offline crea despesa al servidor | Bug: anota steps + captura; el gate **no** passa. |
| Duplicats després de sync | Bug d’idempotència CF-16; anota `client_op_id` / IDs si pots. |

---

## 8. Full de resultats (copiar)

```text
Gate Tall 2→3 — UAT humana
Data Dia 1: ________    Hora inici: ________
Data Dia 2: ________    Hora inici: ________
Entorn (local/staging URL): ________
Tenant: Riera / Volt / altre: ________
Tècnic: ________ (dispositiu: ________)
Oficina: ________

OS-A id: ________  nom: ________
OS-B id: ________  nom: ________
OS-C id (Dia 2): ________

Online Dia 1 OS-A: O1☐ O2☐ O3☐ O4☐ O5☐ O6☐ O7☐
Online Dia 1 OS-B: O1☐ O2☐ O3☐ O4☐ O5☐ O6☐ O7☐
Offline Dia 1:     F1☐ F2☐ F3☐ F4☐ F5☐ F6☐
Online Dia 2:      O1☐ O2☐ O3☐ O4☐ O5☐ O6☐ O7☐

Bugs / captures:
-
-

Veredicte gate: PASS / FAIL / PASS amb deute (detallar)
Signatura / qui ho ha fet: ________
```

Després del PASS: actualitzar registre a [`08-gate-tall2-tall3.md`](./08-gate-tall2-tall3.md) §A i marcar gate ✅ a EXECUTION/STATUS/05.

---

## 9. Què no cal en aquesta passada

- Mòdul EXP (IVA, reemborsament, OCR).
- CF-19 / CF-20 (marges).
- Stripe / Holded.
- Omplir costos de materials històrics antics (només les OS de prova).
