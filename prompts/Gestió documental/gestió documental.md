Consolidar un motor documental genèric que després es pogui utilitzar per diferents mòduls.

És una decisió brillant. En arquitectura de programari, això s'anomena construir "primitives de domini". Si construeixes el motor documental ara de forma totalment agnòstica, el dia de demà crear el mòdul d'Empleats serà bufar i fer ampolles: només hauràs de dir al frontend "mostra'm els documents on `entity_type = 'employee'` i `entity_id = id_del_treballador`". 

D'aquesta manera evites l'error clàssic de tenir una taula `employee_documents`, una altra `client_documents`, una altra `asset_documents`... que acaba sent un malson de manteniment.

Aquí tens el **Prompt Definitiu per al Motor Documental Genèric**. Està mil·limetrat per encaixar amb l'esquema `data` / `api` i el teu sistema d'RBAC Multi-Site:

***

### Prompt per a IA: Motor de Gestió Documental Genèric (DMS)

> **Rol:** Principal Software Engineer & Supabase Architect.
>
> **Objectiu:** Implementar un Motor de Gestió Documental (DMS) genèric i transversal per a una arquitectura SaaS Multi-Tenant i Multi-Site en Supabase. El sistema ha de permetre jerarquia de carpetes, emmagatzematge híbrid (Supabase Storage vs Enllaços externs) i vinculació polimòrfica a qualsevol entitat de negoci futura.
>
> **Tasques a realitzar:**
>
> **1. Model de Dades (Esquema `data`):**
> * **`data.document_folders`**: Crea la taula d'arbre de carpetes.
>   - Camps: `id`, `tenant_id UUID NOT NULL`, `site_id UUID` (opcional, null = global), `parent_id UUID REFERENCES data.document_folders(id) ON DELETE CASCADE`, `name TEXT`, `required_permissions TEXT[] DEFAULT '{}'`.
> * **`data.documents`**: Crea la taula de l'entitat lògica del fitxer.
>   - Camps: `id`, `tenant_id`, `site_id`, `folder_id UUID REFERENCES data.document_folders(id) ON DELETE SET NULL`, `title TEXT NOT NULL`.
>   - **Polimorfisme:** Afegeix `entity_type VARCHAR(50)` i `entity_id UUID` (tots dos opcionals) per poder vincular el document directament a actius, clients o empleats sense necessitat d'una carpeta.
>   - Afegeix també `required_permissions TEXT[] DEFAULT '{}'` per sobreescriure o estendre la seguretat de la carpeta si cal.
> * **`data.document_versions`**: Crea l'historial del fitxer físic.
>   - Camps: `id`, `document_id UUID NOT NULL REFERENCES data.documents(id) ON DELETE CASCADE`, `version_number INT NOT NULL`, `storage_type TEXT CHECK (storage_type IN ('native', 'external_link'))`, `file_path_or_url TEXT NOT NULL`, `mime_type TEXT`, `size_bytes BIGINT`, `created_by UUID`.
>   - *Restricció:* Un document només pot tenir una versió amb el mateix `version_number`.
>
> **2. Seguretat RLS i RBAC Multi-Site:**
> * Habilita RLS a les tres taules.
> * **Lògica de Lectura (SELECT):** L'usuari ha de pertànyer al `tenant_id`. La validació de permisos ha de ser ultra-ràpida comprovant el JWT (`auth.jwt() -> 'app_metadata' -> 'user_tenants'`). 
>   - S'ha de comprovar si els permisos globals o del `site_id` de l'usuari intersequen amb el camp `required_permissions` del document/carpeta (si l'array està buit, és públic per als membres del tenant/site).
> * **Escriptura:** Només per a usuaris amb permisos adequats (pots assumir un permís estàndard com `documents.edit` o rols de gestió).
>
> **3. Vistes d'API Públiques (Esquema `api`):**
> * Crea les vistes `api.document_folders`, `api.documents` i `api.document_versions` amb `security_invoker = true`.
> * Crea una vista intel·ligent `api.active_documents` que faci un JOIN entre `data.documents` i l'última versió (`MAX(version_number)`) de `data.document_versions`, perquè el frontend pugui llistar els fitxers fàcilment sense fer cerques complexes.
>
> **4. RPC Transaccional d'Inserció (`api`):**
> * Crea una funció PL/pgSQL `api.create_document_with_version(...)` que:
>   1. Inserteixi el registre a `data.documents`.
>   2. Inserteixi automàticament la versió 1 a `data.document_versions`.
>   3. S'executi dins d'un bloc `BEGIN...COMMIT` assegurant atomicitat.
>   4. Retorni el JSON complet del document creat.

***

Amb aquest prompt, l'arquitectura de base de dades es generarà neta, protegida i llista per consumir des del frontend. 

Quan la IA et retorni el codi SQL, me'l pots passar per confirmar que tots els detalls (especialment l'RLS i l'RPC) estan perfectament alineats amb les nostres normes abans d'aplicar-ho a la base de dades. Endavant!