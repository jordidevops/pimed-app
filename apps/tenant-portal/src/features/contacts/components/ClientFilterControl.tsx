import { useEffect, useMemo, useRef, useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import { Search, X } from 'lucide-react'
import { Input } from '@/components/ui/input'
import { Button } from '@/components/ui/button'
import { getContact, searchContacts } from '../api/contactsService'
import { cn } from '@/lib/utils'

export interface ClientFilterControlProps {
  value: string | null
  onChange: (clientId: string | null, displayName: string | null) => void
  disabled?: boolean
  className?: string
  /** Match sibling filter labels (QuotesPage / ProjectsPage). */
  labeled?: boolean
}

export function ClientFilterControl({
  value,
  onChange,
  disabled,
  className,
  labeled = true,
}: ClientFilterControlProps) {
  const { t } = useTranslation('projects')
  const [query, setQuery] = useState('')
  const [open, setOpen] = useState(false)
  const [knownName, setKnownName] = useState<string | null>(null)
  const rootRef = useRef<HTMLDivElement>(null)

  const selectedId = value?.trim() || null

  const { data: selectedContact } = useQuery({
    queryKey: ['contacts', 'by-id', selectedId],
    queryFn: () => getContact(selectedId!),
    enabled: !!selectedId,
  })

  const { data: searchHits = [] } = useQuery({
    queryKey: ['contacts', 'search', 'client-filter', query],
    queryFn: () => searchContacts({ q: query, limit: 20 }),
    enabled: !selectedId && !disabled && open,
  })

  useEffect(() => {
    if (!selectedId) {
      setKnownName(null)
      return
    }
    if (selectedContact?.display_name) {
      setKnownName(selectedContact.display_name)
    }
  }, [selectedId, selectedContact?.display_name])

  useEffect(() => {
    if (!open) return
    function onPointerDown(event: MouseEvent) {
      if (!rootRef.current?.contains(event.target as Node)) {
        setOpen(false)
      }
    }
    document.addEventListener('mousedown', onPointerDown)
    return () => document.removeEventListener('mousedown', onPointerDown)
  }, [open])

  const displayName = knownName ?? selectedContact?.display_name ?? selectedId
  const options = useMemo(() => searchHits.filter((c) => !!c.id), [searchHits])

  function clear() {
    setQuery('')
    setOpen(false)
    onChange(null, null)
  }

  const field = selectedId ? (
    <div className="flex h-10 items-center gap-1 rounded-md border border-input bg-background px-2">
      <span
        className="min-w-0 flex-1 truncate text-sm text-foreground"
        title={displayName ?? undefined}
      >
        {displayName}
      </span>
      <Button
        type="button"
        variant="ghost"
        size="icon"
        className="h-7 w-7 shrink-0"
        disabled={disabled}
        onClick={clear}
        aria-label={t('projects.filters.client_clear', 'Netejar client')}
      >
        <X className="h-3.5 w-3.5" />
      </Button>
    </div>
  ) : (
    <div className="relative" ref={rootRef}>
      <Search className="pointer-events-none absolute left-2.5 top-1/2 h-3.5 w-3.5 -translate-y-1/2 text-muted-foreground" />
      <Input
        value={query}
        disabled={disabled}
        onChange={(e) => {
          setQuery(e.target.value)
          setOpen(true)
        }}
        onFocus={() => setOpen(true)}
        placeholder={t('projects.filters.client', 'Client')}
        className="h-10 pl-8"
        aria-label={t('projects.filters.client_search', 'Cerca client…')}
        aria-expanded={open}
        aria-autocomplete="list"
        role="combobox"
      />
      {open ? (
        <ul
          className="absolute z-20 mt-1 max-h-56 w-full overflow-auto rounded-md border border-border bg-popover py-1 text-sm shadow-md"
          role="listbox"
        >
          {options.length === 0 ? (
            <li className="px-3 py-2 text-muted-foreground">
              {query.trim()
                ? t('projects.filters.client_empty', 'Cap resultat')
                : t('projects.filters.client_type', 'Escriu per cercar…')}
            </li>
          ) : (
            options.map((c) => (
              <li key={c.id!}>
                <button
                  type="button"
                  role="option"
                  className="flex w-full px-3 py-2 text-left hover:bg-accent"
                  onClick={() => {
                    setKnownName(c.display_name ?? null)
                    setQuery('')
                    setOpen(false)
                    onChange(c.id!, c.display_name ?? null)
                  }}
                >
                  <span className="truncate">{c.display_name}</span>
                </button>
              </li>
            ))
          )}
        </ul>
      ) : null}
    </div>
  )

  if (!labeled) {
    return <div className={cn('min-w-0', className)}>{field}</div>
  }

  return (
    <div className={cn('flex min-w-0 flex-col gap-1 text-xs text-muted-foreground', className)}>
      <span>{t('projects.filters.client', 'Client')}</span>
      {field}
    </div>
  )
}
