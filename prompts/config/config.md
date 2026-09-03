El que proposes és un **Motor de Configuració en Cascada (Cascading Settings Engine)**.

És una solució molt elegant que evita que els usuaris hagin de configurar-ho tot mil vegades, però que els dóna el control total per personalitzar el seu flux de treball.

Aquí tens l'estudi de com ho implementaria i el prompt per a la IA de codi.

---

### 🧠 Disseny del Motor de Configuració en Cascada

Perquè aquest sistema sigui eficient a Supabase i no carregui la base de dades, utilitzarem la potència de **JSONB** i el concepte d'**Herència Lògica**.

#### 1. L'Estructura de Dades

Afegirem una columna `settings jsonb` a les taules que ja tenim definides a la Fase 1:

* **Nivell App (Global):** Una taula nova `data.system_settings` on tu, com a owner de la plataforma, defineixes els valors de fàbrica.
* **Nivell Tenant (Empresa):** Columna `settings` a `data.tenants`.
* **Nivell Site (Local):** Columna `settings` a `data.sites`.
* **Nivell Usuari (Personal):** Columna `settings` a `data.tenant_members` (perquè les preferències d'un usuari solen ser diferents per a cada empresa on treballa).

#### 2. La Resolució de Valors (El "Merge")

A PostgreSQL, l'operador `||` per a JSONB fusiona dos objectes. El que es troba a la dreta sobreescriu el de l'esquerra. La jerarquia de resolució seria:
`app_settings || tenant_settings || site_settings || user_settings`

#### 3. UX al Frontend (Inherited Values)

Aquest és el detall de qualitat:

* Si estic al formulari de configuració del **Site** i el camp "Hora d'inici" està buit al JSONB del site, el component ha d'anar a buscar el valor al **Tenant**.
* Si al Tenant també està buit, el busca a l'**App**.
* Visualment, el `placeholder` de l'input mostrarà el valor heretat (ex: "8:00 (Heretat de l'empresa)").

---

### 🚀 Prompt per a la IA: Implementació del Motor de Configuració

Pots passar aquest prompt per consolidar aquesta funcionalitat transversal:

> **Rol:** Principal Software Engineer & Supabase Architect.
> **Objectiu:** Implementar un sistema de configuració jeràrquic (Settings Engine) en cascada per a una arquitectura SaaS Multi-Tenant i Multi-Site. Els valors s'han de poder definir a quatre nivells: Sistema (App), Tenant, Site i Usuari, on cada nivell sobreescriu l'anterior.
> **Tasques a realitzar:**
> **1. SQL DDL - Extensions de Taules (Esquema `data`):**
> * Crea la taula **`data.system_settings`** amb una sola fila per guardar els valors per defecte de tota la plataforma (ex: `{"default_event_start_time": "09:00"}`).
> * Afegeix una columna **`settings JSONB NOT NULL DEFAULT '{}'`** a les taules existents: `data.tenants`, `data.sites` i `data.tenant_members`.
> 
> 
> **2. SQL - Funció de Resolució (Esquema `api`):**
> * Crea una funció PL/pgSQL **`api.get_effective_settings(p_site_id UUID, p_user_id UUID)`** que:
> 1. Obtingui el `tenant_id` vinculat al site o a l'usuari.
> 2. Realitzi la fusió (merge) dels quatre JSONB en l'ordre: `System || Tenant || Site || User`.
> 3. Retorni el JSON final resultant.
> 
> 
> * Aquesta funció s'ha d'executar amb `SECURITY DEFINER` per poder llegir les taules privades de l'esquema `data`.
> 
> 
> **3. Frontend (React Hooks & UI):**
> * Crea un hook **`useSettings(key: string, context: {siteId?, userId?})`** que retorni el valor efectiu d'una configuració.
> * **Lògica de Formularis:** Dissenya una lògica per a components d'input de configuració que rebin el valor del nivell actual i el valor "heretat" (el resultat del merge dels nivells superiors).
> * Si el valor actual és `null` o `undefined`, l'input ha de mostrar el valor heretat com a placeholder o amb un estil visual diferent (ex: cursiva gris).
> 
> 
> 
> 
> **4. Seguretat RLS:**
> * Garanteix que els usuaris només puguin modificar el seu propi JSONB a `tenant_members` i que només els `managers`/`owners` puguin modificar els de `sites` o `tenants`.
> 
> 