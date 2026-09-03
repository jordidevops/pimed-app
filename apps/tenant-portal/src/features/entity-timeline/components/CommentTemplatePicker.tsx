import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import { useQuery } from '@tanstack/react-query'
import { FileText, Settings2 } from 'lucide-react'
import { Button } from '@/components/ui/button'
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from '@/components/ui/dropdown-menu'
import { useTenant } from '@/contexts/TenantContext'
import {
  listCommentTemplates,
  type CommentTemplate,
  type EntityTimelineType,
} from '../api/timelineService'
import { CommentTemplatesDialog } from './CommentTemplatesDialog'

interface CommentTemplatePickerProps {
  entityType: EntityTimelineType
  disabled?: boolean
  onApply: (template: CommentTemplate) => void
}

export function CommentTemplatePicker({
  entityType,
  disabled,
  onApply,
}: CommentTemplatePickerProps) {
  const { t } = useTranslation('activity')
  const { activeRole } = useTenant()
  const [manageOpen, setManageOpen] = useState(false)

  const canManage = activeRole === 'owner' || activeRole === 'manager'

  const { data: templates = [], isLoading } = useQuery({
    queryKey: ['comment-templates', entityType],
    queryFn: () => listCommentTemplates(entityType),
    staleTime: 60_000,
  })

  if (!isLoading && templates.length === 0 && !canManage) {
    return null
  }

  return (
    <>
      <DropdownMenu>
        <DropdownMenuTrigger asChild>
          <Button
            type="button"
            variant="ghost"
            size="sm"
            className="h-7 px-2 text-xs gap-1"
            disabled={disabled || isLoading}
            title={t('templates.picker_title', 'Plantilles de comentari')}
          >
            <FileText className="h-3.5 w-3.5" />
            {t('templates.picker_label', 'Plantilla')}
          </Button>
        </DropdownMenuTrigger>
        <DropdownMenuContent align="start" className="w-64">
          {isLoading && (
            <DropdownMenuItem disabled>
              {t('timeline.loading', 'Carregant...')}
            </DropdownMenuItem>
          )}
          {!isLoading && templates.length === 0 && (
            <DropdownMenuItem disabled>
              {t('templates.empty', 'Cap plantilla disponible.')}
            </DropdownMenuItem>
          )}
          {templates.map((template) => (
            <DropdownMenuItem
              key={template.id}
              onSelect={() => onApply(template)}
              className="flex flex-col items-start gap-0.5"
            >
              <span className="font-medium truncate w-full">{template.title}</span>
              {template.default_is_task && (
                <span className="text-[10px] text-muted-foreground">
                  {t('templates.task_badge', 'Tasca per defecte')}
                </span>
              )}
            </DropdownMenuItem>
          ))}
          {canManage && (
            <>
              <DropdownMenuSeparator />
              <DropdownMenuItem onSelect={() => setManageOpen(true)}>
                <Settings2 className="h-3.5 w-3.5 mr-2" />
                {t('templates.manage', 'Gestionar plantilles')}
              </DropdownMenuItem>
            </>
          )}
        </DropdownMenuContent>
      </DropdownMenu>

      {canManage && (
        <CommentTemplatesDialog open={manageOpen} onOpenChange={setManageOpen} />
      )}
    </>
  )
}
