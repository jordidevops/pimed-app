-- EX-03.4 follow-up: eliminar overload antic d'assign_shift_slot (4 args)
-- CREATE OR REPLACE amb signatura nova no reemplaça l'antiga → ambigüitat.

DROP FUNCTION IF EXISTS api.assign_shift_slot(uuid, date, uuid, text);
