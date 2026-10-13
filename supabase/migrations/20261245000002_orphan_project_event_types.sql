-- Allow orphan OS lifecycle events on commercial_document_events.
ALTER TABLE data.commercial_document_events
  DROP CONSTRAINT IF EXISTS commercial_document_events_event_type_check;

ALTER TABLE data.commercial_document_events
  ADD CONSTRAINT commercial_document_events_event_type_check
  CHECK (event_type IN (
    'issued', 'sent', 'viewed', 'accepted', 'rejected',
    'signed', 'superseded', 'cancelled', 'pdf_rendered', 'invoice_cancelled',
    'accounting_reviewed', 'accounting_changes_requested', 'included_in_export',
    'payment_recorded',
    'project_linked',
    'project_not_needed'
  ));
