import { useTranslation } from 'react-i18next'
import { useQuery } from '@tanstack/react-query'
import { searchMembersForMention } from '../api/timelineService'

interface MentionMemberDropdownProps {
  query: string
  onSelect: (member: { id: string; full_name: string }) => void
  /** Quan és dins d'un popup ja posicionat, no cal position:absolute */
  inline?: boolean
}

export function MentionMemberDropdown({ query, onSelect, inline }: MentionMemberDropdownProps) {
  const { t } = useTranslation('activity')

  const { data: members = [], isLoading } = useQuery({
    queryKey: ['mention-members', query],
    queryFn: () => searchMembersForMention(query, 8),
  })

  return (
    <div
      className={
        inline
          ? 'p-0'
          : 'absolute z-20 left-0 top-full mt-1 w-56 rounded-md border bg-popover shadow-md p-2'
      }
      onMouseDown={(e) => e.preventDefault()}
    >
      <p className="text-[10px] text-muted-foreground px-1 pb-1">
        {t('timeline.mention_hint', 'Selecciona un membre per mencionar-lo')}
      </p>
      <ul className="max-h-40 overflow-y-auto">
        {isLoading && (
          <li className="px-2 py-1 text-xs text-muted-foreground">
            {t('timeline.mention_loading', 'Carregant...')}
          </li>
        )}
        {!isLoading && members.length === 0 && (
          <li className="px-2 py-1 text-xs text-muted-foreground">
            {t('timeline.mention_empty', 'Cap membre trobat')}
          </li>
        )}
        {members.map((m) => (
          <li key={m.id}>
            <button
              type="button"
              className="w-full text-left px-2 py-1 text-xs rounded hover:bg-accent"
              onClick={() => onSelect({ id: m.id, full_name: m.full_name })}
            >
              {m.full_name}
            </button>
          </li>
        ))}
      </ul>
    </div>
  )
}
