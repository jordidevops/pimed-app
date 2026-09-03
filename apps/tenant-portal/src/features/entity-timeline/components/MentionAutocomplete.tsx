import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import { MentionMemberDropdown } from './MentionMemberDropdown'

interface MentionAutocompleteProps {
  onSelect: (member: { id: string; full_name: string }) => void
}

export function MentionAutocomplete({ onSelect }: MentionAutocompleteProps) {
  const { t } = useTranslation('activity')
  const [open, setOpen] = useState(false)
  const [query, setQuery] = useState('')

  function handleSelect(member: { id: string; full_name: string }) {
    onSelect(member)
    setOpen(false)
    setQuery('')
  }

  return (
    <div className="relative">
      <button
        type="button"
        className="text-xs text-primary hover:underline"
        title={t('timeline.mention_button', 'Mencionar membre')}
        onClick={() => setOpen((v) => !v)}
      >
        @
      </button>
      {open && (
        <div className="absolute z-20 left-0 top-full mt-1 w-56 rounded-md border bg-popover shadow-md p-2 space-y-1">
          <input
            type="text"
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            placeholder={t('timeline.mention_search', 'Cercar membre...')}
            className="w-full rounded border border-input px-2 py-1 text-xs"
            autoFocus
          />
          <MentionMemberDropdown query={query} onSelect={handleSelect} inline />
        </div>
      )}
    </div>
  )
}
