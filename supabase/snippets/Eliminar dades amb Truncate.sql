-- TRUNCATE esborra totes les files d'una taula d'un cop
-- RESTART IDENTITY — reinicia els comptadors de les seqüències (els SERIAL/BIGSERIAL tornen a 1). Sense això, si tenies files fins a l'ID 50 i fas TRUNCATE, el proper insert seria ID 51 en lloc de 1.
-- CASCADE — esborra automàticament les files de les taules que tenen una foreign key apuntant a les taules llistades. Sense CASCADE fallaria si hi ha dades relacionades en altres taules.
TRUNCATE 
  data.notes,
  data.tenant_members,
  data.subscriptions,
  data.tenants,
  data.profiles,
  data.plans
RESTART IDENTITY CASCADE;