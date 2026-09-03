# Consideracions i Crítica a l'Arquitectura d'Automatització

**Data:** Juny 2026
**Estat:** Revisió Crítica
**Objectiu:** Analitzar el pla original i la revisió de la IA, descartant sobre-enginyeria i enfocant-nos en el futur (AI-in-the-loop, pragmatisme, viabilitat a Supabase).

---

## 1. Visió General de les propostes

L'enfocament del pla original és molt **pragmàtic** però es queda curt per a casos d'ús complexos de clients (processos multi-step). La revisió de la IA aporta conceptes d'enginyeria de programari enterprise excel·lents, però pateix d'una **sobre-enginyeria acadèmica** que podria paralitzar el desenvolupament de la nostra app si intentem implementar-ho tot d'inici. A més, **la IA ha ignorat completament el paper de la Intel·ligència Artificial** (ironies de la vida) en els fluxos de treball del futur.

## 2. Crítica a la Revisió de la IA (Errors i Sobre-enginyeria)

La revisió de la IA proposa patrons que sonen bé en teoria però són inviables o innecessaris per a la fase inicial/mitjana del nostre SaaS:

1. **Patró Saga / Compensacions (Rollbacks):** La IA suggereix accions de compensació si un pas falla (ex: esborrar l'usuari si falla l'enviament de l'email). Això és **sobre-enginyeria extrema** per a un sistema com el nostre. Implementar transaccions distribuïdes o Sagas duplicarà el temps de desenvolupament de cada acció. És molt més eficient i comú en iPaaS permetre **retries** (reintents) o pausar el procés per a intervenció manual (BAM) abans que desfer accions complexes.
2. **Construir un BPM complet a Supabase:** Suggerir taules com `process_versions`, `process_instances`, `process_steps` ens empeny a construir un motor BPM (com Camunda) dins de Postgres. Hem d'optar per **Pipelines lineals** o Directed Acyclic Graphs (DAGs) simples com GitHub Actions o Zapier, no un motor BPMN amb comportes paral·leles complexes. Si un client necessita BPMN avançat, per això fem la integració externa V2 cap a n8n.
3. **Falsa alarma amb el Transactional Outbox:** La IA diu "No facis Trigger -> webhook, fes Outbox". Però el pla original ja usava `PGMQ`. A Postgres, cridar `pgmq.send()` dins de la mateixa transacció SQL que modifica la dada (o en un trigger AFTER INSERT) **ja actua de forma transaccional**. Si la transacció principal fa rollback, el missatge no es posa a la cua PGMQ. Per tant, l'arquitectura PGMQ existent ja cobreix el patró Outbox sense necessitat de crear una nova taula `event_outbox`.

## 3. Errors de disseny en el Pla Original

El pla original tampoc és perfecte. Hi ha un error d'acoblament greu que cal corregir:

*   **Acoblament de Calendari amb Plantilles de Document:** El pla original proposa que en el moment de generar un document, s'escanegi la plantilla per crear events de calendari basant-se en camps de tipus `date`.
    *   **Per què és un error?** Acobla la capa de presentació (plantilla de document) amb la lògica de negoci abstracta (calendari). Què passa si s'esborra el document? O si la data clau ve d'un camp personalitzat i no d'un document imprès?
    *   **Solució:** Utilitzar esdeveniments purs. Un trigger `DOCUMENT_GENERATED` dispara una regla que extreu les dates i crea l'event. Això manté els components desacoblats.

## 4. El Gran Absent: AI-in-the-Loop i Agents

El futur dels ERPs no és només "si passa A, fes B", sinó delegar processos cognitius i decisius. Hem de dissenyar el motor d'automatització perquè la IA sigui un actor de primera classe.

### 4.1. Accions Natives d'IA
En lloc de només `SEND_EMAIL` o `CREATE_TASK`, necessitem **Tipus d'Accions AI**:
*   `AI_DATA_EXTRACTION`: Arriba un PDF de factura per email o upload -> L'acció IA n'extreu {import, proveïdor, data} en format JSON estructurat -> El següent pas desa la informació a la BD.
*   `AI_TEXT_GENERATION`: Generar el cos d'un email de resposta a un client de manera contextual basada en l'historial del projecte.
*   `AI_DECISION_ROUTING`: Un pas on la IA avalua un context (ex: "És una reclamació urgent?") i decideix quina branca de l'automatització cal seguir.

### 4.2. Fallback de Confiança (AI-to-Human in the loop)
La IA connecta perfectament amb el concepte de Business Automation Manager (BAM):
*   L'automatització executa un pas d'IA.
*   Si la **confiança de la IA és baixa** (< 85%), l'estat del procés canvia a `WAITING_HUMAN_APPROVAL` i aterra a l'Inbox del BAM.
*   Al BAM, l'usuari humà veu la proposta de la IA al costat del document original, la corregeix/valida, i el procés continua (Human in the loop).

### 4.3. Agents Autònoms com a "Actors"
A mitjà termini, podrem assignar tasques a un "Agent" a més de fer-ho a un empleat o usuari. L'ID d'assignació d'una tasca a `data.tasks` pot apuntar a un Agent especialitzat (ex: Agent Comptable), que processarà l'element de forma asíncrona utilitzant les seves eines, integrant la IA com si fos "un més de l'equip".

## 5. Proposta de Solució Òptima i Pragmàtica

Per tenir un sistema modern, preparat pel futur i viable de desenvolupar en la nostra app:

1.  **Format d'Events (CloudEvents):** Adoptem l'estàndard CloudEvents com suggeria la IA, garantint compatibilitat immediata amb n8n, Make i altres serveis externs.
2.  **Workflows Lineals o DAGs (No BPMN):** Expandim les "regles" del pla original a "Pipelines" (Processos seqüencials: Trigger -> Step 1 -> Step 2 -> Step 3). Si un client necessita arbres de decisió extremadament retorçats, que empri l'API cap al seu n8n.
3.  **Control d'Estat (`automation_runs`):** Creem una taula per l'estat global de l'execució d'un workflow (`RUNNING`, `WAITING_HUMAN_APPROVAL`, `COMPLETED`, `FAILED`), la qual cosa dóna visibilitat en temps real.
4.  **BAM Inbox:** El "Centre d'Automatització" serà principalment un Inbox (Safata d'Entrada) operativa, on el gestor revisarà automatitzacions aturades, ja sigui per passos de validació obligatòria (`HUMAN_APPROVAL`) o per dubtes de la IA.
5.  **Blueprints d'Instal·lació ("1-click Apps"):** Com indicava la revisió, permetrem als tenants instal·lar "paquets d'automatització" pre-fets per l'equip (ex: Flux Onboarding) en lloc d'haver de configurar totes les regles manualment des de zero.
