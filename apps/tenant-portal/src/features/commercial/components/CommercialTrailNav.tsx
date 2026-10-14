import { Link } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { cn } from '@/lib/utils'
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from '@/components/ui/dropdown-menu'
import { Button } from '@/components/ui/button'

export type CommercialTrailLink = {
  kind: 'order' | 'quote' | 'agreement'
  label: string
  href: string | null
  active?: boolean
  missingLabel?: string
  /** Extra siblings when there is more than one quote/agreement — opens «Tots» menu. */
  siblings?: Array<{ label: string; href: string }>
}

type CommercialTrailNavProps = {
  links: CommercialTrailLink[]
  className?: string
}

export function CommercialTrailNav({ links, className }: CommercialTrailNavProps) {
  const { t } = useTranslation('projects')

  return (
    <nav
      aria-label={t('projects.commercial.trail_nav', 'Recorregut comercial')}
      className={cn(
        '-mx-1 flex max-w-full items-center gap-1.5 overflow-x-auto px-1 pb-0.5 [scrollbar-width:thin]',
        className,
      )}
    >
      {links.map((link, index) => (
        <span key={link.kind} className="inline-flex shrink-0 items-center gap-1.5">
          {index > 0 ? (
            <span className="text-muted-foreground" aria-hidden>
              ·
            </span>
          ) : null}
          {link.href ? (
            <Link
              to={link.href}
              className={cn(
                'inline-flex max-w-[14rem] items-center truncate rounded-full border px-2 py-0.5 text-[11px] font-medium transition sm:max-w-none',
                link.active
                  ? 'border-primary bg-primary/10 text-foreground'
                  : 'border-border text-muted-foreground hover:border-primary/40 hover:text-foreground',
              )}
              aria-current={link.active ? 'page' : undefined}
            >
              {link.label}
            </Link>
          ) : (
            <span className="inline-flex items-center rounded-full border border-dashed border-border px-2 py-0.5 text-[11px] text-muted-foreground">
              {link.missingLabel ?? link.label}
            </span>
          )}
          {link.siblings && link.siblings.length > 0 ? (
            <DropdownMenu modal={false}>
              <DropdownMenuTrigger asChild>
                <Button
                  type="button"
                  size="sm"
                  variant="ghost"
                  className="h-6 shrink-0 px-1.5 text-[11px] text-muted-foreground"
                >
                  {t('projects.commercial.trail_all', 'Tots')}
                </Button>
              </DropdownMenuTrigger>
              <DropdownMenuContent align="start">
                {link.siblings.map((sibling) => (
                  <DropdownMenuItem key={sibling.href} asChild>
                    <Link to={sibling.href}>{sibling.label}</Link>
                  </DropdownMenuItem>
                ))}
              </DropdownMenuContent>
            </DropdownMenu>
          ) : null}
        </span>
      ))}
    </nav>
  )
}
