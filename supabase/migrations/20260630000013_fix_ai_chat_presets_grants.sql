-- Fix: GRANT SELECT on data.ai_chat_presets (security_invoker view needs underlying table access)
GRANT SELECT ON data.ai_chat_presets TO authenticated;

NOTIFY pgrst, 'reload schema';
