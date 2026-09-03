import { useState } from 'react'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { CheckCircle, XCircle, UserCog } from 'lucide-react'
import { Button } from '@/components/ui/button'
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogFooter,
  DialogDescription,
} from '@/components/ui/dialog'
import { Textarea } from '@/components/ui/textarea'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { useToast } from '@/hooks/use-toast'
import { resolveApproval } from '../api/automationService'

export interface ApprovalDialogProps {
  approvalId: string
  title?: string
  contextPreview?: Record<string, unknown>
  open: boolean
  onClose: () => void
}

type Mode = 'default' | 'reassign'

export function ApprovalDialog({
  approvalId,
  title,
  contextPreview,
  open,
  onClose,
}: ApprovalDialogProps) {
  const { toast } = useToast()
  const queryClient = useQueryClient()
  const [comment, setComment] = useState('')
  const [reassignTo, setReassignTo] = useState('')
  const [mode, setMode] = useState<Mode>('default')

  const mutation = useMutation({
    mutationFn: ({
      resolution,
    }: {
      resolution: 'approved' | 'rejected' | 'reassigned'
    }) =>
      resolveApproval(
        approvalId,
        resolution,
        comment || undefined,
        resolution === 'reassigned' ? reassignTo : undefined,
      ),
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: ['automation'] })
      toast({ description: 'Aprovació processada correctament.' })
      onClose()
    },
    onError: () => {
      toast({
        variant: 'destructive',
        description: 'No s\'ha pogut processar l\'aprovació.',
      })
    },
  })

  function handleClose() {
    setComment('')
    setReassignTo('')
    setMode('default')
    onClose()
  }

  const contextEntries = contextPreview ? Object.entries(contextPreview) : []

  return (
    <Dialog open={open} onOpenChange={(o) => { if (!o) handleClose() }}>
      <DialogContent className="max-w-lg">
        <DialogHeader>
          <DialogTitle>{title ?? 'Revisió d\'aprovació'}</DialogTitle>
          <DialogDescription>
            Revisa la informació i tria una acció.
          </DialogDescription>
        </DialogHeader>

        {contextEntries.length > 0 && (
          <div className="rounded-lg border bg-muted/40 p-4 space-y-2 text-sm">
            <p className="font-medium text-xs uppercase tracking-wide text-muted-foreground">
              Context
            </p>
            {contextEntries.map(([key, val]) => (
              <div key={key} className="flex gap-2">
                <span className="text-muted-foreground shrink-0 min-w-[100px]">{key}:</span>
                <span className="font-medium break-all">
                  {typeof val === 'object' ? JSON.stringify(val) : String(val)}
                </span>
              </div>
            ))}
          </div>
        )}

        <div className="space-y-3">
          <Label htmlFor="approval-comment">Comentari (opcional)</Label>
          <Textarea
            id="approval-comment"
            rows={3}
            placeholder="Afegeix un comentari..."
            value={comment}
            onChange={(e) => setComment(e.target.value)}
          />
        </div>

        {mode === 'reassign' && (
          <div className="space-y-2">
            <Label htmlFor="reassign-user">ID d'usuari destinatari</Label>
            <Input
              id="reassign-user"
              placeholder="UUID de l'usuari"
              value={reassignTo}
              onChange={(e) => setReassignTo(e.target.value)}
            />
          </div>
        )}

        <DialogFooter className="flex-wrap gap-2 sm:justify-between">
          <div className="flex gap-2">
            {mode === 'default' ? (
              <Button
                type="button"
                variant="ghost"
                size="sm"
                onClick={() => setMode('reassign')}
                disabled={mutation.isPending}
              >
                <UserCog className="h-4 w-4" />
                Reassignar
              </Button>
            ) : (
              <Button
                type="button"
                variant="ghost"
                size="sm"
                onClick={() => setMode('default')}
                disabled={mutation.isPending}
              >
                Enrere
              </Button>
            )}
          </div>

          <div className="flex gap-2">
            <Button
              type="button"
              variant="outline"
              onClick={handleClose}
              disabled={mutation.isPending}
            >
              Cancel·lar
            </Button>

            {mode === 'reassign' ? (
              <Button
                type="button"
                onClick={() => mutation.mutate({ resolution: 'reassigned' })}
                disabled={mutation.isPending || !reassignTo.trim()}
              >
                <UserCog className="h-4 w-4" />
                Reassignar
              </Button>
            ) : (
              <>
                <Button
                  type="button"
                  variant="destructive"
                  onClick={() => mutation.mutate({ resolution: 'rejected' })}
                  disabled={mutation.isPending}
                >
                  <XCircle className="h-4 w-4" />
                  Rebutjar
                </Button>
                <Button
                  type="button"
                  onClick={() => mutation.mutate({ resolution: 'approved' })}
                  disabled={mutation.isPending}
                  className="bg-green-600 hover:bg-green-700 text-white"
                >
                  <CheckCircle className="h-4 w-4" />
                  Aprovar
                </Button>
              </>
            )}
          </div>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}
