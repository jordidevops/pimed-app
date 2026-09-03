import { ClipboardCheck, ListTodo } from 'lucide-react'
import { cn } from '@/lib/utils'
import type { ChecklistKind } from '../api/checklistTemplatesService'

/** Visual cue shared across catalog + visit runtime: ToDo vs Review. */
export function ChecklistKindIcon({
  kind,
  className,
}: {
  kind: ChecklistKind | string | null | undefined
  className?: string
}) {
  const isReview = kind === 'review'
  const Icon = isReview ? ClipboardCheck : ListTodo
  return (
    <Icon
      className={cn(
        'h-4 w-4 shrink-0',
        isReview ? 'text-sky-600 dark:text-sky-400' : 'text-emerald-600 dark:text-emerald-400',
        className,
      )}
      aria-hidden
    />
  )
}
