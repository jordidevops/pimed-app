import type { KeyboardEvent, ReactNode } from 'react'
import { MoreHorizontal } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Checkbox } from '@/components/ui/checkbox'
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from '@/components/ui/dropdown-menu'
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from '@/components/ui/table'
import { cn } from '@/lib/utils'
import type { ListDensity } from '@/hooks/useListDensity'

export type SalesDataTableColumn<T> = {
  id: string
  header: ReactNode
  sortable?: boolean
  className?: string
  cell: (row: T) => ReactNode
}

export type SalesDataTableRowAction = {
  key: string
  label: string
  onSelect: () => void
  disabled?: boolean
  destructive?: boolean
}

export type SalesDataTableProps<T> = {
  columns: SalesDataTableColumn<T>[]
  rows: T[]
  getRowId: (row: T) => string
  selectedIds?: string[]
  onToggleRow?: (row: T) => void
  onToggleAll?: (checked: boolean) => void
  canSelectRow?: (row: T) => boolean
  rowActions?: (row: T) => SalesDataTableRowAction[]
  bulkBar?: ReactNode
  countLabel?: ReactNode
  sortKey?: string | null
  sortDir?: 'asc' | 'desc'
  onSort?: (columnId: string) => void
  empty?: ReactNode
  compact?: boolean
  density?: ListDensity
  /** Highlighted row (inspector peek). */
  activeRowId?: string | null
  /** Row click / Space opens peek (not checkbox). */
  onRowActivate?: (row: T) => void
  className?: string
}

export function SalesDataTable<T>({
  columns,
  rows,
  getRowId,
  selectedIds = [],
  onToggleRow,
  onToggleAll,
  canSelectRow,
  rowActions,
  bulkBar,
  countLabel,
  sortKey,
  sortDir,
  onSort,
  empty,
  compact = false,
  density = 'comfortable',
  activeRowId = null,
  onRowActivate,
  className,
}: SalesDataTableProps<T>) {
  const selectable = Boolean(onToggleRow)
  const selectedSet = new Set(selectedIds)
  const selectableRows = canSelectRow ? rows.filter(canSelectRow) : rows
  const allSelected =
    selectableRows.length > 0 && selectableRows.every((row) => selectedSet.has(getRowId(row)))
  const someSelected = selectableRows.some((row) => selectedSet.has(getRowId(row)))
  const effectiveDensity = compact ? 'compact' : density

  function handleRowKeyDown(event: KeyboardEvent<HTMLTableRowElement>, row: T) {
    if (!onRowActivate) return
    if (event.key === ' ' || event.key === 'Enter') {
      event.preventDefault()
      onRowActivate(row)
    }
  }

  return (
    <div className={cn('space-y-3', className)}>
      <div className="flex flex-wrap items-center justify-between gap-2">
        {countLabel ? <div className="text-sm text-muted-foreground">{countLabel}</div> : <div />}
        {selectedIds.length > 0 && bulkBar ? bulkBar : null}
      </div>

      {rows.length === 0 ? (
        empty ?? null
      ) : (
        <div
          className={cn(
            'rounded-xl border border-border bg-card',
            effectiveDensity === 'compact' && 'rounded-lg',
          )}
        >
          <Table
            className="app-list-table"
            data-density={effectiveDensity}
          >
            <TableHeader className="[&_tr]:border-b-0">
              <TableRow>
                {selectable ? (
                  <TableHead className="w-10 px-3">
                    <Checkbox
                      checked={allSelected ? true : someSelected ? 'indeterminate' : false}
                      onCheckedChange={(value) => onToggleAll?.(value === true)}
                      aria-label="Select all"
                    />
                  </TableHead>
                ) : null}
                {columns.map((col) => (
                  <TableHead
                    key={col.id}
                    className={cn(
                      col.className,
                      effectiveDensity === 'compact' ? '!h-8 !py-1 !px-2.5 text-xs' : '!h-12 !py-3 !px-4',
                    )}
                  >
                    {col.sortable && onSort ? (
                      <button
                        type="button"
                        className="inline-flex items-center gap-1 hover:underline"
                        onClick={() => onSort(col.id)}
                      >
                        {col.header}
                        {sortKey === col.id ? (sortDir === 'asc' ? ' ↑' : ' ↓') : null}
                      </button>
                    ) : (
                      col.header
                    )}
                  </TableHead>
                ))}
                {rowActions ? (
                  <TableHead
                    className={cn(
                      'w-12',
                      effectiveDensity === 'compact' ? '!h-8 !px-1' : '!h-12 !px-2',
                    )}
                  />
                ) : null}
              </TableRow>
            </TableHeader>
            <TableBody>
              {rows.map((row) => {
                const id = getRowId(row)
                const checked = selectedSet.has(id)
                const canSelect = canSelectRow ? canSelectRow(row) : true
                const actions = rowActions?.(row) ?? []
                const isActive = activeRowId === id
                return (
                  <TableRow
                    key={id}
                    data-state={checked ? 'selected' : undefined}
                    tabIndex={onRowActivate ? 0 : undefined}
                    className={cn(
                      onRowActivate && 'cursor-pointer focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring',
                      isActive && 'bg-accent/60',
                    )}
                    onClick={
                      onRowActivate
                        ? (event) => {
                            const target = event.target as HTMLElement
                            if (
                              target.closest(
                                'a,button,input,label,[role="checkbox"],[role="menuitem"]',
                              )
                            ) {
                              return
                            }
                            onRowActivate(row)
                          }
                        : undefined
                    }
                    onKeyDown={(event) => handleRowKeyDown(event, row)}
                  >
                    {selectable ? (
                      <TableCell className="px-3" onClick={(e) => e.stopPropagation()}>
                        {canSelect || checked ? (
                          <Checkbox
                            checked={checked}
                            onCheckedChange={() => onToggleRow?.(row)}
                            aria-label={id}
                          />
                        ) : null}
                      </TableCell>
                    ) : null}
                    {columns.map((col) => (
                      <TableCell
                        key={col.id}
                        className={cn(
                          col.className,
                          effectiveDensity === 'compact'
                            ? '!py-1 !px-2.5 text-[0.8125rem] leading-snug'
                            : '!py-3 !px-4',
                        )}
                      >
                        {col.cell(row)}
                      </TableCell>
                    ))}
                    {rowActions ? (
                      <TableCell
                        className={cn(
                          'text-right',
                          effectiveDensity === 'compact' ? '!py-1 !px-1' : '!py-3 !px-2',
                        )}
                        onClick={(e) => e.stopPropagation()}
                      >
                        {actions.length > 0 ? (
                          <DropdownMenu>
                            <DropdownMenuTrigger asChild>
                              <Button
                                type="button"
                                size="icon"
                                variant="ghost"
                                className={effectiveDensity === 'compact' ? 'h-6 w-6' : 'h-8 w-8'}
                              >
                                <MoreHorizontal className="h-4 w-4" />
                                <span className="sr-only">Actions</span>
                              </Button>
                            </DropdownMenuTrigger>
                            <DropdownMenuContent align="end">
                              {actions.map((action) => (
                                <DropdownMenuItem
                                  key={action.key}
                                  disabled={action.disabled}
                                  className={action.destructive ? 'text-destructive' : undefined}
                                  onSelect={action.onSelect}
                                >
                                  {action.label}
                                </DropdownMenuItem>
                              ))}
                            </DropdownMenuContent>
                          </DropdownMenu>
                        ) : null}
                      </TableCell>
                    ) : null}
                  </TableRow>
                )
              })}
            </TableBody>
          </Table>
        </div>
      )}
    </div>
  )
}
