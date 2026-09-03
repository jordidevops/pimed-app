# Plan: SendEmailModal V1 + Wrapper Governance

## Goal
Implement in tenant-portal a reusable `SendEmailModal` with dual editing mode (`WYSIWYG` with TipTap + raw `HTML`), final preview with wrapper layout, template loading with `{{key}}` placeholders, interactive variable resolution, and send through `api.enqueue_email`.

The option to send without company wrapper must exist, but only for `owner` and `manager` users.

## Scope Summary
- Included in V1:
  - Reusable modal component for transactional emails.
  - Dual editor: WYSIWYG and HTML.
  - Wrapper toggle restricted by role.
  - Attachments list (from caller context).
  - Preview and placeholder resolution.
- Excluded from V1:
  - Full email operations center (shared drafts, campaigns, bulk, approvals, SLA workflows).

## Implementation Phases

### Phase A: Component contract and permission policy
1. Define component API:
   - `open`, `onClose`, `tenantId`, `contextVariables`, `attachments`, `defaultRecipients`, `defaultSubject`, `onSent`.
2. Add governance props:
   - `allowWrapperBypass` (resolved by caller role), `defaultApplyWrapper=true`.
3. UX rule:
   - If `allowWrapperBypass=false`, hide or disable wrapper bypass toggle and show info text.
4. Defensive payload rule:
   - If `allowWrapperBypass=false`, never send `layout_id=null`; always resolve tenant/site wrapper.

### Phase B: Dual editor (WYSIWYG + HTML)
1. Reuse existing TipTap component in:
   - `apps/tenant-portal/src/components/ui/RichTextEditor.tsx`
2. Add editor mode switch inside modal:
   - `WYSIWYG` / `HTML`.
3. Keep single source of truth:
   - `htmlBody` string as canonical value.
4. Roundtrip behavior:
   - Switching mode must not lose content.
5. Placeholder compatibility note:
   - In WYSIWYG, `{{key}}` is treated as literal text and usually preserved.
   - If formatting splits tokens, user can fix quickly in HTML mode.

### Phase C: Templates and placeholders
1. Load templates with `useEmailTemplates`.
2. On template select, fill:
   - `subject`, `html`, `text`.
3. Apply immediate partial substitution using `contextVariables`.
4. Detect pending placeholders with regex:
   - `/{{\s*([a-zA-Z0-9_.-]+)\s*}}/g`
5. Show "Pending variables" panel and input fields.
6. Recompute preview and final payload in real time.

### Phase D: Final preview and wrapper behavior
1. Reuse preview/layout approach from:
   - `EmailTemplateEditor`.
2. Compose final preview as:
   - rendered content + resolved wrapper + wrapper variables.
3. Render final output in sandboxed iframe.
4. For `owner|manager`:
   - allow "Do not apply wrapper" toggle with clear warning state.

### Phase E: Sending
1. Send with:
   - `supabase.rpc('enqueue_email', { payload })`
2. Payload includes:
   - `tenant_id`, `idempotency_key`, recipients, `subject`, `html_body`, `text_body`, `attachments`, `template_id`, `template_variables`, `layout_id` (governed by role policy).
3. Add UI states:
   - `sending`, `sent`, `error` + toast notifications.
4. i18n:
   - Add `email.compose.*` keys in `src/locales/ca/email.json` with fallback text in `t()`.

### Phase F: Progressive rollout
1. First integration point:
   - Documents flow (`DocumentRow`) with document attachment context.
2. Validate adoption and behavior.
3. Expand to other modules:
   - signing, storage, contacts.

## Relevant Files
- `apps/tenant-portal/src/components/ui/RichTextEditor.tsx`
- `apps/tenant-portal/src/features/email/components/EmailTemplateEditor.tsx`
- `apps/tenant-portal/src/features/email/components/EmailTemplatesTab.tsx`
- `apps/tenant-portal/src/features/email/api/useEmailTemplates.ts`
- `apps/tenant-portal/src/features/email/api/useEmailConfig.ts`
- `apps/tenant-portal/src/features/documents/components/DocumentRow.tsx`
- `apps/tenant-portal/src/hooks/usePermission.ts`
- `apps/tenant-portal/src/pages/SettingsPage.tsx`
- `supabase/migrations/20260415000002_email_system_core.sql`
- `docs/email.md`

## Verification Checklist
1. Placeholder persistence in WYSIWYG:
   - test `{{name}}`, `{{document_url}}` after save and mode switch.
2. Regex coverage:
   - test `{{contact.email}}`, `{{site-name}}` detection/substitution.
3. Wrapper restriction:
   - non owner/manager cannot send without wrapper (UI + payload).
4. Wrapper bypass for allowed roles:
   - owner/manager can disable wrapper and preview updates correctly.
5. End-to-end send:
   - email appears in history (`queued -> sent`).
6. i18n:
   - all visible strings use `t('email.compose.xxx', 'Fallback')`.

## Product Decisions
- Keep this as reusable component in V1 (recommended).
- Do not build full email center yet.
- Revisit "Email Center" only if operation needs appear:
  - shared drafts, queue operations, approvals, bulk campaigns, SLA controls.

## Future Hardening
1. Optional server-side enforcement for wrapper policy via dedicated RPC.
2. Add "Insert variable" helper in WYSIWYG toolbar to reduce token typos.
3. Add analytics events for usage and completion funnel.
