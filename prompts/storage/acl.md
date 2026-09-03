Aquí tens el *prompt* definitiu, redissenyat per assegurar que la IA no només implementi les ACLs, sinó que ho faci de la manera més eficient possible aprofitant l'herència de carpetes i la columna `ancestor_paths` que ja tenim.

***

**Copia i enganxa el següent text:**

> Act as a Senior Backend & Security Architect. We are going to implement a high-performance **ACL (Access Control List) system** for our file management platform, with a focus on **folder inheritance**.
>
> **Current Context:**
> - We have a `file_nodes` table with an `ancestor_paths` column (UUID array) and `node_type` ('file'|'folder').
> - The `FileNode` type includes `is_restricted: boolean` and `can_access_for_me: boolean`.
>
> **The Architecture (Inheritance via Ancestor Paths):**
> Instead of using slow recursive CTEs, we will use the `ancestor_paths` column to determine access. If a user has permission on a parent folder, they automatically have access to all descendants.
>
> **Your Task:**
>
> **1. Database Schema (Migration):**
> - Create a `data.node_permissions` table with `node_id`, `user_id`, and `access_level` ('viewer', 'editor', 'owner').
> - **Update RLS for `data.file_nodes`:**
>   - Access is granted if:
>     1. `is_restricted` is `false`.
>     2. The user is the `created_by` owner.
>     3. The user has a direct entry in `node_permissions` for this `node_id`.
>     4. **Inheritance:** The user has an entry in `node_permissions` for ANY `node_id` present in the current node's `ancestor_paths`.
> - **Update `api.file_nodes` View:** Recalculate `can_access_for_me` using this same inheritance logic so the frontend knows the effective permission.
>
> **2. Business Logic (RPCs):**
> - Implement `api.update_node_permissions(p_node_id, p_permissions_json)`: A `SECURITY DEFINER` function to manage the ACL.
> - **Folder Logic:** Ensure that when a new folder or file is created, it inherits the `is_restricted` status of its parent by default.
>
> **3. Frontend Service (`storageService.ts`):**
> - Add `getNodePermissions(nodeId)` and `updateNodePermissions(nodeId, permissions)` methods.
> - Map errors like `insufficient_permissions` to our standard `StorageServiceError`.
>
> **4. UI Component (`PermissionsModal.tsx`):**
> - Create a modal to manage access.
> - Include a toggle for `is_restricted` ("Privat" vs "Compartit amb el Tenant").
> - Add a user search (tenant members) to grant 'viewer' or 'editor' roles.
> - **i18n Requirement:** MUST follow the `.github/copilot-instructions.md` rule: `{t('storage.acl.key', 'Default Catalan')}`. Provide the updated `ca/storage.json`.
>
> **Critical Design Requirement:**
> When a folder's `is_restricted` status changes, how should we handle existing permissions of its children? For this implementation, assume that the parent's ACL acts as the "base" and children can have "additional" restrictions or grants. Explain your logic for resolving conflicts (e.g., if a child is restricted but the parent is public).
>
> **Output:**
> - SQL migration.
> - Updated `storageService.ts` and `storage.types.ts`.
> - `PermissionsModal.tsx` component.
> - Updated `ca/storage.json`.

***

### Per què aquest prompt és clau per a les carpetes?

1.  **Herència Eficient:** Al forçar l'ús d'`ancestor_paths` dins de la política RLS, la base de dades podrà resoldre els permisos de milers de fitxers en una sola operació de comparació d'arrays, evitant que el "Google Drive" es torni lent quan tinguis moltes subcarpetes.
2.  **Consistència:** El requeriment que els nous fitxers heretin l'estat `is_restricted` del pare evita que un usuari creï per error un fitxer públic dins d'una carpeta que s'suposa que és privada.
3.  **Intel·ligència de Negoci:** El repte del final ("Critical Design Requirement") obliga la IA a documentar com gestionarà els conflictes, la qual cosa et donarà una visió clara de com funcionarà la seguretat abans de provar-la.

Amb aquest prompt, la IA hauria de lligar la creació de carpetes que està fent ara amb el sistema de seguretat ACL de forma perfecta.