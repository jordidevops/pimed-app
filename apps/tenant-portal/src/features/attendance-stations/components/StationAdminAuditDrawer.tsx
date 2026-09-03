import { Loader2 } from 'lucide-react'
import {
  Drawer,
  DrawerContent,
  DrawerDescription,
  DrawerHeader,
  DrawerTitle,
} from '@/components/ui/drawer'
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from '@/components/ui/table'
import type { AttendanceStationRow } from '../api/attendanceStationsService'
import {
  stationAdminAuditActionLabel,
  summarizeStationAdminAuditPayload,
} from '../api/stationAdminAuditService'
import { useStationAdminAudit } from '../api/useStationAdminAudit'

export interface StationAdminAuditDrawerProps {
  station: AttendanceStationRow | null
  open: boolean
  onOpenChange: (open: boolean) => void
}

export function StationAdminAuditDrawer({
  station,
  open,
  onOpenChange,
}: StationAdminAuditDrawerProps) {
  const deviceId = station?.id ?? null
  const { data: logs = [], isLoading, error } = useStationAdminAudit(deviceId, open)

  return (
    <Drawer open={open} onOpenChange={onOpenChange} direction="right">
      <DrawerContent className="fixed inset-y-0 right-0 left-auto top-0 mt-0 flex h-full w-full max-w-3xl flex-col rounded-none rounded-l-2xl border-l">
        <DrawerHeader className="shrink-0 border-b pb-4">
          <DrawerTitle>
            Auditoria d&apos;administració
            {station?.name ? ` — ${station.name}` : ''}
          </DrawerTitle>
          <DrawerDescription>
            Accions d&apos;administració sobre aquesta estació: codis d&apos;aparellament, registre,
            edicions i revocació de secret.
          </DrawerDescription>
        </DrawerHeader>

        <div className="min-h-0 flex-1 overflow-y-auto p-4 pt-2">
          {isLoading ? (
            <div className="flex justify-center py-16 text-muted-foreground">
              <Loader2 className="h-6 w-6 animate-spin" />
            </div>
          ) : error ? (
            <div className="rounded-lg border border-destructive/30 bg-destructive/5 p-4 text-sm text-destructive">
              {(error as Error).message}
            </div>
          ) : logs.length === 0 ? (
            <p className="rounded-lg border p-4 text-sm text-muted-foreground">
              Encara no hi ha registres d&apos;auditoria per aquesta estació.
            </p>
          ) : (
            <div className="overflow-hidden rounded-xl border">
              <Table>
                <TableHeader>
                  <TableRow>
                    <TableHead className="w-[160px]">Data</TableHead>
                    <TableHead className="w-[140px]">Usuari</TableHead>
                    <TableHead className="w-[180px]">Acció</TableHead>
                    <TableHead>Detalls</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {logs.map((log) => (
                    <TableRow key={log.id}>
                      <TableCell className="text-xs tabular-nums text-muted-foreground">
                        {new Date(log.created_at).toLocaleString()}
                      </TableCell>
                      <TableCell className="text-sm">
                        {log.user_name ?? (log.user_id ? log.user_id.slice(0, 8) : 'Sistema')}
                      </TableCell>
                      <TableCell className="text-sm font-medium">
                        {stationAdminAuditActionLabel(log.action)}
                      </TableCell>
                      <TableCell className="text-sm text-muted-foreground">
                        {summarizeStationAdminAuditPayload(log.action, log.payload)}
                      </TableCell>
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
            </div>
          )}
        </div>
      </DrawerContent>
    </Drawer>
  )
}
