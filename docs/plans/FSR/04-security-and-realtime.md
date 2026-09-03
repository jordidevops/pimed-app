# FSR — Seguretat i Realtime (ADR)

> Part del pack [`README.md`](./README.md).  
> **Estat:** decisions d'arquitectura obligatòries abans de migracions calentes.

## Problema

Guest, cambrer (employee portal) i KDS **no** usen la sessió Supabase Auth del tenant-portal. Reutilitzar el patró `useNotificationsRealtime` (`postgres_changes` + JWT d'usuari) és incorrecte i perillós.

## Decisió: tres superfícies BFF/Edge

| Superfície | Patró de referència al repo | Mecànica |
|------------|------------------------------|----------|
| KDS tablet | attendance-station | `ops_devices` + Edge `ops-device-api` (nou), secret hashejat, cookie httpOnly path dedicat (p.ex. `/api/ops-device`) |
| Cambrer Sala | employee-portal-api | Rutes Edge + RPCs `employee_portal_dining_*`; **`site_id` al claim o gate de selecció** |
| Guest QR | inspect-api / station | Token opaca → Edge amb service_role; cookie/sessió curta; **cap** SELECT anon directe sobre `dining_*` |
| Maître | tenant-portal + Supabase Auth | RLS + permisos `dining.*` |

### Anti-patrons prohibits

- Anon key + RLS “filtre per token a la query” exposant `dining_order_items`.
- Posar el secret de dispositiu o guest token en `localStorage` en clar.
- Estendre `attendance_devices.type` per KDS (contamina HR).
- Publicar `dining_orders` + `dining_order_items` + `dining_sessions` a `supabase_realtime` amb UPDATEs d'ETA en cascada.

## Realtime: Broadcast + poll

Després de mutació exitosa a Edge/RPC:

1. Edge emet **Broadcast** a `dining:{site_id}` (staff/KDS) i/o `dining:{session_id}` (guest).
2. Clients subscriuen amb credencials del seu canal BFF (o canal Realtime autoritzat via Edge).
3. **Fallback:** poll cada 5s a KDS i Sala si Broadcast falla.
4. ETA: recalcular en canvi d'estat / nou item enviat; escriure com a molt `dining_sessions.eta_seconds` — no UPDATE massiu d'items.

## Amenaces i controls

| Amenaça | Control |
|---------|---------|
| Guest comanda a una altra taula | Token lligat a `session_id`; RPCs validen hash; cap llista de sessions |
| QR de paret etern | Només uneix a sessió `open`; sense sessió → “espera cambrer” |
| Enumeració de tokens | Tokens llargs, hash a DB, rate limit Edge |
| KDS alien | Parellament secret; cookie path tancat; heartbeat/`last_seen_at` |
| Cambrer multi-site sense context | Gate `site_id` obligatori abans de Sala |
| Tempesta Realtime en rush | Broadcast acotat; no trigger ETA en cascada |
| Fuga cross-tenant | `tenant_id` a totes les files; Edge resolveix tenant des del device/session, no del client |

## Secrets

- Guest token i device secret: hash a DB; plaintext només en cookie httpOnly o resposta d'emissió única (QR).
- Seguir regles de `secrets-and-encryption` del repo; no logar tokens.

## Checklist abans de merge Fase 1/2

- [ ] Cap política RLS que permeti a `anon` llegir `dining_*` per ID endevinable
- [ ] Totes les mutacions guest/KDS/Sala passen per Edge + RPC
- [ ] Prova d'aïllament: token sessió A no llegeix/escriu sessió B
- [ ] KDS sense secret vàlid → 401
- [ ] Poll fallback documentat i provat amb Broadcast desactivat
