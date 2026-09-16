import { useEffect, useMemo, useState } from 'react'
import { useParams, useSearchParams } from 'react-router-dom'
import { useQuery } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import { Loader2 } from 'lucide-react'
import { useTenant } from '@/contexts/TenantContext'
import { usePermission } from '@/hooks/usePermission'
import { useProject } from '@/features/projects/api/useProject'
import { useCustomerPortalEffective } from '@/features/portal-entitlements'
import { getFileUrl } from '@/features/storage/api/storageService'
import {
  getActiveCirDraft,
  getCirReportForProject,
  getCirVersion,
  previewCirDraft,
} from '../api/customerInterventionReportsService'
import { fieldMediaKeys, listProjectBulletinMedia } from '../api/fieldMediaService'
import {
  BulletinClientPreview,
  type BulletinPreviewMediaItem,
} from './BulletinClientPreview'

const bulletinKeys = {
  root: (projectId: string) => ['bulletin', projectId] as const,
}

const EMPTY_MEDIA: Awaited<ReturnType<typeof listProjectBulletinMedia>> = []

export function BulletinStandalonePreviewPage() {
  const { id: projectId = '' } = useParams()
  const [searchParams] = useSearchParams()
  const { t } = useTranslation('field-service')
  const { activeTenant, selectedTenantId, setSelectedTenantId } = useTenant()
  const tenantFromUrl = searchParams.get('tenant')
  const tenantId = activeTenant?.id ?? ''
  const { data: project, isLoading: projectLoading } = useProject(projectId)
  const canPreview = usePermission(
    'field_service.reports.preview_as_customer',
    project?.site_id,
  )
  const { supportedLocales, defaultLocale } = useCustomerPortalEffective(activeTenant?.id)

  useEffect(() => {
    if (tenantFromUrl && tenantFromUrl !== selectedTenantId) {
      setSelectedTenantId(tenantFromUrl)
    }
  }, [tenantFromUrl, selectedTenantId, setSelectedTenantId])

  const [previewJson, setPreviewJson] = useState<Record<string, unknown> | null>(null)
  const [previewMedia, setPreviewMedia] = useState<BulletinPreviewMediaItem[]>([])
  const [previewDigest, setPreviewDigest] = useState<string | undefined>(undefined)
  const [previewLoading, setPreviewLoading] = useState(true)

  const { data, isLoading } = useQuery({
    queryKey: bulletinKeys.root(projectId),
    queryFn: async () => {
      const report = await getCirReportForProject(projectId)
      const draft = report ? await getActiveCirDraft(report.id) : null
      const version = report?.current_published_version_id
        ? await getCirVersion(report.current_published_version_id)
        : null
      return { report, draft, version }
    },
    enabled: Boolean(projectId && tenantId),
  })

  const { data: projectMedia = EMPTY_MEDIA } = useQuery({
    queryKey: [...fieldMediaKeys.photos(tenantId, projectId), 'bulletin-picker-v2'],
    queryFn: () => listProjectBulletinMedia(tenantId, projectId),
    enabled: Boolean(tenantId && projectId),
  })

  const draft = data?.draft ?? null
  const version = data?.version ?? null

  const locale = useMemo(() => {
    const supported = supportedLocales.length > 0 ? supportedLocales : ['ca', 'es', 'en']
    const fromDraft = draft?.locale
    if (fromDraft && supported.includes(fromDraft)) return fromDraft
    const tenantDefault = (defaultLocale || 'es').trim().toLowerCase()
    if (tenantDefault && supported.includes(tenantDefault)) return tenantDefault
    return 'es'
  }, [supportedLocales, defaultLocale, draft?.locale])

  useEffect(() => {
    if (projectLoading || isLoading || !tenantId) return
    if (!canPreview) {
      setPreviewLoading(false)
      return
    }

    let cancelled = false

    async function buildMedia(nodeIds: string[]): Promise<BulletinPreviewMediaItem[]> {
      const items: BulletinPreviewMediaItem[] = []
      for (const id of nodeIds) {
        const node = projectMedia.find((n) => n.id === id)
        if (!node) {
          items.push({
            id,
            name: id.slice(0, 8),
            contentType: 'application/octet-stream',
          })
          continue
        }
        const mime = node.mime_type ?? 'application/octet-stream'
        const canInline =
          mime === 'image/jpeg' ||
          mime === 'image/jpg' ||
          mime === 'image/png' ||
          mime === 'image/gif' ||
          mime === 'image/webp' ||
          mime === 'image/avif'
        let previewUrl: string | null = null
        let fileUrl: string | null = null
        if (tenantId) {
          try {
            const { url: downloadUrl } = await getFileUrl(node.id, 600, tenantId, true)
            fileUrl = downloadUrl
            if (canInline) {
              const { url: viewUrl } = await getFileUrl(node.id, 600, tenantId, false)
              previewUrl = viewUrl
            }
          } catch {
            previewUrl = null
            fileUrl = null
          }
        }
        items.push({
          id: node.id,
          name: node.name,
          contentType: mime,
          previewUrl,
          fileUrl,
        })
      }
      return items
    }

    function mediaIdsFromDraft(): string[] {
      const raw = draft?.selected_media
      if (!Array.isArray(raw)) return []
      const ids: string[] = []
      for (const item of raw) {
        if (!item || typeof item !== 'object') continue
        const id = (item as { file_node_id?: unknown }).file_node_id
        if (typeof id === 'string' && id) ids.push(id)
      }
      return ids
    }

    async function load() {
      setPreviewLoading(true)
      try {
        if (draft?.id && draft.status !== 'superseded') {
          const raw = await previewCirDraft(draft.id)
          const projection = (raw && typeof raw === 'object' ? raw : {}) as Record<string, unknown>
          const withTenant: Record<string, unknown> = { ...projection }
          if (!withTenant.tenant && activeTenant?.name) {
            withTenant.tenant = { name: activeTenant.name }
          }
          const media = await buildMedia(mediaIdsFromDraft())
          if (cancelled) return
          setPreviewJson(withTenant)
          setPreviewMedia(media)
          setPreviewDigest(undefined)
        } else if (version?.projection && typeof version.projection === 'object') {
          const ids: string[] = []
          const raw = version.media_manifest
          if (Array.isArray(raw)) {
            for (const item of raw) {
              if (!item || typeof item !== 'object') continue
              const id = (item as { file_node_id?: unknown }).file_node_id
              if (typeof id === 'string' && id) ids.push(id)
            }
          }
          const withTenant: Record<string, unknown> = {
            ...(version.projection as Record<string, unknown>),
          }
          if (!withTenant.tenant && activeTenant?.name) {
            withTenant.tenant = { name: activeTenant.name }
          }
          const media = await buildMedia(ids.length > 0 ? ids : mediaIdsFromDraft())
          if (cancelled) return
          setPreviewJson(withTenant)
          setPreviewMedia(media)
          setPreviewDigest(version.content_digest)
        } else if (!cancelled) {
          setPreviewJson(null)
          setPreviewMedia([])
        }
      } catch {
        if (!cancelled) {
          setPreviewJson(null)
          setPreviewMedia([])
        }
      } finally {
        if (!cancelled) setPreviewLoading(false)
      }
    }

    void load()
    return () => {
      cancelled = true
    }
  }, [
    projectLoading,
    isLoading,
    canPreview,
    draft?.id,
    draft?.status,
    draft?.selected_media,
    version?.id,
    version?.projection,
    version?.media_manifest,
    version?.content_digest,
    projectMedia.length,
    tenantId,
    activeTenant?.name,
  ])

  if (previewLoading || isLoading) {
    return (
      <div className="fixed inset-0 flex items-center justify-center bg-[#f7f4ef] text-muted-foreground">
        <Loader2 className="h-5 w-5 animate-spin" />
      </div>
    )
  }

  if (!canPreview || !previewJson) {
    return (
      <div className="fixed inset-0 flex items-center justify-center bg-[#f7f4ef] px-4 text-center text-sm text-muted-foreground">
        {t('bulletin.preview_empty', 'Sense contingut de preview.')}
      </div>
    )
  }

  return (
    <div className="fixed inset-0 overflow-y-auto overscroll-contain bg-[#f7f4ef]">
      <BulletinClientPreview
        projection={previewJson}
        locale={
          (typeof previewJson.locale === 'string' ? previewJson.locale : draft?.locale) || locale
        }
        tenantNameFallback={activeTenant?.name}
        documentTitle={project?.name}
        contentDigest={previewDigest}
        media={previewMedia}
        draftBanner={false}
      />
    </div>
  )
}
