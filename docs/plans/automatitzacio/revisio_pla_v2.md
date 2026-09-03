He revisat detingudament la proposta arquitectònica **V2** per al sistema d'automatització. Com a anàlisi general, el document està molt ben enfocat: la decisió d'anar cap a un model d'automatització basat en **Workflows com a dades (JSONB)** en lloc de regles soltes és totalment encertada per evitar el deute tècnic, i conceptualitzar-ho com un "GitHub Actions/n8n intern" s'ajusta perfectament a les necessitats d'un ERP SaaS.

Malgrat tot, tenint en compte que **la implementació la farà un agent IA**, cal ser extremadament precís amb els detalls que es donen per fets. Les IA excel·leixen seguint instruccions estructurades, però poden patir o prendre decisions subòptimes si troben buits en la lògica d'infraestructura, concurrència o seguretat de Supabase (PostgreSQL).

A continuació, detallo els **possibles problemes (riscos)** i les **millores recomanades** estructurades per capes, pensant específicament en facilitar la feina de l'agent IA.

---

## 1. Riscos Tècnics i de Disseny (A corregir)

### 🔴 Concurrència i Competició de Cues (Race Conditions)

El disseny proposa que quan arriba un event, la Edge Function `process-workflow-triggers` llegeix la taula `automation_workflows` i fa un `INSERT` en massa a `automation_step_runs`. Després, envia el **primer pas** a la cua `automation_queue` de PGMQ.

* **El risc:** Si la cua té múltiples workers (escalat d'Edge Functions), o si un pas es reintenta ràpidament, correm el risc que s'executin passos fora d'ordre o es dupliquin execucions si no es gestiona bé el bloqueig.
* **Solució per a la IA:** Cal forçar que l'agent implementi un mecanisme de **bloqueig optimista** o un check d'estat estricte (`WHERE status = 'PENDING'`) abans que qualsevol worker canviï l'estat d'un step a `RUNNING`.

### 🔴 El perill dels bucles infinits indirectes

Es menysprea el risc de bucles dient que el model és un *Directed Acyclic Graph (DAG)* i que no hi ha loops interns a la definició del JSONB.

* **El risc:** El bucle pot no estar *dins* del workflow, sinó *entre* workflows i efectes secundaris. Per exemple:
1. Event: `EMPLOYEE_CREATED` $\rightarrow$ Dispara Workflow A.
2. Workflow A, Pas 5: `UPDATE_FIELD` (actualitza el departament de l'empleat).
3. L'actualització de l'empleat genera un nou `audit_log` (UPDATE).
4. El trigger de la Capa 0 ho detecta i torna a disparar el Workflow A (o un Workflow B que torna a modificar l'empleat). **Bucle infinit a la base de dades i col·lapse de PGMQ.**


* **Solució per a la IA:** Cal definir un **Mecanisme de Recidiva o profunditat màxima** (ex: un camp `depth` o `parent_run_id` a l'envelope de l'event, o ignorar modificacions fetes pel propi usuari del sistema/worker d'automatització a les regles del trigger).

### 🟡 El Handler de Dates (`pg_cron` + `process-date-triggers`)

El pla diu: *"Cada matí a les 08:00 UTC, busca documents... i envia a PGMQ"*.

* **El risc:** Si el volum de dades creix (milers de tenants amb milers de documents), una sola crida cronogràfica que faci un `SELECT` massiu pot causar un *timeout* a l'Edge Function o bloquejar la base de dades.
* **Solució per a la IA:** L'agent IA ha d'implementar aquest procés mitjançant **paginació (cursor-based o keyset pagination)** i enviar els missatges a PGMQ en *batches* (lots), mai carregant tot el volum a la memòria de la funció en una sola consulta.

---

## 2. Millores de Disseny per a la Implementació de la IA

### 🟢 Estructura del JSONB de `steps` (Donar un esquema rígid)

Si deixem que la IA dissenyi l'estructura exacta del JSONB de definició de passos, pot variar el criteri entre diferents fitxers o rutes de codi. Recomano fixar un esquema JSON estricte (que es pugui validar amb Typescript / Zod al codi).

Per a una millor robustesa, el punter del flux no hauria de ser només un text lliure a `on_success`, sinó una estructura clara de graf:

```typescript
// Exemple d'esquema de validació estricte que la IA hauria d'utilitzar:
const StepDefinitionSchema = z.object({
  id: z.string(),
  type: z.string(),
  config: z.record(z.any()),
  routing: z.object({
    on_success: z.string().nullable(), // ID del següent pas o null per acabar (END_OK)
    on_failure: z.string().default('END_FAIL') // ID del pas de gestió d'error o finalització
  }),
  retry_policy: z.object({
    max_attempts: z.number().default(3),
    backoff_factor: z.string().default('exponential')
  })
});

```

### 🟢 El patró "State Machine" per al Workflow Engine

Perquè l'agent IA no s'emboliqui decidint com avançar de pas, cal donar-li una regla d'or d'arquitectura: **Un pas mai encua el següent directament.**

* *Flux recomanat:* El Handler executa el Pas 1 $\rightarrow$ Marca el Pas 1 com a `COMPLETED` $\rightarrow$ Crida una funció centralitzada (ex: `rpc.transition_workflow_run(run_id)`) $\rightarrow$ Aquesta funció avalua el graf, busca el següent pas a executar, i l'encua a PGMQ.
* *Avantatge:* Centralitza tota la lògica de transició en un sol lloc del codi, evitant que la IA hagi de replicar la lògica de "què ve ara" a cada un dels 12 handlers que escriurà.

### 🟢 Gestió del Context i la Seguretat (RLS) en Background

Els workers (QueueRunner) s'executen fora del context de sessió de l'usuari (sense JWT de Supabase).

* **Millora:** Quan es creï un `workflow_run`, cal emmagatzemar l'`user_id` que va originar l'event inicial. Si un pas fa un `UPDATE_FIELD` o un insert a `data.tasks`, l'agent IA ha d'assegurar-se que l'operació a la base de dades es fa utilitzant un rol que respecti el tenant, o simulant la sessió de l'usuari (actuant *on behalf of*) si teniu RLS molt estrictes que requereixin variables de sessió.

---

## 3. Com preparar la feina per a l'Agent IA

Abans de donar aquest fitxer de proposta a l'agent d'IA perquè comenci a picar codi, et recomano crear un directori de treball de preparació amb aquests elements:

1. **Defineix els Schemas de Base de Dades (Fase Prèvia):** En lloc de demanar-li que imagini les taules, dóna-li el llistat exactat amb codi SQL (incloent-hi els tipus de dades de `automation_runs`, `status` enums, etc.).
2. **Afegeix els canvis dels Riscos esmentats:** Modifica el Roadmap de la proposta afegint explícitament al *Sprint 1*: "Implementar protecció contra bucles infinits en triggers d'audit" i "Validació d'esquema de passos amb Zod".
3. **Dissenya un "Mock Handler":** Escriu tu mateix el codi del handler més senzill (`SEND_NOTIFICATION`). Feso servir com a *Blueprint de Codi* per a la IA. Un cop la IA vegi com interactua el handler amb PGMQ, el Workflow Run store i els errors, podrà replicar exactament el mateix patró arquitectònic per als 11 handlers restants de manera simètrica i polida.

La proposta V2 té una base de negoci i funcional immillorable; implementant aquestes guardes tècniques a nivell de concurrència i control de flux a la base de dades, l'automatització serà extremadament sòlida.