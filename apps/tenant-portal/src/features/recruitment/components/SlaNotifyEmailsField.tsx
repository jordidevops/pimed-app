import { useMemo, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { X } from 'lucide-react'
import { Input } from '@/components/ui/input'
import { Button } from '@/components/ui/button'
import { useAuth } from '@/contexts/AuthContext'
import { useTenant } from '@/contexts/TenantContext'
import { useMembers } from '@/hooks/useMembers'

type Props = {
  emails: string[]
  onChange: (emails: string[]) => void
  disabled?: boolean
}

export function SlaNotifyEmailsField({ emails, onChange, disabled }: Props) {
  const { t } = useTranslation('recruitment')
  const { activeTenant } = useTenant()
  const { user } = useAuth()
  const { data: members = [] } = useMembers(activeTenant?.id ?? null, user?.id, 'active')
  const [search, setSearch] = useState('')
  const [manual, setManual] = useState('')

  const selectedSet = useMemo(
    () => new Set(emails.map((e) => e.toLowerCase())),
    [emails],
  )

  const filtered = useMemo(() => {
    const q = search.trim().toLowerCase()
    return members
      .filter((m) => m.email && !selectedSet.has(m.email.toLowerCase()))
      .filter((m) => {
        if (!q) return true
        return (
          (m.full_name ?? '').toLowerCase().includes(q) ||
          m.email.toLowerCase().includes(q)
        )
      })
      .slice(0, 6)
  }, [members, search, selectedSet])

  function addEmail(email: string) {
    const normalized = email.trim().toLowerCase()
    if (!normalized.includes('@') || selectedSet.has(normalized)) return
    onChange([...emails, normalized])
    setSearch('')
    setManual('')
  }

  function removeEmail(email: string) {
    onChange(emails.filter((e) => e.toLowerCase() !== email.toLowerCase()))
  }

  return (
    <div className="space-y-2">
      {emails.length > 0 && (
        <div className="flex flex-wrap gap-1.5">
          {emails.map((email) => {
            const member = members.find((m) => m.email.toLowerCase() === email.toLowerCase())
            return (
              <span
                key={email}
                className="inline-flex items-center gap-1 rounded-full border bg-muted/50 px-2 py-0.5 text-xs"
              >
                {member?.full_name ? `${member.full_name} · ${email}` : email}
                {!disabled && (
                  <button
                    type="button"
                    className="rounded-full p-0.5 hover:bg-muted"
                    onClick={() => removeEmail(email)}
                    aria-label={t('settings.remove_email')}
                  >
                    <X className="h-3 w-3" />
                  </button>
                )}
              </span>
            )
          })}
        </div>
      )}

      {!disabled && (
        <>
          <Input
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            placeholder={t('settings.sla_search_members')}
            className="h-8 text-sm"
          />
          {search.trim() && filtered.length > 0 && (
            <ul className="rounded-lg border bg-card text-sm shadow-sm">
              {filtered.map((m) => (
                <li key={m.id}>
                  <button
                    type="button"
                    className="flex w-full flex-col items-start px-3 py-2 text-left hover:bg-muted/50"
                    onClick={() => addEmail(m.email)}
                  >
                    <span className="font-medium">{m.full_name || m.email}</span>
                    <span className="text-xs text-muted-foreground">{m.email}</span>
                  </button>
                </li>
              ))}
            </ul>
          )}
          <div className="flex gap-2">
            <Input
              value={manual}
              onChange={(e) => setManual(e.target.value)}
              placeholder={t('settings.sla_manual_email')}
              className="h-8 text-sm"
              onKeyDown={(e) => {
                if (e.key === 'Enter') {
                  e.preventDefault()
                  addEmail(manual)
                }
              }}
            />
            <Button
              type="button"
              variant="outline"
              size="sm"
              className="h-8"
              onClick={() => addEmail(manual)}
            >
              {t('settings.add_email')}
            </Button>
          </div>
        </>
      )}
      <p className="text-xs text-muted-foreground">{t('settings.rights_sla_notify_emails_hint')}</p>
    </div>
  )
}
