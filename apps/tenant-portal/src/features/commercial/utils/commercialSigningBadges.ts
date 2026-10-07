import { signingProviderKind } from './commercialSigningHub'

export type CommercialSigningProviderBadge = 'native' | 'docuseal'
export type CommercialSigningChannelBadge = 'presential' | 'remote'

export function commercialSigningProviderBadge(
  provider: string | null | undefined,
): CommercialSigningProviderBadge | null {
  if (!provider) return null
  return signingProviderKind(provider)
}

export function commercialSigningChannelBadge(
  signingType: string | null | undefined,
): CommercialSigningChannelBadge | null {
  if (signingType === 'presential' || signingType === 'remote') return signingType
  return null
}

export function commercialSigningProviderLabelKey(
  badge: CommercialSigningProviderBadge,
): string {
  return badge === 'native'
    ? 'projects.commercial.badge_provider_native'
    : 'projects.commercial.badge_provider_docuseal'
}

export function commercialSigningChannelLabelKey(
  badge: CommercialSigningChannelBadge,
): string {
  return badge === 'presential'
    ? 'projects.commercial.badge_channel_presential'
    : 'projects.commercial.badge_channel_remote'
}
