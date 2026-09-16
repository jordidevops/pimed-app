# Horari mòbil: contracte tècnic

L’autoservei d’Horari de `tenant-portal` i el portal públic de l’empleat són
canals d’accés diferents. El primer exigeix un usuari intern vinculat a un
empleat actiu i el permís `attendance.punch_own`; no cal activar el portal
públic per utilitzar-lo.

Els dos canals comparteixen les regles de domini de Postgres i els RPC
canònics:

- `record_time_punch` i `sync_time_punches` per al fitxatge;
- `resolve_work_day` per a l’horari resolt;
- la política central de motiu obligatori per als permisos;
- `get_vacation_entitlement`, limitat al mateix empleat o a
  `attendance.approve`.

La cua IndexedDB conserva un `client_op_id` estable. Un únic coordinador
autenticat la drena i la projecció local s’aplica immediatament a la pàgina
d’Horari i al giny d’Avui.
