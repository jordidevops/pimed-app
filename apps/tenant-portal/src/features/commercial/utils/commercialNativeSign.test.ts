import { describe, expect, it } from 'vitest'
import {
  buildCommercialNativeSignaturePayload,
  buildCommercialSigningLinkShareText,
  commercialNativeSignLink,
  commercialSignerRoleForAction,
  isAlreadyAppliedCommercialSigningError,
} from './commercialNativeSign'

describe('commercialNativeSign', () => {
  it('maps accept/delivery to stampable template roles', () => {
    expect(commercialSignerRoleForAction('accept')).toBe('client_accept')
    expect(commercialSignerRoleForAction('delivery')).toBe('client_delivery')
  })

  it('builds a native signature payload without staff_ui', () => {
    const payload = buildCommercialNativeSignaturePayload({
      action: 'accept',
      submissionId: 'sub-1',
      sessionId: 'sess-1',
      signingGroupId: 'grp-1',
    })
    expect(payload.method).toBe('native')
    expect(payload).not.toHaveProperty('staff_ui')
    expect(JSON.stringify(payload)).not.toContain('staff_ui')
    expect(payload.signing_submission_id).toBe('sub-1')
    expect(payload.signing_session_id).toBe('sess-1')
    expect(payload.signing_group_id).toBe('grp-1')
    expect(payload.role).toBe('client_accept')
  })

  it('omits submission id when the hub row is missing', () => {
    const payload = buildCommercialNativeSignaturePayload({
      action: 'delivery',
      sessionId: 'sess-3',
    })
    expect(payload).not.toHaveProperty('signing_submission_id')
    expect(payload.signing_session_id).toBe('sess-3')
    expect(payload.role).toBe('client_delivery')
  })

  it('treats QT-9 trigger races as already applied', () => {
    expect(
      isAlreadyAppliedCommercialSigningError(
        new Error('document_not_issuable_state:accepted'),
      ),
    ).toBe(true)
    expect(
      isAlreadyAppliedCommercialSigningError(
        new Error('document_not_rejectable_state:rejected'),
      ),
    ).toBe(true)
    expect(isAlreadyAppliedCommercialSigningError(new Error('stamp_failed'))).toBe(false)
  })

  it('builds a public /sign/:token URL', () => {
    expect(commercialNativeSignLink('abc123')).toMatch(/\/sign\/abc123$/)
    expect(commercialNativeSignLink('https://app.example/sign/tok')).toBe(
      'https://app.example/sign/tok',
    )
  })

  it('builds WhatsApp/email share text with the signing link', () => {
    const text = buildCommercialSigningLinkShareText({
      title: 'Pressupost',
      docNumber: 'PRE-1',
      signUrl: 'https://app.example/sign/tok',
    })
    expect(text).toContain('PRE-1')
    expect(text).toContain('https://app.example/sign/tok')
  })
})
