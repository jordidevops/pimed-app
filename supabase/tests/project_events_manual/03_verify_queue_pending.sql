-- Step 03: Inspect pending queue messages before processing the worker.

SELECT
  msg_id,
  read_ct,
  enqueued_at,
  message
FROM pgmq.q_project_events
WHERE message ->> 'project_id' = '52000000-0000-0000-0000-000000000001'
ORDER BY msg_id DESC;

SELECT *
FROM pgmq.metrics('project_events');
