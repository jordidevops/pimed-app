import type { ReactNode } from 'react'
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
  className,
}: SalesDataTableProps<T>) {
  const selectable = Boolean(onToggleRow)
  const selectedSet = new Set(selectedIds)
  const selectableRows = canSelectRow ? rows.filter(canSelectRow) : rows
  const allSelected =
    selectableRows.length > 0 && selectableRows.every((row) => selectedSet.has(getRowId(row)))
  const someSelected = selectableRows.some((row) => selectedSet.has(getRowId(row)))

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
            'overflow-hidden rounded-xl border border-border bg-card',
            compact && 'rounded-lg',
          )}
        >
          <Table>
            <TableHeader>
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
                  <TableHead key={col.id} className={col.className}>
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
                {rowActions ? <TableHead className="w-12 px-2" /> : null}
              </TableRow>
            </TableHeader>
            <TableBody>
              {rows.map((row) => {
                const id = getRowId(row)
                const checked = selectedSet.has(id)
                const canSelect = canSelectRow ? canSelectRow(row) : true
                const actions = rowActions?.(row) ?? []
                return (
                  <TableRow key={id} data-state={checked ? 'selected' : undefined}>
                    {selectable ? (
                      <TableCell className="px-3">
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
                      <TableCell key={col.id} className={col.className}>
                        {col.cell(row)}
                      </TableCell>
                    ))}
                    {rowActions ? (
                      <TableCell className="px-2 text-right">
                        {actions.length > 0 ? (
                          <DropdownMenu>
                            <DropdownMenuTrigger asChild>
                              <Button type="button" size="icon" variant="ghost" className="h-8 w-8">
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
