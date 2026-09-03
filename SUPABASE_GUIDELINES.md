# Arquitectura de Dades i API: Supabase + Prisma (B2B Multi-tenant)

Aquest document descriu l'arquitectura de base de dades i els patrons d'accés per al nostre sistema multi-tenant. **IMPORTANT PER A AGENTS LLM:** Llegiu atentament les regles de seguretat (RLS) i de creació de vistes abans de generar o modificar fitxers de migració SQL.

## 1. Visió General de l'Arquitectura

El sistema utilitza el patró **Schema Isolation** per separar l'emmagatzematge físic de les dades de la seva exposició via API.

* **Schema `data` (Privat):** Conté totes les taules reals, claus foranes, índexs i polítiques RLS (Row Level Security). Aquest esquema MAI s'exposa directament a internet.
* **Schema `api` (Públic via PostgREST):** Conté exclusivament Vistes (Views) que apunten a les taules de `data`. És l'únic esquema exposat pel Data API de Supabase. Actua com un contracte de dades (DTOs) per al frontend dels tenants.

### Patrons d'Accés per Actor
1.  **Tenants / Usuaris Finals (Frontend):**
    * Utilitzen `supabase-js` via la Data API.
    * Autenticació via Supabase Auth.
    * Accedeixen NOMÉS a l'esquema `api`.
    * La seguretat està garantida pel RLS heretat a les vistes.
2.  **Administradors del Sistema (Backend / Panell Admin):**
    * Utilitzen **Prisma ORM** en un entorn de servidor (Node.js/Edge).
    * Connexió directa a l'esquema `data` mitjançant un pooler transaccional (port 6543).
    * Utilitzen un rol de base de dades amb permisos de super-administrador o atribut `BYPASSRLS` per tenir accés global sense restriccions per tenant.

## 2. Gestió de Migracions (Regla d'Or)

**Totes les migracions de base de dades es gestionen EXCLUSIVAMENT amb Supabase CLI.**
* `supabase migration new nom_migracio`
* Mai utilitzarem `prisma migrate`. Prisma només actua com a client (generat via `prisma db pull` o mantenint l'`schema.prisma` sincronitzat manualment com a reflex de l'esquema `data`).

## 3. Regles de l'Esquema `api` (Vistes)

**PER A AGENTS AI:** Quan se us demani crear o modificar una vista a l'esquema `api`, heu de complir estrictament les següents regles:

1.  **Seguretat de l'Invocador OBLIGATÒRIA:** Tota vista ha d'incloure la clàusula `WITH (security_invoker = true)`. Si s'omet, la vista farà by-pass del RLS.
    ```sql
    -- CORRECTE:
    CREATE OR REPLACE VIEW api.notes WITH (security_invoker = true) AS SELECT ...
    
    -- INCORRECTE (Risc crític de seguretat):
    CREATE OR REPLACE VIEW api.notes AS SELECT ...
    ```
2.  **Vistes Auto-Actualitzables (Sense `CREATE RULE`):** Per exposar CRUD complert via PostgREST sobre una taula, feu un `SELECT` directe sobre la taula sense `JOIN`s. Postgres farà la vista actualitzable automàticament. **NO utilitzeu `CREATE RULE`**, ja que trenca el comportament `RETURNING` de l'API de Supabase.
3.  **Permisos (Grants):** Especifiqueu exactament quines accions pot fer l'usuari autenticat sobre la vista.
    ```sql
    GRANT SELECT, INSERT, UPDATE, DELETE ON api.notes TO authenticated;
    ```
4.  **Lògica de Dades i Valors per Defecte:** Els valors per defecte (`DEFAULT`) s'han de definir a la taula `data`, mai a la vista.

## 4. Regles de Row Level Security (RLS) a `data`

A l'esquema `data`, totes les taules han de tenir `ENABLE ROW LEVEL SECURITY`.

**PER A AGENTS AI:** La lògica multi-tenant pot ser perillosa quant a rendiment. Seguiu aquestes pautes per a les polítiques:

1.  **Evitar el problema "N+1" del RLS:** No utilitzeu crides a funcions externes que facin un `SELECT` per validar el `tenant_id` si aquest s'ha d'avaluar per cada fila d'una taula gran.
2.  **Validació Multi-tenant:** Si el context requereix buscar dins d'una taula intermèdia (ex: `tenant_members`), feu servir un `EXISTS` directament dins la política, evitant sub-consultes esbiaixades com `LIMIT 1`.
    ```sql
    -- Exemple de política òptima per multi-tenant:
    CREATE POLICY "notes: membres veuen notes del tenant" 
      ON data.notes FOR SELECT TO authenticated
      USING (
        EXISTS (
          SELECT 1 FROM data.tenant_members tm
          WHERE tm.tenant_id = data.notes.tenant_id
            AND tm.user_id = auth.uid()
            AND tm.is_active = true
        )
      );
    ```
3.  **Funcions Helper i `SECURITY DEFINER`:** Si necessiteu funcions SQL d'ajuda per a comprovar rols globals de l'usuari, assegureu-vos d'usar `SECURITY DEFINER` de manera molt acotada, configurant el `search_path` de forma segura.

## 5. Exemple Pràctic Complert

### Taula (a `data`)
```sql
CREATE TABLE data.tasks (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES data.tenants(id),
  title text NOT NULL,
  is_completed boolean DEFAULT false,
  created_by uuid REFERENCES auth.users(id) DEFAULT auth.uid()
);

ALTER TABLE data.tasks ENABLE ROW LEVEL SECURITY;

-- RLS
CREATE POLICY "tasks: usuaris del tenant veuen les tasques"
  ON data.tasks FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM data.tenant_members tm
      WHERE tm.tenant_id = data.tasks.tenant_id
        AND tm.user_id = auth.uid()
    )
  );