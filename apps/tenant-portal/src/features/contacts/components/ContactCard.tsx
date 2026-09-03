import { useTranslation } from 'react-i18next'
import { useNavigate } from 'react-router-dom'
import { Mail, MapPin, Phone } from 'lucide-react'
import type { Contact } from '../api/contactsService'

// ─── Avatar helpers ───────────────────────────────────────────────────────────

const AVATAR_COLORS = [
  'bg-indigo-500',
  'bg-violet-500',
  'bg-pink-500',
  'bg-rose-500',
  'bg-orange-500',
  'bg-amber-500',
  'bg-teal-500',
  'bg-cyan-500',
  'bg-sky-500',
  'bg-emerald-500',
]

function getAvatarColor(name: string): string {
  let hash = 0
  for (let i = 0; i < name.length; i++) {
    hash = name.charCodeAt(i) + ((hash << 5) - hash)
  }
  return AVATAR_COLORS[Math.abs(hash) % AVATAR_COLORS.length]
}

function getInitials(name: string): string {
  return name
    .split(' ')
    .filter(Boolean)
    .slice(0, 2)
    .map((w) => w[0].toUpperCase())
    .join('')
}

// ─── ContactCard ──────────────────────────────────────────────────────────────

export interface ContactCardSiteInfo {
  count: number
  mapsUrl: string | null
}

interface ContactCardProps {
  contact: Contact
  siteInfo?: ContactCardSiteInfo | null
}

export function ContactCard({ contact, siteInfo }: ContactCardProps) {
  const { t } = useTranslation('contacts')
  const navigate = useNavigate()

  const name = contact.display_name ?? '?'
  const avatarColor = getAvatarColor(name)
  const initials = getInitials(name)

  const tags = contact.tags ?? []
  const visibleTags = tags.slice(0, 3)
  const extraTags = tags.length - visibleTags.length
  const siteCount = siteInfo?.count ?? 0
  const mapsUrl = siteInfo?.mapsUrl ?? null

  return (
    <div className="relative rounded-2xl border border-border bg-card p-4 flex flex-col gap-3 hover:shadow-sm transition-shadow">
      {siteCount > 0 && mapsUrl && (
        <a
          href={mapsUrl}
          target="_blank"
          rel="noopener noreferrer"
          onClick={(e) => e.stopPropagation()}
          title={t('contacts.actions.open_maps', 'Obrir a Maps ({{count}} adreces)', {
            count: siteCount,
          })}
          aria-label={t('contacts.actions.open_maps', 'Obrir a Maps ({{count}} adreces)', {
            count: siteCount,
          })}
          className="absolute top-3 right-3 z-10 inline-flex h-8 w-8 items-center justify-center rounded-full border border-border bg-background text-muted-foreground shadow-sm hover:bg-accent hover:text-foreground transition-colors"
        >
          <MapPin className="h-3.5 w-3.5" />
          <span className="absolute -top-1 -right-1 min-w-4 h-4 px-1 rounded-full bg-indigo-600 text-white text-[10px] font-semibold leading-4 text-center">
            {siteCount > 99 ? '99+' : siteCount}
          </span>
        </a>
      )}

      {/* Header: avatar + name + kind badge */}
      <div className={`flex items-start gap-3 ${siteCount > 0 && mapsUrl ? 'pr-10' : ''}`}>
        <div
          className={`h-10 w-10 rounded-full ${avatarColor} flex items-center justify-center text-white text-sm font-semibold shrink-0`}
          aria-hidden
        >
          {initials}
        </div>
        <div className="flex-1 min-w-0">
          <p className="text-sm font-semibold text-foreground truncate">{name}</p>
          <span
            className={`inline-block mt-0.5 px-2 py-0.5 rounded-full text-[10px] font-medium ${
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
      </div>

      {/* Contact info */}
      <div className="space-y-1 text-xs text-muted-foreground">
        {contact.email && (
          <a
            href={`mailto:${contact.email}`}
            className="flex items-center gap-1.5 hover:text-foreground truncate"
            onClick={(e) => e.stopPropagation()}
          >
            <Mail className="h-3 w-3 shrink-0" />
            <span className="truncate">{contact.email}</span>
          </a>
        )}
        {contact.phone && (
          <a
            href={`tel:${contact.phone}`}
            className="flex items-center gap-1.5 hover:text-foreground"
            onClick={(e) => e.stopPropagation()}
          >
            <Phone className="h-3 w-3 shrink-0" />
            <span>{contact.phone}</span>
          </a>
        )}
      </div>

      {/* Tags */}
      {tags.length > 0 && (
        <div className="flex flex-wrap gap-1">
          {visibleTags.map((tag) => (
            <span
              key={tag}
              className="px-2 py-0.5 rounded-full bg-accent text-accent-foreground text-[10px] font-medium"
            >
              {tag}
            </span>
          ))}
          {extraTags > 0 && (
            <span className="px-2 py-0.5 rounded-full bg-accent text-muted-foreground text-[10px]">
              +{extraTags}
            </span>
          )}
        </div>
      )}

      {/* Action */}
      <button
        type="button"
        onClick={() => navigate(`/contacts/${contact.id}`)}
        className="mt-auto text-xs font-medium text-indigo-600 hover:text-indigo-700 text-left"
      >
        {t('contacts.actions.view', 'Veure detall')} →
      </button>
    </div>
  )
}
