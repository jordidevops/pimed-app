import { useState, type ReactNode } from 'react'
import { Check, Copy } from 'lucide-react'
import {
  Toast,
  ToastClose,
  ToastDescription,
  ToastProvider,
  ToastTitle,
  ToastViewport,
} from '@/components/ui/toast'
import { useToast } from '@/hooks/use-toast'
import { cn } from '@/lib/utils'

function nodeToPlainText(node: ReactNode): string {
  if (node == null || typeof node === 'boolean') return ''
  if (typeof node === 'string' || typeof node === 'number') return String(node)
  if (Array.isArray(node)) return node.map(nodeToPlainText).filter(Boolean).join('\n')
  if (typeof node === 'object' && node !== null && 'props' in node) {
    const props = (node as { props?: { children?: ReactNode } }).props
    return nodeToPlainText(props?.children)
  }
  return ''
}

function ToastCopyButton({
  title,
  description,
  destructive,
}: {
  title?: ReactNode
  description?: ReactNode
  destructive?: boolean
}) {
  const [copied, setCopied] = useState(false)
  const text = [nodeToPlainText(title), nodeToPlainText(description)]
    .filter(Boolean)
    .join('\n')
    .trim()
  if (!text) return null

  async function handleCopy() {
    try {
      await navigator.clipboard.writeText(text)
      setCopied(true)
      window.setTimeout(() => setCopied(false), 1500)
    } catch {
      // Fallback for older browsers / denied clipboard
      const ta = document.createElement('textarea')
      ta.value = text
      ta.style.position = 'fixed'
      ta.style.left = '-9999px'
      document.body.appendChild(ta)
      ta.select()
      try {
        document.execCommand('copy')
        setCopied(true)
        window.setTimeout(() => setCopied(false), 1500)
      } finally {
        document.body.removeChild(ta)
      }
    }
  }

  return (
    <button
      type="button"
      onClick={() => void handleCopy()}
      className={cn(
        'inline-flex h-8 w-8 shrink-0 items-center justify-center rounded-md border bg-transparent transition-colors',
        'hover:bg-secondary focus:outline-none focus:ring-2 focus:ring-ring focus:ring-offset-2',
        destructive &&
          'border-muted/40 hover:border-destructive/30 hover:bg-destructive/20 hover:text-destructive-foreground',
      )}
      title={copied ? 'Copiat' : 'Copiar per a suport'}
      aria-label={copied ? 'Copiat' : 'Copiar contingut de l’error'}
    >
      {copied ? <Check className="h-3.5 w-3.5" /> : <Copy className="h-3.5 w-3.5" />}
    </button>
  )
}

export function Toaster() {
  const { toasts } = useToast()

  return (
    <ToastProvider>
      {toasts.map(function ({ id, title, description, action, variant, ...props }) {
        const isDestructive = variant === 'destructive'
        return (
          <Toast key={id} variant={variant} {...props}>
            <div className="grid min-w-0 flex-1 gap-1">
              {title && <ToastTitle>{title}</ToastTitle>}
              {description && <ToastDescription>{description}</ToastDescription>}
            </div>
            <div className="flex shrink-0 items-center gap-1">
              {isDestructive ? (
                <ToastCopyButton
                  title={title}
                  description={description}
                  destructive
                />
              ) : null}
              {action}
            </div>
            <ToastClose />
          </Toast>
        )
      })}
      <ToastViewport />
    </ToastProvider>
  )
}
