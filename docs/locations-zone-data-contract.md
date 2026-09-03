# Contracte de Dades de Zona (Locations)

Aquest document defineix d'on surten les dades de la fitxa de zona a `tenant-portal /locations`, què és disponible avui i què es considera evolucio futura.

## Objectiu

Evitar ambiguitats en KPI de zona i permetre continuar la millora UX (arbre + floorplan + fitxa) sense bloquejar-nos per nous canvis de backend.

## Dades disponibles avui (MVP)

### 1) Estructura de zona
- Font: `api.locations`
- Camps clau: `id`, `parent_id`, `site_id`, `name`, `type`, `status`, `geo_coordinates`, `metadata`
- Us: arbre jerarquic, seleccio de zona, render al floorplan, context de subarbre.

### 2) Estat d'actius
- Font: `api.assets`
- Camps clau: `location_id`, `status`, `site_id`
- Us: comptadors per estat (`operational`, `repairing`, `down`, `retired`) dins la zona seleccionada + descendants.

### 3) Ocupacio operativa estimada
- Fonts: `api.projects` + `api.work_logs`
- Camps clau:
- `projects.location_id` per mapar projectes a zona
- `work_logs.status='open'`, `work_logs.project_id`, `work_logs.worker_id`
- Us: persones presents estimades = nombre de `worker_id` unics amb logs oberts en projectes de la zona/subarbre.

## KPI definits al MVP

### Aforament maxim
- Definicio MVP: `locations.metadata.capacity`
- Naturalesa: input funcional configurable per zona (encara no forma part d'un model dedicat)

### Ocupacio actual estimada
- Definicio MVP: recompte de treballadors unics amb `work_logs` oberts associats a projectes de la zona/subarbre
- Nota de permisos: pot ser parcial en rols no `owner/manager` per RLS de `work_logs`

### Percentatge d'us
- Formula:
- `percentatge_us = (ocupacio_actual_estimada / aforament_maxim) * 100`
- Si no hi ha `aforament_maxim`: `null` (UI mostra `N/D`)

## Dades futures (quan calgui precisio superior)

### F1. Aforament formalitzat
- Opcio A: mantenir `metadata.capacity` amb validacions fortes a frontend/backend
- Opcio B: afegir columna dedicada (`capacity`) a `data.locations`
- Criteri de canvi: necessitat de reporting fiable i validacio estricta multi-sistema

### F2. Ocupacio en temps real robusta
- Afegir agregacio server-side (RPC o vista materialitzada) per evitar joins client-side en arbres grans
- Separar metrica de "presencia operativa" vs "afluencia" si entren noves fonts (sensors, accessos, checkins externs)

### F3. Percentatge d'us contextual
- Metrica per franja horaria i per tipus de zona (planta/sala/exterior)
- Llindars de saturacio i alertes

## Decisions operatives

1. La UX nova de `/locations` no queda bloquejada per dades futures.
2. Els KPI actuals s'etiqueten com estimacio quan depenen de visibilitat RLS.
3. La formula de percentatge no aplica si no hi ha aforament definit.
4. El contracte es revisara quan s'introdueixi una font de presencia diferent de `work_logs`.

## Referencies tecniques

- `supabase/migrations/20260502000002_locations_assets.sql`
- `supabase/migrations/20260506000005_work_logs.sql`
- `apps/tenant-portal/src/features/locations/api/useLocationOperationalData.ts`
- `apps/tenant-portal/src/features/locations/components/LocationsPage.tsx`
