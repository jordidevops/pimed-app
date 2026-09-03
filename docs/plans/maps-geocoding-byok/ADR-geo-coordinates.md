# ADR — `GeoCoordinates` compartit és obligatori per a qualsevol entitat amb mapa

**Estat:** Acceptat. **Àmbit:** `apps/tenant-portal`. **Relacionat:** `docs/plans/maps-geocoding-byok/README.md` §0.2, §5.0.

## Decisió

Qualsevol entitat, nova o existent, que capturi una ubicació al mapa (adreça + lat/lng) **ha d'usar**:

1. `src/lib/geo/geoCoordinates.ts` — tipus `GeoCoordinates`/`StructuredAddress` i helpers `parseGeoCoordinates`, `buildGeoCoordinates`, `formatAddressLine`, `googleMapsUrlFromGeo`.
2. `src/components/maps/AddressLocationFields.tsx` — inputs d'adreça estructurada (carrer, número, ciutat, província, CP, país).
3. `src/components/maps/CoordinatePicker.tsx` — mapa, cerca, clic, "la meva ubicació", reverse geocode.

## Prohibit

- Guardar lat/lng dins `metadata` genèric o qualsevol camp JSON ad hoc que no sigui una columna `geo_coordinates` amb el shape de `GeoCoordinates`.
- Forkar `CoordinatePicker` o `AddressLocationFields` per a una entitat concreta.
- Escriure un parser d'adreça local (Nominatim/Google) fora de `geoCoordinates.ts`.
- Cridar el proxy de geocoding directament des del component sense passar per `useGeocoding` / `lib/maps/nominatim.ts` (que mai envia `provider_key`; el servidor el resol).

## Com adoptar-ho en una entitat nova

1. Columna `geo_coordinates jsonb` (o mirall en columnes SQL si cal cerca/filtre) que persisteixi exactament el shape de `GeoCoordinates`.
2. Formulari: `<CoordinatePicker />` + `<AddressLocationFields />`, sincronitzats amb `parseGeoCoordinates` (llegir) i `buildGeoCoordinates` (desar).
3. i18n: reutilitzar el namespace `maps` (`src/locales/{ca,es,en}/maps.json`); no crear claus pròpies per al picker.

## Per què

Evita divergència de UX i de shape entre `sites`, `locations`, `contact_sites` i futures entitats (assets, projectes amb obra, etc.), i garanteix que cap client controli el `provider_key` de geocoding (regla de seguretat §5.5 del pla).
