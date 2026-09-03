# Signing Implementation Plan (Reviewed)

Date: 2026-05-20
Scope: tenant-portal + supabase migrations + edge functions
Status: Planned, pending implementation

## 1. Objectives

1. Add document-centric navigation and detail page at /documents/:id.
2. Show document title and link from Signing Center rows.
3. Support signature history per document version (multi-sign scenario).
4. Complete badge/status UX for all signing states.
5. Add robust audit PDF persistence and download access.
6. Keep permissions aligned with existing RLS rules.

## 2. Confirmed Current State

### 2.1 Routes
- /documents
- /documents/templates
- /documents/signing
- /documents/signing/:id
- Missing route: /documents/:id

### 2.2 Permissions (RLS)
- documents SELECT: any tenant member, optionally filtered by required_permissions.
- documents INSERT/UPDATE: owner/manager (global or site).
- documents DELETE: global owner/manager.
- signing_submissions SELECT: any tenant member.
- signing_submissions INSERT: owner/manager/member (viewer excluded).

### 2.3 Data Gaps in signing_submissions
- Missing source_document_id.
- Missing document_title snapshot.
- Missing audit_trail_storage_path.
- Signing Center currently cannot render reliable document link/title.

## 3. Implementation Phases

### Phase 1 - DB schema + API view
Create migration: supabase/migrations/20260520000001_signing_doc_and_audit.sql

Changes:
- Add source_document_id uuid references data.documents(id) on delete set null.
- Add document_title text.
- Add audit_trail_storage_path text.
- Add index idx_signing_submissions_doc on source_document_id.
- Update api.signing_submissions view to expose new columns.

After migration:
- Regenerate apps/tenant-portal/src/types/database.types.ts
- Copy to supabase/functions/_shared/database.types.ts (project rule).

### Phase 2 - sign-document-router snapshot fields
File: supabase/functions/sign-document-router/index.ts

Changes:
- Extend source resolver return type with documentId.
- For source_type=document_existing, persist source_document_id from active_documents.id.
- Persist document_title snapshot from resolved source name.
- For template-based flow, source_document_id stays null and document_title uses template locale name.

### Phase 3 - docuseal-webhook audit PDF
File: supabase/functions/docuseal-webhook/index.ts

Changes:
- Add attachAuditDocument helper.
- Detect audit/certificate file by name first.
- Fallback to documents[1] if list shape matches known payload behavior.
- Upload to documents/{tenantId}/audit/{submissionId}-audit.pdf.
- Update signing_submissions.audit_trail_storage_path.

### Phase 4 - Document detail route/page
Files:
- apps/tenant-portal/src/App.tsx
- apps/tenant-portal/src/features/documents/components/DocumentDetailPage.tsx (new)

Changes:
- Add route /documents/:id.
- Build detail page with:
  - header + back action
  - metadata summary
  - current version actions (preview/download/sign)
  - version history
  - signing history section (see Phase 5)
- Reuse existing document/signing modals where possible.

### Phase 5 - Signing history per document
File (new): apps/tenant-portal/src/features/signing/api/useDocumentSigningHistory.ts

Changes:
- Query signing_submissions by source_document_id.
- Order by created_at desc.
- Group/render by source_document_version_id in DocumentDetailPage.
- Surface link to /documents/signing/:id for each submission.

### Phase 6 - Badges for all states in document list
File: apps/tenant-portal/src/features/signing/api/useDocumentVersionSubmissionsBatch.ts

Changes:
- Remove active-only status filter.
- Keep best status per version with priority:
  - prefer active states if present
  - otherwise latest terminal state

File: apps/tenant-portal/src/features/documents/components/DocumentRow.tsx

Changes:
- Display badges for completed/declined/expired/cancelled/error.
- Reuse shared status color mapping.

### Phase 7 - Re-sign warning flow
File: apps/tenant-portal/src/features/documents/components/DocumentRow.tsx

Changes:
- If latest status is completed and user clicks sign, show warning modal.
- Actions:
  - View signature
  - Sign anyway
  - Cancel
- On re-sign, keep historical chain metadata (previous_completed_submission_id, re_sign_sequence).

### Phase 8 - Signing Center document column
File: apps/tenant-portal/src/features/signing/components/SigningCenterPage.tsx

Changes:
- Select source_document_id + document_title from signing_submissions.
- Add Document column:
  - link to /documents/:id when source_document_id exists
  - show title-only for template-origin submissions

### Phase 9 - Submission detail enhancements
File: apps/tenant-portal/src/features/signing/components/SigningSubmissionDetail.tsx

Changes:
- Show source document title + link to /documents/:id.
- If audit_trail_storage_path exists, show "Audit PDF" action (signed URL).

### Phase 10 - i18n updates (mandatory)
Files:
- apps/tenant-portal/src/locales/ca/documents.json
- apps/tenant-portal/src/locales/ca/signing.json

Rule:
- Any user-facing text must use t('namespace.key', 'Fallback text').

## 4. Acceptance Checklist

1. /documents/:id loads and includes document actions + version history + signing history.
2. Signing Center rows include document title and link when source document exists.
3. Document list badges show all terminal and active states correctly.
4. Re-sign warning modal appears for completed signatures.
5. Completed webhook processing stores signed PDF and audit PDF paths.
6. Submission detail can open audit PDF when available.
7. No permission regression for viewer/member/manager/owner roles.
8. Types regenerated in both required destinations.

## 5. Risks and Notes

- If source document is deleted, source_document_id may become null (expected with ON DELETE SET NULL).
- document_title is intentionally denormalized for audit/history consistency.
- Any migration touching data/api objects must keep grants intact when views are recreated.
- Existing folder docs/sigining appears misspelled; this plan is stored in docs/signing per requested path.
