Aquesta és la culminació de tota l'arquitectura que hem estat dissenyant. Ara és quan totes les peces del trencaclosques (DMS, Hub & Spoke, Rols, Sites, Locations) encaixen per crear un **SaaS de nivell Enterprise**.

Si agafem l'estudi inicial de les `work_orders` i li apliquem la "lent" de tot el que hem construït, el mòdul pateix una evolució espectacular. Es torna molt més net i potent.

Aquí tens l'anàlisi de com impacta cada nou element, seguit del **Prompt Definitiu** per generar aquest super-mòdul.

### 💥 Impacte de la Nova Arquitectura al Mòdul d'Obres/Feines

**1. Adeu `work_orders`, Hola `data.projects` (Amb Departaments)**
Ja no necessitem una taula aïllada d'obres. Utilitzarem la taula mestra `data.projects` (tipus `work_order` o `maintenance`).
* **Com afecta:** L'obra s'assigna a un `department_id` (ex: "Equip de Manteniment"). Només els usuaris d'aquest departament (o els globals) podran veure i executar l'obra. Això simplifica l'RLS enormement.

**2. Integració amb Espais i Actius (Locations & Assets)**
Una obra ja no és només un text lliure ("Reparar a la cuina").
* **Com afecta:** El projecte/obra tindrà camps opcionals `site_id`, `location_id` i `asset_id`. Ara pots dir exactament: "Aquesta obra és al *Site* (Restaurant A), a la *Location* (Cuina Principal), per reparar l'*Asset* (Forn de Pizza 2)". L'historial de reparacions de la màquina queda registrat de forma nativa.

**3. Adeu taula `photos`, Hola Motor Documental (DMS)**
L'estudi original proposava crear una taula `photos`. Això ara és **completament innecessari i redundant**.
* **Com afecta:** Quan un operari faci una foto d'una feina acabada, simplement crearem un registre al nostre DMS (`data.documents`) amb `entity_type = 'work_log'` i `entity_id = id_del_fitxatge`. Tindrem versions, control de permisos i carpetes automàticament de franc.

**4. Integració Total (Calendari + Jobs + Events)**
Quan l'estudi feia un RPC per crear una obra, només tocava la seva taula.
* **Com afecta:** El nostre RPC ara farà la transacció perfecta: Crea el projecte + Inserteix al `app.calendar_events` (perquè surti a l'agenda) + Inserteix a `data.events` (Audit log) + Fa `pgmq.send` amb `idempotency_key` (per enviar notificacions push/email asíncrones).

---

### 🚀 El Prompt Definitiu: Mòdul de Feines / Field Service (Enterprise)

Quan la base de la teva app estigui a lloc, passa-li aquest prompt a la IA de codi per generar aquest mòdul. És el més complex i ric que tindràs:

> **Rol:** Principal Software Engineer & Supabase Architect.
>
> **Objectiu:** Implementar el mòdul de "Field Service / Execució d'Obres" dins d'una arquitectura ERP multi-tenant i multi-site existent. Aquest mòdul aprofita la taula `data.projects` unificada i s'integra amb els mòduls de *Locations*, *Assets*, *DMS (Documents)* i *Calendari*.
>
> **Tasques a realitzar:**
>
> **1. Extensió del Model Base (SQL DDL):**
> * Afegeix a `data.projects` (si no hi són) els camps: `type` (ENUM: 'internal', 'work_order', 'maintenance'), `location_id UUID REFERENCES data.locations(id)`, i `asset_id UUID REFERENCES data.assets(id)`.
> * Crea la taula d'execució core **`data.work_logs`** (Fitxatges de camp).
>   - Camps: `id`, `tenant_id`, `site_id`, `project_id UUID REFERENCES data.projects(id)`, `task_id UUID REFERENCES data.tasks(id)`, `worker_id UUID REFERENCES data.profiles(id)`, `status VARCHAR` (open/closed), `check_in TIMESTAMPTZ`, `check_out TIMESTAMPTZ`, `check_in_geo JSONB`, `check_out_geo JSONB`, `notes TEXT`.
> * Crea taules auxiliars **`data.project_expenses`** i **`data.project_materials`** vinculades a `project_id` amb aïllament de `tenant_id`.
> * *Nota crucial:* NO creïs taules de fotos o adjunts. S'utilitzarà la taula polimòrfica existent `data.documents` amb `entity_type IN ('project', 'work_log')`.
>
> **2. Seguretat RLS (Basada en Context i Departaments):**
> * Aplica polítiques RLS a `work_logs`, `expenses` i `materials`.
> * La lectura i escriptura depèn del projecte pare. L'usuari ha de tenir accés al `department_id` del projecte (via JWT `user_tenants`), tenir un rol global, o bé ser el mateix `worker_id` que ha creat el `work_log`.
>
> **3. RPCs Transaccionals de Negoci (Esquema `api`):**
> * **`api.start_work_log(p_project_id, p_task_id, p_geo_json)`**:
>   1. Valida que l'usuari no tingui un log "open".
>   2. Inserteix a `data.work_logs`.
>   3. Registra a `data.events` (Audit log).
>   4. Executa `pgmq.send` amb `idempotency_key` informant l'inici.
> * **`api.stop_work_log(p_log_id, p_geo_json)`**:
>   1. Tanca el log (`check_out = now()`).
>   2. Registra l'esdeveniment a l'Audit.
>   3. Si s'indica que la tasca està acabada, actualitza `data.tasks`.
>
> **4. Integració amb el Calendari:**
> * Genera un script o trigger d'exemple on, en assignar una `task` a un `worker_id` amb `due_date`, s'insereixi de forma transaccional un registre a `app.calendar_events` vinculat al mòdul corresponent, establint com a `owner_id` l'operari, perquè li aparegui a la seva agenda mòbil.
>
> **5. Frontend (React) - Vista Operari:**
> * Dissenya el component/hook que cridi a `start_work_log`.
> * Usa la API nativa de geolocalització del navegador (`navigator.geolocation.getCurrentPosition`) per extreure {lat, lng, accuracy} i formatar el JSONB del `check_in_geo` abans d'enviar-ho al RPC.

### 🌟 Resultat

Amb aquest enfocament, has transformat un simple "gestor de feines" en un motor industrial. Si el teu client envia un tècnic a fer una feina, l'app registrarà on està el tècnic (GPS), vincularà les fotos de la reparació al manual del fabricant (DMS) de l'equip exacte (Asset), i la tasca apareixerà a l'agenda del seu departament (Calendari). Tot controlat amb permisos granulars en temps real i notificacions asíncrones en background. 

És directament insuperable. Cap a on movem la lupa ara? Facturació i subscripcions amb Stripe?