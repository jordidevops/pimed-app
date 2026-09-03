import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogFooter,
} from '@/components/ui/dialog'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { Tabs, TabsList, TabsTrigger, TabsContent } from '@/components/ui/tabs'
import { Eye } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import type { EmailLog, EmailLogStatus } from '../types'

const STATUS_BADGE_CLASS: Record<EmailLogStatus, string> = {
  queued:
    'bg-muted text-muted-foreground border-0 hover:bg-muted',
  processing:
    'bg-blue-100 text-blue-700 border-0 hover:bg-blue-100 dark:bg-blue-950/50 dark:text-blue-400',
  sent:
    'bg-indigo-100 text-indigo-700 border-0 hover:bg-indigo-100 dark:bg-indigo-950/50 dark:text-indigo-400',
  delivered:
    'bg-green-100 text-green-700 border-0 hover:bg-green-100 dark:bg-green-950/50 dark:text-green-400',
  bounced:
    'bg-red-100 text-red-700 border-0 hover:bg-red-100 dark:bg-red-950/50 dark:text-red-400',
  failed:
    'bg-red-100 text-red-700 border-0 hover:bg-red-100 dark:bg-red-950/50 dark:text-red-400',
}

function Field({
  label,
  value,
}: {
  label: string
  value: React.ReactNode
}) {
  if (!value) return null
  return (
    <div className="grid grid-cols-[140px_1fr] gap-2 text-sm">
      <span className="text-muted-foreground font-medium shrink-0">{label}</span>
      <span className="break-all text-foreground">{value}</span>
    </div>
  )
}

interface EmailLogDetailModalProps {
  log: EmailLog | null
  open: boolean
  onClose: () => void
}

export function EmailLogDetailModal({
  log,
  open,
  onClose,
}: EmailLogDetailModalProps) {
  const { t } = useTranslation('email')
  const [showBodyConfirm, setShowBodyConfirm] = useState(false)
  const [showBody, setShowBody] = useState(false)
  const [isLoggingAudit, setIsLoggingAudit] = useState(false)

  if (!log) return null

  const hasBody = !!(log.html_body || log.text_body)

  async function handleBodyViewConfirm() {
    if (!log) return
    setIsLoggingAudit(true)
    try {
      // fire-and-forget: l'error no ha d'impedir veure el cos
      supabase.rpc('log_email_body_viewed', {
        p_email_log_id: log.id,
        p_portal: 'tenant-portal',
      }).then(({ error }) => {
        if (error) console.warn('[audit] log_email_body_viewed error:', error.message)
      })
    } finally {
      setIsLoggingAudit(false)
      setShowBodyConfirm(false)
      setShowBody(true)
    }
  }

  const formatDate = (iso: string | null) =>
    iso
      ? new Date(iso).toLocaleString('ca-ES', {
          dateStyle: 'medium',
          timeStyle: 'medium',
        })
      : null

  const joinAddresses = (arr: string[] | null | undefined) =>
    arr && arr.length > 0 ? arr.join(', ') : null

  return (
    <>
    <Dialog open={open} onOpenChange={(o) => !o && onClose()}>
      <DialogContent className="max-w-2xl max-h-[90vh] overflow-y-auto">
        <DialogHeader>
          <DialogTitle className="flex items-center gap-3 flex-wrap">
            <span className="truncate max-w-85">
              {log.subject ?? (
                <em className="text-muted-foreground font-normal">
                  {t('email.logs.no_subject', '(sense assumpte)')}
                </em>
              )}
            </span>
            <Badge className={STATUS_BADGE_CLASS[log.status]}>
              {t(`email.logs.status_${log.status}`, log.status)}
            </Badge>
            {log.is_dead_letter && (
              <span className="text-xs text-destructive font-medium">
                {t('email.logs.dead_letter', 'dead-letter')}
              </span>
            )}
          </DialogTitle>
        </DialogHeader>

        <div className="space-y-5 mt-2">
          {/* Capçaleres */}
          <section className="space-y-2 rounded-lg border bg-muted/30 p-4">
            <h3 className="text-xs font-semibold uppercase tracking-wide text-muted-foreground mb-3">
              {t('email.logs.modal_section_headers', 'Capçaleres')}
            </h3>
            <Field
              label={t('email.logs.modal_from', 'De')}
              value={
                log.from_name
                  ? `${log.from_name} <${log.from_email}>`
                  : log.from_email
              }
            />
            <Field
              label={t('email.logs.modal_to', 'Per a')}
              value={joinAddresses(log.to_emails)}
            />
            <Field
              label={t('email.logs.modal_cc', 'CC')}
              value={joinAddresses(log.cc_emails)}
            />
            <Field
              label={t('email.logs.modal_bcc', 'BCC')}
              value={joinAddresses(log.bcc_emails)}
            />
            <Field
              label={t('email.logs.modal_reply_to', 'Resposta a')}
              value={log.reply_to}
            />
          </section>

          {/* Dates */}
          <section className="space-y-2 rounded-lg border bg-muted/30 p-4">
            <h3 className="text-xs font-semibold uppercase tracking-wide text-muted-foreground mb-3">
              {t('email.logs.modal_section_timeline', 'Cronologia')}
            </h3>
            <Field
              label={t('email.logs.modal_created_at', 'Creat')}
              value={formatDate(log.created_at)}
            />
            <Field
              label={t('email.logs.modal_sent_at', 'Enviat')}
              value={formatDate(log.sent_at)}
            />
            <Field
              label={t('email.logs.modal_delivered_at', 'Entregat')}
              value={formatDate(log.delivered_at)}
            />
          </section>

          {/* Errors */}
          {(log.last_error || (log.error_history && log.error_history.length > 0)) && (
            <section className="space-y-2 rounded-lg border border-destructive/30 bg-destructive/5 p-4">
              <h3 className="text-xs font-semibold uppercase tracking-wide text-destructive mb-3">
                {t('email.logs.modal_section_errors', 'Errors')}
              </h3>
              {log.last_error && (
                <Field
                  label={t('email.logs.modal_last_error', 'Últim error')}
                  value={
                    <span className="font-mono text-xs text-destructive">
                      {log.last_error}
                    </span>
                  }
                />
              )}
              {log.error_history && log.error_history.length > 0 && (
                <div className="mt-2 space-y-1">
                  <span className="text-xs text-muted-foreground font-medium block mb-1">
                    {t('email.logs.modal_error_history', 'Historial d\'errors')}
                  </span>
                  {log.error_history.map((entry, i) => (
                    <div
                      key={i}
                      className="rounded bg-background border p-2 text-xs font-mono"
                    >
                      <span className="text-muted-foreground mr-2">
                        #{entry.attempt} · {formatDate(entry.at)}
                      </span>
                      <span className="text-destructive">{entry.error}</span>
                    </div>
                  ))}
                </div>
              )}
            </section>
          )}

          {/* Vista prèvia HTML (sandboxed) */}
          {hasBody && (
            <section className="space-y-2 pt-2">
              <Button
                type="button"
                variant="outline"
                size="sm"
                onClick={() => setShowBodyConfirm(true)}
                className="flex items-center gap-2"
              >
                <Eye className="size-4" />
                {t('email.logs.view_body_btn', 'Veure cos del correu')}
              </Button>
            </section>
          )}
        </div>
      </DialogContent>
    </Dialog>

    {/* Diàleg de confirmació: avís d'auditoria */}
    <Dialog open={showBodyConfirm} onOpenChange={(o) => !o && setShowBodyConfirm(false)}>
      <DialogContent className="max-w-sm">
        <DialogHeader>
          <DialogTitle>
            {t('email.logs.view_body_confirm_title', 'Consulta del cos del correu')}
          </DialogTitle>
        </DialogHeader>
        <div className="rounded-md border border-amber-200 bg-amber-50 px-4 py-3 text-sm text-amber-800">
          <p className="font-medium mb-1">
            {t('email.logs.view_body_audit_warning_title', 'Avís d\'auditoria')}
          </p>
          <p>
            {t(
              'email.logs.view_body_audit_warning_desc',
              "Accedir al contingut d'aquest correu deixarà un registre permanent a l'historial d'auditoria amb el vostre nom d'usuari i la data i hora actuals.",
            )}
          </p>
        </div>
        <DialogFooter className="mt-2">
          <Button variant="ghost" onClick={() => setShowBodyConfirm(false)}>
            {t('email.logs.view_body_cancel', 'Cancel·lar')}
          </Button>
          <Button onClick={handleBodyViewConfirm} disabled={isLoggingAudit}>
            {isLoggingAudit
              ? t('email.logs.view_body_logging', 'Registrant...')
              : t('email.logs.view_body_confirm_ok', 'Continuar')}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>

    {/* Modal: cos del correu */}
    <Dialog open={showBody} onOpenChange={(o) => !o && setShowBody(false)}>
      <DialogContent className="max-w-4xl max-h-[92vh] flex flex-col p-0 gap-0 overflow-hidden">
        <DialogHeader className="px-6 py-4 border-b shrink-0">
          <DialogTitle className="truncate text-base">
            {log.subject ?? (
              <em className="text-muted-foreground font-normal">
                {t('email.logs.no_subject', '(sense assumpte)')}
              </em>
            )}
          </DialogTitle>
          <p className="text-xs text-muted-foreground truncate mt-0.5">
            <span className="font-medium">{t('email.logs.modal_from', 'De')}:</span>{' '}
            {log.from_name ? `${log.from_name} <${log.from_email}>` : log.from_email}
            <span className="ml-3 font-medium">{t('email.logs.modal_to', 'Per a')}:</span>{' '}
            {log.to_emails?.join(', ')}
            {log.cc_emails && log.cc_emails.length > 0 && (
              <> <span className="ml-2 font-medium">CC:</span> {log.cc_emails.join(', ')}</>
            )}
          </p>
        </DialogHeader>

        <Tabs
          defaultValue={log.html_body ? 'preview' : 'text'}
          className="flex flex-col flex-1 min-h-0"
        >
          <TabsList className="mx-6 mt-3 mb-0 shrink-0 w-fit">
            <TabsTrigger value="preview" disabled={!log.html_body}>
              {t('email.logs.modal_body_tab_preview', 'Vista prèvia HTML')}
            </TabsTrigger>
            <TabsTrigger value="html" disabled={!log.html_body}>
              {t('email.logs.modal_body_tab_html', 'Codi HTML')}
            </TabsTrigger>
            <TabsTrigger value="text" disabled={!log.text_body}>
              {t('email.logs.modal_body_tab_text', 'Text pla')}
            </TabsTrigger>
          </TabsList>

          <TabsContent value="preview" className="flex-1 min-h-0 mt-3">
            {log.html_body && (
              <iframe
                title={t('email.logs.modal_preview_iframe', 'Vista prèvia de l\'email')}
                srcDoc={log.html_body}
                sandbox="allow-same-origin"
                className="w-full h-full border-0 bg-white"
                style={{ minHeight: '400px' }}
              />
            )}
          </TabsContent>

          <TabsContent value="html" className="flex-1 min-h-0 mt-3 overflow-auto">
            <pre className="px-6 pb-6 text-xs text-foreground leading-relaxed whitespace-pre-wrap break-all font-mono bg-muted/30 min-h-full">
              {log.html_body}
            </pre>
          </TabsContent>

          <TabsContent value="text" className="flex-1 min-h-0 mt-3 overflow-auto">
            <pre className="px-6 pb-6 text-sm text-foreground leading-relaxed whitespace-pre-wrap font-sans bg-muted/30 min-h-full">
              {log.text_body ?? <span className="italic text-muted-foreground">{t('email.logs.modal_body_no_content', 'No hi ha contingut de text pla.')}</span>}
            </pre>
          </TabsContent>
        </Tabs>
      </DialogContent>
    </Dialog>
    </>
  )
}
