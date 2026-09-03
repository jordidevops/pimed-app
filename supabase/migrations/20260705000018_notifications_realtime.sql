-- Notificacions in-app — Realtime per actualitzar el badge sense esperar el poll

ALTER PUBLICATION supabase_realtime ADD TABLE data.notifications;
