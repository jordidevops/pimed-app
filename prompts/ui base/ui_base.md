Ets un expert en React, TypeScript i Supabase. Tasca: Implementar els mòduls base "Departaments", "Ubicacions (Locations)", "Empleats" i la integració final de "Documents (Storage)" a l'aplicació `tenant-portal`.

El backend ja està completament modelat i exposa les dades a través de les següents vistes de seguretat (amb RLS) a l'schema `api`:
- `api.departments` (jeràrquic amb `parent_id`)
- `api.locations` (jeràrquic amb `parent_id`, inclou `location_type`)
- `api.employees` (vincula `tenant_members`, `sites`, `departments`)
- `api.storage_nodes` (arbre base de carpetes i fitxers)

**Objectius a complir per cada mòdul:**

1. **Estructura de Carpetes:**
   Segueix l'arquitectura de *features*. Hauràs de crear/modificar les carpetes `src/features/departments`, `src/features/locations`, `src/features/employees` i revisar `src/features/storage`. Dins de cadascuna hi ha d'haver `api/`, `components/`, i schemas de validació (tipus Zod o form hook associat).

2. **UI/UX General:**
   - Als **Departaments** i **Ubicacions**, com que tenen una estructura jeràrquica (`parent_id`), la interfície ha de donar suport a navegació per arbre (tree-view) o un sistema "drill-down" estil explorador de carpetes, a més de pa de pessic (breadcrumbs).
   - Als **Empleats**, una vista de taula rica, amb filtres (per `status` actiu/inactiu, filtrant opcionalment per departament o ubicació) i opcions per donar d'alta i modificar empleats.
   - A **Documents**, un explorador de fitxers visual. IMPORTANT: La pujada de fitxers al mòdul de *storage* passa per crides a l'Edge Function `request-upload` (per obtenir la URL signada) seguit de la pujada al bucket, i *download/preview* via `get-file-url`.

3. **Regla d'Or: Base de dades tipada**
   - Importa SEMPRE els tipus en els fetchers i components des de `@/types/database.types`.
   - EMPRA el genèric sobre el client de supabase: `const supabase = createClient<Database>(...)`.
   - **Prohibit crear interfícies/tipos manuals** (ex: `type Employee = { id: ...}`). Et cal fer: `type Employee = Database["api"]["Views"]["employees"]["Row"]`.

4. **Regla d'Or: Internacionalització (i18n)**
   - Qualsevol text visible ha de passar per `react-i18next`.
   - S'ha de fer servir l'estructura de dos arguments OBLIGATÒRIAMENT: `{t('nomNamespace.clau', 'Text Fallback')}`.
   - Demano que, en generar el codi, especifiques el fiter de català `src/locales/ca/[nom-mòdul].json` d'exemple amb totes les traduccions requerides pel teu codi.

5. **Lògica de Dades (Sense Bypass de RLS):**
   - El front-end ha de parlar EXCLUSIVAMENT amb l'esquema `api` o mitjançant les funcions RPC del servidor si convé (per a canvis de pes o accions asíncrones PGMQ que ja estiguin definides al DB). Rescrigui: `.schema('api').from('vistes')`.
   - Tota acció d'inserció/modificació (CRUD normal) des d'aquest frontend es pot fer amb mutacions simples si RLS està ben configurat, però tingues clares les regles d'UI per a errors d'autorització.

**Passos a executar:**

1. Comença pel mòdul de **Departaments**:
   - Dissenya el file tree (`src/features/departments/...`).
   - Genera el codi pel servei d'api (`api.ts`).
   - Genera la vista principal (llistat i vista d'arbre) i el modal o formulari de creació/edició.
   - Proporciona el codi i el fiter JSON de traducció.
2. Després fes una pausa, i quan m'ho presentis, et demanaré continuar amb els següents mòduls d'un en un per no saltar el límit de tokens i mantenir atenció màxima als detalls.