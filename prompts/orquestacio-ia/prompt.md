Prompt temporalment aparcat per funcionalitat poc clara.


# Prompt d'estudi: orquestració agentiva en segon pla sobre el motor V1.5

Actua com a arquitecte principal de software i especialista en sistemes agentius, Supabase, PostgreSQL, PGMQ, Edge Functions, seguretat multi-tenant i sistemes human-in-the-loop.

Estàs revisant PiMed, una aplicació SaaS ERP multi-tenant construïda amb Supabase Postgres, Edge Functions, un tenant-portal Vite/React i un admin-portal Next.js. Tens accés complet al repositori.

## Objectiu

Produeix un **estudi tècnic i de producte en profunditat**, sense implementar codi, per determinar si convé introduir **orquestració agentiva en segon pla sobre el motor d'automatització V1.5 existent**.

El sistema objecte de l'estudi ha de poder rebre un objectiu acotat, treballar de manera asíncrona, consultar dades i utilitzar tools de forma adaptativa, mantenir estat entre invocacions, aturar-se de manera segura i deixar una proposta o expedient pendent d'aprovació humana.

Exemple conceptual:

```text
Trigger o encàrrec
  → workflow V1.5
  → AGENT_TASK amb objectiu i límits
      → inspecciona dades autoritzades
      → decideix quina tool de lectura necessita
      → observa el resultat
      → continua, replanteja o finalitza
      → prepara una proposta estructurada
  → HUMAN_APPROVAL
  → handlers deterministes apliquen només les accions aprovades
```

L'estudi no ha de donar per fet que aquesta és la solució correcta. Ha de comparar-la amb alternatives més simples i concloure, amb evidència del repositori, **on aporta valor, on no, i quin seria el pilot mínim segur**.

Llegeix tot aquest prompt abans d'explorar el codi.

---

## Documents obligatoris

Llegeix, com a mínim:

1. `docs/plans/automatitzacio/arquitectura-automatitzacio-v2.md`
2. `docs/plans/automatitzacio/revisio_pla_v2.md`
3. Tot `docs/plans/automatitzacio/paquet-implementacio-ia/`
4. `docs/plans/ai/chat_tools_function_calling_plan.md`
5. Els plans relacionats amb BYOK, governança d'IA, MCP i tools que localitzis al repositori
6. Altres documents `plan-*.md` necessaris per seguir les convencions locals de documentació

Tracta els documents com a hipòtesis i decisions històriques. Contrasta'ls amb el codi actual. Quan documentació i implementació divergeixin, identifica-ho explícitament.

---

## Distincions obligatòries

No confonguis aquests conceptes:

| Concepte | Qui decideix el flux | Exemple |
|---|---|---|
| Automatització determinista | Workflow JSONB | Consultar dades → generar document → enviar |
| AI-in-the-Loop V2.1 | Workflow JSONB; la IA resol un step acotat | `AI_EXTRACT`, `AI_CLASSIFY`, `AI_GENERATE` |
| Assistent AI interactiu | Usuari + model durant el xat | Consulta o proposta iniciada per l'usuari |
| Agent en segon pla | Agent dins d'un objectiu i pressupost acotats | Selecciona tools de lectura, investiga i prepara una proposta |
| Orquestració multiagent | Supervisor o protocol delega entre agents | Agent coordinador + agents especialistes |

Treballar en segon pla, usar IA o acabar en aprovació humana **no converteix per si sol** un procés en agentiu. Considera agentiu el procés quan el model pot escollir adaptativament tools o passos intermedis dins d'un perímetre autoritzat.

---

## Decisions de partida

Aquestes són restriccions de l'estudi, no conclusions que hagis de redescobrir:

1. El motor V1.5 és la base de triggers, cues, runs, retries, cancel·lació, observabilitat i aprovacions. No proposis substituir-lo sense demostrar una incompatibilitat concreta.
2. La primera aplicació agentiva, si es recomana, serà **read-mostly**: podrà consultar dades i generar una proposta estructurada, però no aplicar directament canvis de negoci.
3. Les accions amb efectes persistents es faran després d'un `HUMAN_APPROVAL`, mitjançant handlers deterministes i autoritzats.
4. BYOK continua sent obligatori per tenant. Sense credencial vàlida no s'executa cap agent.
5. Tot accés ha d'estar limitat explícitament per `tenant_id`, permisos, entitlements i conjunt de tools autoritzades.
6. No pressuposis que cal un sistema multiagent. Compara sempre:
   - workflow determinista sense IA;
   - AI-in-the-Loop amb un step acotat;
   - un únic agent amb tools;
   - múltiples agents o patró Supervisor.
7. Frameworks com LangGraph, CrewAI o equivalents no estan prohibits per a l'estudi, però tampoc són una decisió presa. Avalua'ls només si resolen necessitats demostrades que el motor V1.5 no cobreix adequadament.
8. No implementis res. La sortida és un estudi per prendre una decisió arquitectònica i preparar un eventual pilot.

---

## Part 1 — Inventari verificat del repositori

Construeix una matriu amb estat **Implementat / Parcial / Documentat / Inexistent / Divergent**.

### 1.1 Motor d'automatització V1.5

Revisa:

- `automation_workflows`, `automation_runs`, `automation_step_runs` i aprovacions
- workflow snapshots i contractes JSONB
- PGMQ, QueueRunner i Edge Functions del motor
- state machine, reclamació atòmica, idempotència i retries
- `WAITING_HUMAN`, `WAITING_TIMER`, cancel·lació i represa
- correlació, causalitat, profunditat i prevenció de bucles
- Automation Center i capacitat real de suport/debugging
- entitlements, RLS i auditoria

### 1.2 Plataforma d'IA

Revisa:

- BYOK, Vault i resolució server-side de credencials
- `runAiGeneration`, proveïdors i models
- `ai_usage_ledger`, rate limits i polítiques per membre
- timeout, errors de proveïdor i sanitització de secrets
- capacitats de sortida estructurada i validació amb Zod

### 1.3 Assistent AI i tools

Revisa:

- `ai-chat-turn` i `ai-chat-apply-proposal`
- `packages/ai-schemas`
- registre i definició de tools
- validació d'input i output
- tools de lectura, proposta i escriptura
- context d'actor, permisos i tenant scoping
- quina lògica de domini és reutilitzable fora del xat

### 1.4 Resultat

Per cada component indica:

- fitxers i símbols clau;
- estat real;
- garanties que ja ofereix;
- limitacions per executar agents asíncrons;
- divergències respecte als plans.

---

## Part 2 — Definició del problema i casos d'ús

Identifica problemes reals de l'ERP que puguin justificar un agent en segon pla.

Per cada cas candidat, descriu:

- objectiu de negoci;
- usuari beneficiari;
- dades i mòduls implicats;
- variabilitat del procés;
- per què un workflow fix o un únic step d'IA seria insuficient;
- tools que l'agent necessitaria;
- output proposat;
- accions que quedarien pendents d'aprovació;
- freqüència i volum estimables a partir del producte;
- pitjor conseqüència d'una conclusió incorrecta.

Avalua especialment casos com:

- revisió d'incidències de fitxatges, horaris i absències;
- expedients d'onboarding o offboarding incomplets;
- revisió documental i detecció de dades mancants;
- preparació de resums operatius multi-mòdul;
- seguiment de processos que combinen documents, tasques, calendari i signatures.

No assumeixis que aquests exemples són bons. Descarta els que no estiguin recolzats pel domini o les dades actuals.

Selecciona un màxim de **tres candidats** i classifica'ls amb una matriu:

- valor per al tenant;
- necessitat real d'agència;
- risc;
- qualitat i disponibilitat de dades;
- cost d'IA;
- facilitat d'avaluació;
- complexitat d'implementació;
- adequació per a un pilot read-only.

---

## Part 3 — Comparativa de solucions

Per al millor cas candidat, compara com a mínim:

### Opció A — Workflow determinista

Passos predefinits, regles SQL i handlers existents.

### Opció B — AI-in-the-Loop

Un step d'IA acotat amb input/output estructurat, sense tool loop adaptatiu.

### Opció C — Agent únic en segon pla

Objectiu acotat, conjunt de tools permès, bucle plan-act-observe limitat, checkpoints i proposta final.

### Opció D — Multiagent o Supervisor

Delegació entre agents especialitzats o planificador central.

Compara:

- valor funcional;
- determinisme i reproduïbilitat;
- seguretat;
- auditoria;
- latència;
- cost;
- manteniment;
- testabilitat;
- dependència de framework;
- encaix amb V1.5.

Recomana la solució **menys complexa que resolgui suficientment el problema**. Si l'orquestració agentiva no queda justificada, digues-ho clarament.

---

## Part 4 — Arquitectura proposada del pilot agentiu

Si recomanes un pilot, dissenya'l sobre V1.5.

### 4.1 Frontera entre workflow i agent

Defineix:

- què controla el workflow V1.5;
- què pot decidir l'agent;
- què no pot decidir mai;
- condicions de finalització;
- format de la proposta final;
- com entra a `HUMAN_APPROVAL`;
- com els handlers deterministes apliquen les accions aprovades.

Considera un step conceptual `AGENT_TASK`, però verifica si és millor:

- un nou `step_type`;
- una run filla correlacionada;
- una capa separada referenciada des d'un step;
- una altra abstracció compatible amb els invariants actuals.

### 4.2 Bucle d'execució

Especifica un contracte conceptual per a:

```text
load checkpoint
→ provide objective + context + allowed tools
→ model selects zero or one next action
→ validate action
→ execute tool
→ persist observation and usage
→ evaluate stop conditions
→ enqueue continuation or finalize proposal
```

No assumeixis que tot el bucle cap en una sola Edge Function.

### 4.3 Estat i checkpoints

Avalua quines dades cal persistir:

- `agent_run_id` i relació amb `automation_run_id` / `step_run_id`;
- objectiu i instruccions versionades;
- model, proveïdor i paràmetres efectius;
- iteració actual i pressupost consumit;
- tool call sol·licitada, arguments validats i resultat sanititzat;
- resum de memòria o estat acumulat;
- proposta final estructurada;
- errors, causa de parada i timestamps;
- aprovació o rebuig posterior.

Decideix si es poden ampliar les taules actuals o calen taules específiques. Evita guardar chain-of-thought privat; registra decisions operacionals, evidència, tool calls i resultats necessaris per auditar.

### 4.4 Execució asíncrona

Verifica els límits actuals de Supabase Edge Functions i dissenya:

- una iteració o tool call per invocació quan sigui necessari;
- continuacions via PGMQ;
- lease i reclamació atòmica;
- heartbeat o detecció de runs abandonades;
- idempotència per iteració i tool call;
- retry selectiu;
- cancel·lació;
- represa després de timeout;
- dead-letter o estat terminal segur.

Compara aquest model amb els patrons ja utilitzats per PDF, signatura i `WAIT`.

---

## Part 5 — Catàleg i contracte de tools

Proposa com reutilitzar els tools del xat sense acoblar l'agent a la UI.

Avalua:

1. reutilitzar directament executors del xat;
2. extreure una capa de serveis de domini compartida;
3. crear un registre comú de tools amb adapters per xat i agent;
4. reutilitzar handlers d'automatització com a tools.

Defineix el contracte mínim d'una tool agentiva:

- identificador i versió;
- descripció;
- esquema Zod d'input i output;
- mode `read`, `propose` o `write`;
- permisos necessaris;
- scoping de tenant i site;
- timeout i mida màxima;
- idempotency key;
- política de retry;
- cost estimat;
- redacció de dades sensibles;
- evidència auditable retornada.

Per al primer pilot, crea una allowlist explícita de tools. Justifica si han de ser exclusivament de lectura.

---

## Part 6 — Seguretat, governança i guardrails

Dissenya defenses en profunditat.

### 6.1 Identitat i autorització

- identitat del tenant;
- usuari o rol patrocinador de la run;
- permisos congelats al començament vs revalidats a cada tool call;
- execució amb `service_role` sense saltar-se les regles de negoci;
- revocació de permisos durant una run;
- separació estricta entre tenants.

### 6.2 Límits operacionals

- nombre màxim d'iteracions;
- nombre màxim de tool calls;
- duració màxima total;
- tokens i cost màxims;
- mida màxima de context i outputs;
- allowlist de models;
- kill switch global, per tenant i per run;
- circuit breaker per proveïdor o tool.

### 6.3 Classificació d'accions

Defineix una política:

- lectura segura;
- proposta sense efecte;
- escriptura reversible;
- acció sensible o irreversible.

Indica quines categories queden prohibides al pilot i quines exigeixen aprovació humana.

### 6.4 Resistència a prompt injection

Analitza especialment:

- documents de tenants;
- camps de text lliure;
- contingut recuperat per tools;
- instruccions malicioses dins d'un PDF o document;
- exfiltració entre tenants;
- intent d'ampliar permisos o invocar tools no autoritzades.

Proposa separació entre instruccions i dades, marcatge de provenance, validació estructurada, allowlists i controls previs a cada execució.

### 6.5 BYOK i privacitat

- resolució segura de la clau a cada invocació;
- absència de secrets en checkpoints i logs;
- polítiques davant clau absent, revocada o invàlida;
- tractament de PII laboral enviada al proveïdor;
- retenció i minimització de dades;
- elecció de proveïdor/model per tenant.

---

## Part 7 — Human-in-the-Loop

L'aprovació humana no ha de ser un simple botó al final. Dissenya:

- proposta estructurada i comprensible;
- evidències i fonts utilitzades;
- diferència entre fets, inferències i recomanacions;
- confiança o incertesa sense inventar una precisió falsa;
- diff de les accions proposades;
- aprovació total, parcial, edició o rebuig;
- revalidació de permisos i dades abans d'aplicar;
- caducitat de propostes;
- comportament si les dades han canviat des de l'anàlisi;
- auditoria de qui aprova què.

Avalua si el BAM actual cobreix aquestes necessitats o requereix extensions.

---

## Part 8 — Observabilitat, avaluació i operació

Defineix què cal mesurar abans de donar el pilot per vàlid:

- percentatge de runs completades;
- motius de parada;
- iteracions i tool calls per run;
- latència i cost;
- errors de tools i proveïdors;
- aprovacions, edicions i rebutjos;
- precisió factual i cobertura;
- falsos positius i omissions;
- incidències de seguretat;
- valor percebut i temps estalviat.

Proposa:

- conjunt d'evals offline amb casos representatius;
- tests de tenant isolation i permisos;
- tests d'idempotència, timeout, retry i cancel·lació;
- casos adversarials de prompt injection;
- mode shadow sense mostrar ni aplicar propostes;
- desplegament progressiu per tenants;
- criteris objectius de go/no-go.

Explica com donar suport a una run concreta sense exposar secrets ni chain-of-thought.

---

## Part 9 — Build vs buy i frameworks

Determina si cal un framework extern.

Compara com a mínim:

- ampliar V1.5 amb un bucle agentiu mínim propi;
- usar un runtime o framework especialitzat;
- executar l'agent en un servei extern i conservar V1.5 com a control plane.

No facis una comparativa genèrica de marques. Avalua capacitats concretes:

- checkpoints persistents;
- durable execution;
- tool calling;
- pauses human-in-the-loop;
- streaming o events;
- retries i idempotència;
- observabilitat;
- suport TypeScript/Deno;
- compatibilitat amb Edge Functions;
- multi-tenant;
- lock-in i cost operatiu.

Si analitzes LangGraph, CrewAI o altres opcions, verifica documentació i límits actuals. No els recomanis només perquè siguin frameworks d'agents.

---

## Part 10 — Pilot recomanat i roadmap

Si la conclusió és favorable, defineix un únic pilot.

Inclou:

- nom i objectiu;
- trigger;
- dades accessibles;
- allowlist de tools;
- límits d'iteració, temps i cost;
- output estructurat;
- aprovador;
- accions posteriors deterministes;
- casos de fallada;
- mètriques;
- criteris d'acceptació;
- criteris per interrompre el pilot.

Divideix el roadmap en fases petites:

1. validació de cas d'ús i evals;
2. contractes i seguretat;
3. runtime agentiu read-only;
4. integració amb V1.5 i BAM;
5. shadow mode;
6. pilot limitat;
7. decisió de continuar, simplificar o descartar.

Per cada fase, especifica entregables, dependències, riscos i criteris d'acceptació.

No planifiquis multiagent fins que un agent únic demostri una limitació mesurable.

---

## Part 11 — Decisions i conclusió executiva

Separa:

- decisions ja tancades;
- decisions recomanades per l'estudi;
- decisions obertes que requereixen producte, legal o operacions;
- hipòtesis que necessiten validació.

La conclusió ha de respondre explícitament:

1. Hi ha almenys un problema de PiMed que justifiqui agència adaptativa?
2. Per què AI-in-the-Loop no és suficient en aquest cas?
3. És suficient un agent únic o cal orquestració multiagent?
4. Com s'integra amb V1.5 sense duplicar el motor?
5. Quin és el pilot mínim segur?
6. Quines condicions farien recomanable no construir-lo?

Accepta com a conclusió vàlida: **“no convé implementar orquestració agentiva ara”**, si l'evidència ho indica.

---

## Format de sortida

Genera:

`docs/plans/automatitzacio/estudi-orquestracio-agentiva-background.md`

Segueix les convencions dels plans vius del repositori:

```markdown
# Estudi: orquestració agentiva en segon pla

> **Data:** YYYY-MM-DD
> **Estat:** Esborrany per decisió
> **Relacionat:** ...

## 0. Resum executiu
## 1. Decisions tancades, recomanades i obertes
## 2. Inventari verificat
## 3. Casos d'ús i necessitat d'agència
## 4. Comparativa d'alternatives
## 5. Arquitectura del pilot
## 6. Tools i contractes
## 7. Seguretat i governança
## 8. Human-in-the-Loop
## 9. Observabilitat i evals
## 10. Build vs buy
## 11. Pilot i roadmap
## 12. Riscos i mitigacions
## 13. Fora d'abast
## 14. Conclusió go/no-go
## Annex A. Evidència de codi
## Annex B. Preguntes obertes
```

Inclou referències precises a fitxers, taules, funcions i símbols del repositori. Distingueix sempre fets verificats, inferències i recomanacions.

---

## Fora d'abast obligatori

- implementar codi, migracions o UI;
- substituir el motor V1.5 sense evidència d'incompatibilitat;
- agents amb escriptura autònoma en el pilot;
- decisions laborals o legals automàtiques;
- multiagent o Supervisor com a requisit inicial;
- memòria indefinida o aprenentatge autònom entre tenants;
- guardar chain-of-thought privat;
- donar accés genèric a SQL, `service_role`, xarxa o tools no incloses a l'allowlist;
- convertir cada automatització existent en un agent.

---

## Regles de qualitat

- Explora codi abans de proposar arquitectura.
- No repeteixis simplement els plans existents: identifica el delta específic necessari per a agents asíncrons.
- No atribueixis a la IA tasques que SQL, regles o workflows resolen millor.
- Prioritza control, reversibilitat i evidència sobre autonomia.
- No confonguis “autònom” amb “sense supervisió”: el pilot ha de finalitzar en proposta humana.
- No inventis capacitats del repositori ni límits de proveïdors.
- Verifica informació externa sensible al temps, especialment límits de Supabase i frameworks.
- Quantifica costos i límits quan hi hagi dades suficients; en cas contrari, declara la incertesa.
- Recomana la solució més simple compatible amb el valor esperat.
