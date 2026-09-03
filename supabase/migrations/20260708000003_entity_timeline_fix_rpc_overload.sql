-- =============================================================================
-- Fix PGRST203: PostgREST no pot resoldre dues sobrecàrregues de get_entity_timeline.
-- La migració 20260708000002 va crear una signatura nova sense eliminar l'anterior.
-- =============================================================================

DROP FUNCTION IF EXISTS api.get_entity_timeline(
  text, uuid, integer, timestamptz, uuid, boolean, boolean, timestamptz, timestamptz, text, boolean, boolean
);

DROP FUNCTION IF EXISTS api.get_entity_timeline(
  text, uuid, integer, timestamptz, uuid, boolean, boolean, timestamptz, timestamptz, text, boolean
);

DROP FUNCTION IF EXISTS api.get_entity_timeline(
  text, uuid, integer, timestamptz, uuid, boolean, boolean, timestamptz, timestamptz
);

-- Re-assegura GRANT sobre la signatura canònica (playbooks / ai_context)
GRANT EXECUTE ON FUNCTION api.get_entity_timeline(
  text, uuid, integer, timestamptz, uuid, boolean, boolean, boolean, timestamptz, timestamptz, text, boolean, boolean
) TO authenticated;
