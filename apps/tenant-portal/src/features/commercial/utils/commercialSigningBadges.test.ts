import { describe, expect, it } from 'vitest'
import {
  commercialSigningChannelBadge,
  commercialSigningProviderBadge,
} from './commercialSigningBadges'

describe('commercialSigningBadges', () => {
  it('maps native and docuseal providers', () => {
    expect(commercialSigningProviderBadge('native')).toBe('native')
    expect(commercialSigningProviderBadge('docuseal')).toBe('docuseal')
    expect(commercialSigningProviderBadge(null)).toBeNull()
  })

  it('maps presential and remote channels', () => {
    expect(commercialSigningChannelBadge('presential')).toBe('presential')
    expect(commercialSigningChannelBadge('remote')).toBe('remote')
    expect(commercialSigningChannelBadge('other')).toBeNull()
  })
})
