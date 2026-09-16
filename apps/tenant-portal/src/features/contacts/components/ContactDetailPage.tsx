import { useState, useEffect } from 'react'
import { Link, useParams, useNavigate, useSearchParams } from 'react-router-dom'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import {
  ArrowLeft,
  Mail,
  Phone,
  MessageSquare,
  Archive,
  User,
  Calendar,
  Plus,
} from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Badge } from '@/components/ui/badge'
import { Tabs, TabsContent, TabsList, TabsTrigger } from '@/components/ui/tabs'
import { useToast } from '@/hooks/use-toast'
import { useTenant } from '@/contexts/TenantContext'
import { useIsFieldService } from '@/hooks/useSectorLabel'
import {
  getContact,
  getContactSites,
  archiveContact,
} from '../api/contactsService'
import { ContactSitesList } from './ContactSitesList'
import { ContactRelationshipsPanel } from './ContactRelationshipsPanel'
import { ContactDeliveryChannelsPanel } from './ContactDeliveryChannelsPanel'
import { ContactPortalAccessPanel } from './ContactPortalAccessPanel'
import { ContactCommercialHistory } from './ContactCommercialHistory'
import { EntityTimeline } from '@/features/entity-timeline'
import { getProjectsByClientId } from '@/features/projects/api/projectsService'
import {
  getProjectStatusClass,
  getProjectStatusLabel,
  getProjectStatusVariant,
} from '@/features/projects/projectStatus'

// ─── Avatar helpers (shared pattern) ─────────────────────────────────────────

const AVATAR_COLORS = [
  'bg-indigo-500', 'bg-violet-500', 'bg-pink-500', 'bg-rose-500',
  'bg-orange-500', 'bg-amber-500', 'bg-teal-500', 'bg-cyan-500',
  'bg-sky-500', 'bg-emerald-500',
]

function getAvatarColor(name: string): string {
  let hash = 0
  for (let i = 0; i < name.length; i++) hash = name.charCodeAt(i) + ((hash << 5) - hash)
  return AVATAR_COLORS[Math.abs(hash) % AVATAR_COLORS.length]
}

function getInitials(name: string): string {
  return name.split(' ').filter(Boolean).slice(0, 2).map((w) => w[0].toUpperCase()).join('')
}

function InfoRow({ icon, label, value }: { icon: React.ReactNode; label: string; value: React.ReactNode }) {
  return (
    <div className="flex items-start gap-2 text-sm">
      <span className="text-muted-foreground mt-0.5 shrink-0">{icon}</span>
      <span className="text-muted-foreground w-32 shrink-0">{label}</span>
      <span className="text-foreground">{value}</span>
    </div>
  )
}

const CONTACT_TABS = [
  'contact',
  'quotes',
  'sites',
  'projects',
  'activity',
  'comms',
  'portal_access',
] as const
type ContactTab = (typeof CONTACT_TABS)[number]

function isContactTab(value: string | null): value is ContactTab {
  return !!value && (CONTACT_TABS as readonly string[]).includes(value)
}

// ─── ContactDetailPage ────────────────────────────────────────────────────────

export function ContactDetailPage() {
  const { id } = useParams<{ id: string }>()
  const navigate = useNavigate()
  const [searchParams, setSearchParams] = useSearchParams()
  const highlightCommentId = searchParams.get('comment')
  const tabParam = searchParams.get('tab')
  const { t } = useTranslation(['contacts', 'projects', 'field-service'])
  const { toast } = useToast()
  const queryClient = useQueryClient()
  const { activeTenant } = useTenant()
  const isFieldService = useIsFieldService()
  const [archiveConfirmOpen, setArchiveConfirmOpen] = useState(false)

  const activeTab: ContactTab = isContactTab(tabParam)
    ? tabParam
    : highlightCommentId
      ? 'activity'
      : 'contact'

  function setTab(next: string) {
    const params = new URLSearchParams(searchParams)
    if (next === 'contact') params.delete('tab')
    else params.set('tab', next)
    setSearchParams(params, { replace: true })
  }

  const {
    data: contact,
    isLoading,
    error,
  } = useQuery({
    queryKey: ['contacts', id],
    queryFn: () => getContact(id!),
    enabled: !!id,
  })

  const { data: sites = [], isLoading: sitesLoading } = useQuery({
    queryKey: ['contact_sites', id],
    queryFn: () => getContactSites(id!),
    enabled: !!id,
  })

  const { data: clientProjects = [], isLoading: projectsLoading } = useQuery({
    queryKey: ['projects', 'by-client', id],
    queryFn: () => getProjectsByClientId(id!),
    enabled: !!id && activeTab === 'projects',
  })

  const archiveMut = useMutation({
    mutationFn: () => archiveContact(id!),
    onSuccess: () => {
      toast({ title: t('contacts.success.archived', 'Contacte arxivat correctament') })
      queryClient.invalidateQueries({ queryKey: ['contacts'] })
      navigate('/contacts')
    },
    onError: () => {
      toast({
        variant: 'destructive',
        title: t('contacts.errors.archive_failed', 'Error en arxivar el contacte'),
      })
    },
  })

  useEffect(() => {
    if (!highlightCommentId || activeTab !== 'activity') return
    const section = document.getElementById('contact-activity')
    section?.scrollIntoView({ behavior: 'smooth', block: 'start' })
  }, [highlightCommentId, contact?.id, activeTab])

  if (isLoading) {
    return (
      <div className="max-w-3xl mx-auto px-4 py-8 space-y-4">
        <div className="h-28 rounded-2xl bg-accent/40 animate-pulse" />
        <div className="h-40 rounded-2xl bg-accent/40 animate-pulse" />
        <div className="h-24 rounded-2xl bg-accent/40 animate-pulse" />
      </div>
    )
  }

  if (error || !contact) {
    return (
      <div className="max-w-3xl mx-auto px-4 py-8">
        <p className="text-sm text-destructive">
          {t('contacts.errors.load_failed', 'Error en carregar els contactes')}
        </p>
      </div>
    )
  }

  const name = contact.display_name ?? '?'
  const tags = contact.tags ?? []
  const projectsTabLabel = isFieldService
    ? t('contacts.detail.tab_orders', 'Ordres')
    : t('contacts.detail.tab_projects', 'Projectes')
  const projectDetailBase = isFieldService ? '/field/orders' : '/projects'

  const channelLabel: Record<string, string> = {
    email: t('contacts.channels.email', 'Email'),
    sms: t('contacts.channels.sms', 'SMS'),
    whatsapp: t('contacts.channels.whatsapp', 'WhatsApp'),
    none: t('contacts.channels.none', 'Cap'),
  }

  const sourceLabel: Record<string, string> = {
    manual: t('contacts.sources.manual', 'Manual'),
    import: t('contacts.sources.import', 'Importació'),
    web: t('contacts.sources.web', 'Web'),
    referral: t('contacts.sources.referral', 'Referència'),
  }

  const formattedDate = contact.created_at
    ? new Date(contact.created_at).toLocaleDateString('ca-ES', {
        day: 'numeric',
        month: 'long',
        year: 'numeric',
      })
    : '—'

  return (
    <div className="max-w-3xl mx-auto px-4 py-6 space-y-5">
      <button
        type="button"
        onClick={() => navigate('/contacts')}
        className="flex items-center gap-1.5 text-sm text-muted-foreground hover:text-foreground"
      >
        <ArrowLeft className="h-4 w-4" />
        {t('contacts.detail.back', 'Tornar als contactes')}
      </button>

      <div className="rounded-2xl border border-border bg-card p-5">
        <div className="flex items-start gap-4">
          <div
            className={`h-14 w-14 rounded-full ${getAvatarColor(name)} flex items-center justify-center text-white text-lg font-bold shrink-0`}
            aria-hidden
          >
            {getInitials(name)}
          </div>
          <div className="flex-1 min-w-0">
            <div className="flex flex-wrap items-center gap-2">
              <h1 className="text-xl font-bold text-foreground">{name}</h1>
              <span
                className={`px-2 py-0.5 rounded-full text-xs font-medium ${
                  contact.kind === 'company'
                    ? 'bg-blue-100 text-blue-700 dark:bg-blue-900/30 dark:text-blue-300'
                    : 'bg-emerald-100 text-emerald-700 dark:bg-emerald-900/30 dark:text-emerald-300'
                }`}
              >
                {contact.kind === 'company'
                  ? t('contacts.kind.company', 'Empresa')
                  : t('contacts.kind.person', 'Persona')}
              </span>
            </div>
            {tags.length > 0 && (
              <div className="flex flex-wrap gap-1 mt-2">
                {tags.map((tag) => (
                  <span
                    key={tag}
                    className="px-2 py-0.5 rounded-full bg-accent text-accent-foreground text-xs"
                  >
                    {tag}
                  </span>
                ))}
              </div>
            )}
          </div>

          <div className="flex gap-2 shrink-0">
            <Button
              variant="outline"
              size="sm"
              onClick={() => setArchiveConfirmOpen(true)}
              disabled={archiveMut.isPending}
            >
              <Archive className="h-4 w-4 mr-1.5" />
              {t('contacts.actions.archive', 'Arxivar')}
            </Button>
          </div>
        </div>
      </div>

      {archiveConfirmOpen && (
        <div className="rounded-xl border border-amber-200 bg-amber-50 dark:bg-amber-900/10 dark:border-amber-700 p-4 flex items-center justify-between gap-3">
          <p className="text-sm text-amber-800 dark:text-amber-300">
            {t('contacts.actions.archive_confirm', 'Confirmes que vols arxivar aquest contacte?')}
          </p>
          <div className="flex gap-2 shrink-0">
            <Button
              variant="outline"
              size="sm"
              onClick={() => setArchiveConfirmOpen(false)}
            >
              {t('contacts.form.cancel', 'Cancel·lar')}
            </Button>
            <Button
              variant="destructive"
              size="sm"
              onClick={() => archiveMut.mutate()}
              disabled={archiveMut.isPending}
            >
              {t('contacts.actions.archive', 'Arxivar')}
            </Button>
          </div>
        </div>
      )}

      <Tabs value={activeTab} onValueChange={setTab} className="space-y-4">
        <TabsList className="w-full justify-start overflow-x-auto">
          <TabsTrigger value="contact">
            {t('contacts.detail.tab_contact', 'Contacte')}
          </TabsTrigger>
          <TabsTrigger value="quotes">
            {t('contacts.detail.tab_quotes', 'Pressupostos')}
          </TabsTrigger>
          <TabsTrigger value="sites">
            {t('contacts.detail.tab_sites', "Adreces d'intervenció")}
          </TabsTrigger>
          <TabsTrigger value="projects">{projectsTabLabel}</TabsTrigger>
          <TabsTrigger value="activity">
            {t('contacts.detail.tab_activity', 'Activitat')}
          </TabsTrigger>
          <TabsTrigger value="comms">
            {t('contacts.detail.tab_comms', 'Comunicacions')}
          </TabsTrigger>
          <TabsTrigger value="portal_access">
            {t('contacts.detail.tab_portal_access', 'Portal')}
          </TabsTrigger>
        </TabsList>

        <TabsContent value="contact" className="space-y-4">
          <section className="rounded-2xl border border-border bg-card p-5 space-y-3">
            <h2 className="text-sm font-semibold text-foreground">
              {t('contacts.detail.contact_info', 'Informació de contacte')}
            </h2>
            {contact.email && (
              <InfoRow
                icon={<Mail className="h-4 w-4" />}
                label={t('contacts.fields.email', 'Correu electrònic')}
                value={
                  <a href={`mailto:${contact.email}`} className="text-indigo-600 hover:underline">
                    {contact.email}
                  </a>
                }
              />
            )}
            {contact.phone && (
              <InfoRow
                icon={<Phone className="h-4 w-4" />}
                label={t('contacts.fields.phone', 'Telèfon')}
                value={
                  <a href={`tel:${contact.phone}`} className="text-indigo-600 hover:underline">
                    {contact.phone}
                  </a>
                }
              />
            )}
            {contact.phone_alt && (
              <InfoRow
                icon={<Phone className="h-4 w-4" />}
                label={t('contacts.fields.phone_alt', 'Telèfon alternatiu')}
                value={
                  <a href={`tel:${contact.phone_alt}`} className="text-indigo-600 hover:underline">
                    {contact.phone_alt}
                  </a>
                }
              />
            )}
            {contact.preferred_channel && (
              <InfoRow
                icon={<MessageSquare className="h-4 w-4" />}
                label={t('contacts.fields.preferred_channel', 'Canal preferit')}
                value={channelLabel[contact.preferred_channel] ?? contact.preferred_channel}
              />
            )}
            {!contact.email && !contact.phone && !contact.phone_alt && !contact.preferred_channel && (
              <p className="text-sm text-muted-foreground">
                {t('contacts.detail.contact_empty', 'Sense dades de contacte')}
              </p>
            )}
          </section>

          <ContactRelationshipsPanel contactId={contact.id!} contactKind={contact.kind} />

          <ContactDeliveryChannelsPanel contactId={contact.id!} />

          <ContactCommercialHistory
            clientId={contact.id!}
            mode="summary"
            projectDetailBase={projectDetailBase}
            onSeeAll={() => setTab('quotes')}
          />

          <section className="rounded-2xl border border-border bg-card p-5 space-y-3">
            <h2 className="text-sm font-semibold text-foreground">
              {t('contacts.detail.additional_info', 'Informació addicional')}
            </h2>
            {contact.source && (
              <InfoRow
                icon={<User className="h-4 w-4" />}
                label={t('contacts.fields.source', 'Origen')}
                value={sourceLabel[contact.source] ?? contact.source}
              />
            )}
            {contact.owner_display_name && (
              <InfoRow
                icon={<User className="h-4 w-4" />}
                label={t('contacts.detail.owner', 'Responsable')}
                value={contact.owner_display_name}
              />
            )}
            <InfoRow
              icon={<Calendar className="h-4 w-4" />}
              label={t('contacts.detail.created_at', 'Creat el')}
              value={formattedDate}
            />
          </section>
        </TabsContent>

        <TabsContent value="quotes" className="space-y-4">
          <ContactCommercialHistory
            clientId={contact.id!}
            mode="full"
            projectDetailBase={projectDetailBase}
          />
        </TabsContent>

        <TabsContent value="sites" className="space-y-4">
          <section className="rounded-2xl border border-border bg-card p-5 space-y-3">
            <h2 className="text-sm font-semibold text-foreground">
              {t('contacts.detail.sites_title', "Adreces d'intervenció")}
            </h2>
            <ContactSitesList
              sites={sites}
              loading={sitesLoading}
              contactId={contact.id!}
              tenantId={activeTenant?.id ?? contact.tenant_id!}
              onChanged={() => {
                queryClient.invalidateQueries({ queryKey: ['contact_sites', id] })
                queryClient.invalidateQueries({ queryKey: ['contact_sites', 'tenant'] })
              }}
            />
          </section>
        </TabsContent>

        <TabsContent value="projects" className="space-y-4">
          <section className="rounded-2xl border border-border bg-card p-5 space-y-4">
            <div className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
              <div>
                <h2 className="text-sm font-semibold text-foreground">{projectsTabLabel}</h2>
                <p className="text-sm text-muted-foreground mt-1">
                  {isFieldService
                    ? t('contacts.detail.orders_hint', 'Crea una ordre de servei per aquest client')
                    : t('contacts.detail.projects_hint', 'Crea un projecte vinculat a aquest client')}
                </p>
              </div>
              <Button
                size="sm"
                className="gap-1.5 shrink-0"
                onClick={() => {
                  navigate(`${projectDetailBase}?create=1&client_id=${contact.id}`)
                }}
              >
                <Plus className="h-4 w-4" />
                {isFieldService
                  ? t('contacts.detail.new_order', 'Nova ordre')
                  : t('contacts.detail.new_project', 'Nou projecte')}
              </Button>
            </div>

            {projectsLoading ? (
              <p className="text-sm text-muted-foreground">
                {t('contacts.detail.projects_loading', 'Carregant…')}
              </p>
            ) : clientProjects.length === 0 ? (
              <p className="text-sm text-muted-foreground">
                {isFieldService
                  ? t('contacts.detail.orders_empty', 'Encara no hi ha ordres per aquest client')
                  : t('contacts.detail.projects_empty', 'Encara no hi ha projectes per aquest client')}
              </p>
            ) : (
              <ul className="divide-y divide-border rounded-xl border border-border overflow-hidden">
                {clientProjects.map((project) => (
                  <li key={project.id}>
                    <Link
                      to={`${projectDetailBase}/${project.id}`}
                      className="flex items-center justify-between gap-3 px-4 py-3 hover:bg-accent/40 transition-colors"
                    >
                      <div className="min-w-0">
                        <p className="text-sm font-medium truncate">{project.name}</p>
                        {project.planned_start && (
                          <p className="text-xs text-muted-foreground">
                            {new Date(project.planned_start).toLocaleDateString('ca-ES')}
                          </p>
                        )}
                      </div>
                      {project.status && (
                        <Badge
                          variant={getProjectStatusVariant(project.status)}
                          className={`text-xs shrink-0 ${getProjectStatusClass(project.status)}`}
                        >
                          {getProjectStatusLabel(t, project.status, { fieldService: isFieldService })}
                        </Badge>
                      )}
                    </Link>
                  </li>
                ))}
              </ul>
            )}
          </section>
        </TabsContent>

        <TabsContent value="activity" className="space-y-4">
          <section
            id="contact-activity"
            className="rounded-2xl border border-border bg-card p-5 space-y-3"
          >
            <h2 className="text-sm font-semibold text-foreground">
              {t('contacts.detail.activity_title', 'Activitat')}
            </h2>
            <EntityTimeline entityType="contact" entityId={contact.id!} />
          </section>
        </TabsContent>

        <TabsContent value="comms" className="space-y-4">
          <section className="rounded-2xl border border-border bg-card p-5 space-y-3">
            <h2 className="text-sm font-semibold text-foreground">
              {t('contacts.detail.comms_title', 'Comunicacions')}
            </h2>
            <p className="text-sm text-muted-foreground italic">
              {t('contacts.detail.comms_soon', 'Properament')}
            </p>
          </section>
        </TabsContent>

        <TabsContent value="portal_access" className="space-y-4">
          <ContactPortalAccessPanel
            contactId={contact.id!}
            contactKind={contact.kind}
            displayName={contact.display_name}
          />
        </TabsContent>
      </Tabs>
    </div>
  )
}
