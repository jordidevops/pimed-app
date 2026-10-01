import { describe, expect, it } from 'vitest'
import { agreementBlocksProjectWork } from './agreementWorkGate'

describe('agreementBlocksProjectWork', () => {
  it('blocks only a require_signed agreement that is not active', () => {
    expect(
      agreementBlocksProjectWork([
        { work_gate: 'none', status: 'pending_start' },
      ]),
    ).toBe(false)
    expect(
      agreementBlocksProjectWork([
        { work_gate: 'require_signed_agreement', status: 'pending_start' },
      ]),
    ).toBe(true)
    expect(
      agreementBlocksProjectWork([
        { work_gate: 'none', status: 'pending_start' },
        { work_gate: 'require_signed_agreement', status: 'active' },
      ]),
    ).toBe(false)
    expect(
      agreementBlocksProjectWork([
        { work_gate: 'require_signed_agreement', status: 'cancelled' },
      ]),
    ).toBe(false)
  })
})
