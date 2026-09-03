import { useTranslation } from 'react-i18next'
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogDescription,
  DialogFooter,
} from '@/components/ui/dialog'
import {
  Table,
  TableHeader,
  TableBody,
  TableRow,
  TableHead,
  TableCell,
} from '@/components/ui/table'
import { Button } from '@/components/ui/button'
import type { DnsRecord, EmailDomain } from '../types'

interface DnsRecordsModalProps {
  domain: EmailDomain
  onClose: () => void
}

function isDnsRecordArray(value: unknown): value is DnsRecord[] {
  return Array.isArray(value) && value.length > 0 && typeof value[0].type === 'string'
}

export function DnsRecordsModal({ domain, onClose }: DnsRecordsModalProps) {
  const { t } = useTranslation('email')
  const records = domain.dns_records

  return (
    <Dialog open onOpenChange={(open) => { if (!open) onClose() }}>
      <DialogContent className="max-w-2xl">
        <DialogHeader>
          <DialogTitle>
            {t('email.domains.dns_records_title', 'Registres DNS per verificar')}
          </DialogTitle>
          <DialogDescription>{domain.domain}</DialogDescription>
        </DialogHeader>

        <p className="text-sm text-muted-foreground">
          {t(
            'email.domains.dns_instructions',
            "Afegeix els registres DNS següents al teu proveïdor de dominis (Cloudflare, GoDaddy, etc.) per verificar la propietat del domini.",
          )}
        </p>

        {isDnsRecordArray(records) ? (
          <div className="overflow-x-auto rounded-lg border">
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>{t('email.domains.dns_type', 'Tipus')}</TableHead>
                  <TableHead>{t('email.domains.dns_name', 'Nom')}</TableHead>
                  <TableHead>{t('email.domains.dns_value', 'Valor')}</TableHead>
                  <TableHead>TTL</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {records.map((rec, i) => (
                  <TableRow key={i}>
                    <TableCell>
                      <span className="inline-block rounded bg-muted px-2 py-0.5 font-mono text-xs font-semibold">
                        {rec.type}
                      </span>
                    </TableCell>
                    <TableCell className="font-mono text-xs break-all">{rec.name}</TableCell>
                    <TableCell className="font-mono text-xs break-all max-w-xs">{rec.value}</TableCell>
                    <TableCell className="text-xs text-muted-foreground">{rec.ttl ?? '—'}</TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </div>
        ) : (
          <div className="rounded-lg border border-amber-200 bg-amber-50 p-4">
            <p className="text-sm text-amber-800 mb-2">
              {t(
                'email.domains.dns_raw_notice',
                "Els registres DNS no segueixen el format esperat. Aquí tens el contingut en brut:",
              )}
            </p>
            <pre className="text-xs text-foreground bg-card rounded p-3 border overflow-x-auto">
              {JSON.stringify(records, null, 2)}
            </pre>
          </div>
        )}

        <DialogFooter className="flex-col items-start gap-3 sm:flex-col">
          <p className="text-xs text-muted-foreground">
            {t(
              'email.domains.dns_propagation_note',
              'La propagació DNS pot trigar entre 15 minuts i 48 hores. Un cop configurats els registres, torna a la llista i clica "Comprovar verificació".',
            )}
          </p>
          <Button onClick={onClose}>
            {t('email.domains.close', 'Tancar')}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}
