-- Fix PGRST203: PostgREST no pot resoldre dues sobrecàrregues de get_entity_timeline.
-- Mantenim només la versió amb p_search (DEFAULT NULL).

DROP FUNCTION IF EXISTS api.get_entity_timeline(
  text, uuid, integer, timestamptz, uuid, boolean, boolean, timestamptz, timestamptz
);
