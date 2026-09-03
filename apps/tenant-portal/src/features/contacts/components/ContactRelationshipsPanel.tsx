import { useMemo, useState } from 'react'
import { Link } from 'react-router-dom'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import { Link2, UserMinus } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { useToast } from '@/hooks/use-toast'
import {
  createContactRelationship,
  listContactRelationships,
  revokeContactRelationship,
  searchContacts,
  type Contact,
  type ContactRelationshipRole,
} from '../api/contactsService'

const ROLES: ContactRelationshipRole[] = [
  'primary',
  'billing',
  'operations',
  'other',
]

interface Props {
  contactId: string
  contactKind: string | null
}

export function ContactRelationshipsPanel({ contactId, contactKind }: Props) {
  const { t } = useTranslation('contacts')
  const { toast } = useToast()
  const queryClient = useQueryClient()
  const isCompany = contactKind === 'company'
  const [personId, setPersonId] = useState('')
  const [orgId, setOrgId] = useState('')
  const [role, setRole] = useState<ContactRelationshipRole>('primary')
  const [search, setSearch] = useState('')

  const queryKey = ['contact_relationships', contactId, contactKind]

  const { data: relationships = [], isLoading } = useQuery({
    queryKey,
    queryFn: () =>
      listContactRelationships(
        isCompany
          ? { organizationContactId: contactId }
          : { personContactId: contactId },
      ),
  })

  const { data: candidates = [] } = useQuery({
    queryKey: ['contacts', 'rel-candidates', isCompany ? 'person' : 'company', search],
    queryFn: () =>
      searchContacts({
        kind: isCompany ? 'person' : 'company',
        q: search,
        limit: 40,
      }),
  })

  const options = useMemo(
    () =>
      candidates.filter((c: Contact) =>
        isCompany ? c.kind === 'person' : c.kind === 'company',
      ),
    [candidates, isCompany],
  )

  const selectedId = isCompany ? personId : orgId

  const createMut = useMutation({
    mutationFn: () =>
      createContactRelationship({
        organizationContactId: isCompany ? contactId : orgId,
        personContactId: isCompany ? personId : contactId,
        role,
      }),
    onSuccess: () => {
      toast({
        title: t('contacts.relationships.created', 'Relació creada'),
      })
      setPersonId('')
      setOrgId('')
      setSearch('')
      queryClient.invalidateQueries({ queryKey })
    },
    onError: (err: Error) => {
      toast({
        variant: 'destructive',
        title: t('contacts.relationships.create_failed', 'No s\'ha pogut crear la relació'),
        description: err.message,
      })
    },
  })

  const revokeMut = useMutation({
    mutationFn: (id: string) =>
      revokeContactRelationship(
        id,
        t('contacts.relationships.revoke_reason_default', 'Offboarding manual'),
      ),
    onSuccess: () => {
      toast({
        title: t('contacts.relationships.revoked', 'Relació desvinculada'),
      })
      queryClient.invalidateQueries({ queryKey })
    },
    onError: () => {
      toast({
        variant: 'destructive',
        title: t('contacts.relationships.revoke_failed', 'No s\'ha pogut desvincular'),
      })
    },
  })

  function handleRevoke(id: string, name: string | null) {
    const ok = window.confirm(
      t(
        'contacts.relationships.revoke_confirm',
        'Desvincular {{name}}? Pot afectar invitacions i comparticions del portal.',
        { name: name || '…' },
      ),
    )
    if (!ok) return
    revokeMut.mutate(id)
  }

  const roleLabel = (r: string) => t(`contacts.relationships.roles.${r}`, r)

  return (
    <section className="rounded-2xl border border-border bg-card p-5 space-y-4">
      <div>
        <h2 className="text-sm font-semibold text-foreground flex items-center gap-2">
          <Link2 className="h-4 w-4" />
          {isCompany
            ? t('contacts.relationships.title_company', 'Persones relacionades')
            : t('contacts.relationships.title_person', 'Empreses relacionades')}
        </h2>
        <p className="text-xs text-muted-foreground mt-1">
          {t(
            'contacts.relationships.hint',
            'Afiliació empresa–persona per shares i portal. Desvincular no esborra evidència.',
          )}
        </p>
      </div>

      {isLoading ? (
        <p className="text-sm text-muted-foreground">{t('contacts.detail.projects_loading', 'Carregant…')}</p>
      ) : relationships.length === 0 ? (
        <p className="text-sm text-muted-foreground">
          {t('contacts.relationships.empty', 'Cap relació activa')}
        </p>
      ) : (
        <ul className="divide-y divide-border rounded-xl border border-border overflow-hidden">
          {relationships.map((rel) => {
            const relatedId = isCompany ? rel.person_contact_id : rel.organization_contact_id
            const relatedName = isCompany
              ? rel.person_display_name
              : rel.organization_display_name
            return (
              <li
                key={rel.id}
                className="flex items-center justify-between gap-3 px-4 py-3"
              >
                <div className="min-w-0">
                  <Link
                    to={`/contacts/${relatedId}`}
                    className="text-sm font-medium truncate text-indigo-600 hover:underline block"
                  >
                    {relatedName ?? relatedId.slice(0, 8)}
                  </Link>
                  <p className="text-xs text-muted-foreground">
                    {roleLabel(rel.role)}
                  </p>
                </div>
                <Button
                  type="button"
                  variant="outline"
                  size="sm"
                  className="shrink-0 gap-1.5"
                  disabled={revokeMut.isPending}
                  onClick={() => handleRevoke(rel.id, relatedName)}
                >
                  <UserMinus className="h-3.5 w-3.5" />
                  {t('contacts.relationships.revoke', 'Desvincular')}
                </Button>
              </li>
            )
          })}
        </ul>
      )}

      <div className="space-y-2">
        <label className="block text-xs space-y-1">
          <span className="text-muted-foreground">
            {isCompany
              ? t('contacts.relationships.pick_person', 'Persona')
              : t('contacts.relationships.pick_company', 'Empresa')}
          </span>
          <Input
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            placeholder={t('contacts.relationships.search_placeholder', 'Cerca per nom…')}
          />
        </label>
        {search.trim() && options.length > 0 && (
          <ul className="max-h-40 overflow-y-auto rounded-lg border border-border divide-y divide-border">
            {options.map((c) => (
              <li key={c.id!}>
                <button
                  type="button"
                  className={`w-full text-left px-3 py-2 text-sm hover:bg-accent/50 ${
                    selectedId === c.id ? 'bg-accent/40 font-medium' : ''
                  }`}
                  onClick={() => {
                    if (isCompany) setPersonId(c.id!)
                    else setOrgId(c.id!)
                  }}
                >
                  {c.display_name}
                </button>
              </li>
            ))}
          </ul>
        )}
        {selectedId && (
          <p className="text-xs text-muted-foreground">
            {t('contacts.relationships.selected', 'Seleccionat')}:{' '}
            {options.find((c) => c.id === selectedId)?.display_name ?? selectedId.slice(0, 8)}
          </p>
        )}
        <div className="flex flex-col gap-2 sm:flex-row sm:items-end">
          <label className="sm:w-40 text-xs space-y-1">
            <span className="text-muted-foreground">
              {t('contacts.relationships.role', 'Rol')}
            </span>
            <select
              className="w-full rounded-lg border border-border bg-background px-3 py-2 text-sm"
              value={role}
              onChange={(e) => setRole(e.target.value as ContactRelationshipRole)}
            >
              {ROLES.map((r) => (
                <option key={r} value={r}>
                  {roleLabel(r)}
                </option>
              ))}
            </select>
          </label>
          <Button
            type="button"
            size="sm"
            disabled={createMut.isPending || !selectedId}
            onClick={() => createMut.mutate()}
          >
            {t('contacts.relationships.add', 'Afegir')}
          </Button>
        </div>
      </div>
    </section>
  )
}
