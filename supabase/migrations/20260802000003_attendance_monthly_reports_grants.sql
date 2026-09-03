-- La vista api.attendance_monthly_reports usa security_invoker; cal GRANT directe
-- sobre data.* (mateix patró que time_daily_summaries).

GRANT SELECT ON data.attendance_monthly_reports TO authenticated;

NOTIFY pgrst, 'reload schema';
