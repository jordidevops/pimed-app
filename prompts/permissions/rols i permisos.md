
***

### Prompt per a IA: Arquitectura de Rols i Permisos Jeràrquics (Multi-Site)

"Actua com un arquitecte de software expert. Analitza la següent descripció d'un sistema de Rols i Permisos (RBAC) per implementar-lo en una aplicació SaaS (Supabase/React) que ja té una arquitectura Multi-Tenant i Multi-Site. El sistema ha de complir aquests requisits:

**1. Model de Dades i Rols Existent:**
- La base de dades ja té definits 4 rols jeràrquics: `owner` (nivell 4), `manager` (nivell 3), `member` (nivell 2), `viewer` (nivell 1).
- Defineix els permisos com a claus granulars (ex: `invoices.view`, `invoices.edit`, `calendar.edit`).

**2. Lògica d'Herència Acumulativa:**
- Cada rol superior hereta automàticament tots els permisos dels rols inferiors.
- Implementa una funció pura en TypeScript que calculi els permisos totals d'un rol sumant els seus permisos base més tots els dels rols de nivell inferior.
- El rol `owner` ha de tenir sempre accés total (wildcard `*` o `return true`) sense necessitat de llistar tots els permisos.

**3. Dependències de Permisos:**
- Alguns permisos depenen d'altres (ex: per tenir `edit` cal tenir primer `view`). El sistema ha de normalitzar la llista per incloure les dependències automàticament.

**4. Persistència Personalitzada per Tenant:**
- Els permisos per defecte estan definits al codi, però els tenants poden personalitzar què pot fer cada rol (excepte l'`owner`).
- Guarda les personalitzacions a la taula `data.tenants` (dins del camp `metadata->'role_permissions'`) en format JSONB.
- L'estructura del JSON ha de ser: `{ "manager": ["permis.1"], "member": ["permis.1", "permis.2"] }`.

**5. Integració amb Supabase RLS i JWT (El més crític):**
- Actualment tenim un Auth Hook (`data.custom_access_token_hook`) que injecta els rols al JWT sota l'estructura:
  `{ "tenant_id": { "global_role": "viewer", "sites": { "site_id_1": "member" } } }`.
- **Actualització:** L'Auth Hook ha de llegir la personalització del tenant i calcular els permisos al vol, injectant-los al JWT de manera separada per context. L'estructura resultant al JWT ha de ser:
  `{ "tenant_id": { "global_permissions": ["view"], "sites": { "site_id_1": { "permissions": ["view", "edit"] } } } }`.
- Les polítiques RLS utilitzaran l'operador d'intersecció d'arrays contra aquest JWT per validar l'accés sense fer JOINs.

**6. Utilitats de Frontend (React/TypeScript):**
- Crea un hook `usePermission(permissionKey: string, targetSiteId?: string | null)`.
- **Lògica de context dual:** - Si no es passa `targetSiteId`, comprova si el permís existeix a l'array `global_permissions` del tenant actiu.
  - Si es passa `targetSiteId`, comprova si existeix a l'array de permisos d'aquell site en concret. (Nota: Si l'usuari té el permís de forma global, també el té a qualsevol site heretat).
- Utilitza TypeScript `Union Types` per garantir que les claus de permisos siguin vàlides i tinguin autocompletat.

**7. Seguretat de Gestió:**
- Implementa una lògica (Server Action o Edge Function) on un usuari només pugui editar les personalitzacions de permisos d'un tenant si el seu propi rang jeràrquic global és `owner` o `manager`.

Basant-te en aquesta arquitectura, genera el codi necessari per a:
1. El fitxer central TypeScript de definició de tipus, jerarquies i funcions d'herència de permisos.
2. La modificació de la funció SQL de l'Auth Hook (`data.custom_access_token_hook`) per calcular i injectar els permisos.
3. El hook de React `usePermission` que llegeixi el token de Supabase i resolgui el context (global vs site)."

***

