/*
  # signing_generate_only_snapshot_backfill

  Objectiu
  - Reclassificar snapshots històrics de generate_only que hagin quedat com a
    submissions "completed" per evitar falsos positius de "firmat digitalment".

  Criteri (conservador)
  - external_id amb patró "generate-only:%"
  - o metadata.generated_only_snapshot = true
  - i sense docuseal_submission_id (no són signatures reals de DocuSeal)

  Efecte
  - status          -> cancelled
  - status_reason   -> generate_only_snapshot
  - completed_at    -> NULL
  - last_event_at   -> COALESCE(last_event_at, now())
*/

DO $$
DECLARE
  v_rows integer := 0;
BEGIN
  UPDATE data.signing_submissions ss
  SET
    status = 'cancelled'::data.signing_submission_status,
    status_reason = 'generate_only_snapshot',
    completed_at = NULL,
    last_event_at = COALESCE(ss.last_event_at, now()),
    updated_at = now(),
    metadata = COALESCE(ss.metadata, '{}'::jsonb) || jsonb_build_object('generated_only_snapshot', true)
  WHERE
    ss.docuseal_submission_id IS NULL
    AND (
      ss.external_id LIKE 'generate-only:%'
      OR COALESCE((ss.metadata ->> 'generated_only_snapshot')::boolean, false)
    )
    AND (
      ss.status <> 'cancelled'::data.signing_submission_status
      OR ss.status_reason IS DISTINCT FROM 'generate_only_snapshot'
      OR ss.completed_at IS NOT NULL
    );

  GET DIAGNOSTICS v_rows = ROW_COUNT;
  RAISE NOTICE '[signing_generate_only_snapshot_backfill] rows_updated=%', v_rows;
END $$;
