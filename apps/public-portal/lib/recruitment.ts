import { createPortalClient } from './supabase'

export type PublicJobPostingListItem = {
  id: string
  title: string
  public_slug: string
  description: string | null
  opens_at: string | null
  closes_at: string | null
}

export type PublicJobPostingDetail = PublicJobPostingListItem & {
  privacy_policy_url: string | null
  default_max_retention_months: number
  retention_options_months: number[]
}

// RPCs not yet in generated Database types (REC-1).
// eslint-disable-next-line @typescript-eslint/no-explicit-any
function rpcClient() {
  return createPortalClient() as any
}

export async function listPublicJobPostings(
  publicSiteId: string,
): Promise<PublicJobPostingListItem[]> {
  const { data, error } = await rpcClient().rpc('list_public_job_postings', {
    p_public_site_id: publicSiteId,
  })
  if (error || !data) return []
  return data as PublicJobPostingListItem[]
}

export async function getPublicJobPosting(
  publicSiteId: string,
  slug: string,
): Promise<PublicJobPostingDetail | null> {
  const { data, error } = await rpcClient().rpc('get_public_job_posting', {
    p_public_site_id: publicSiteId,
    p_slug: slug,
  })
  if (error || !data) return null
  return data as PublicJobPostingDetail
}
