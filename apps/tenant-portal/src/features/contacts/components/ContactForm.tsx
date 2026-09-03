import { useState, KeyboardEvent } from 'react'
import { useForm } from 'react-hook-form'
import { zodResolver } from '@hookform/resolvers/zod'
import { z } from 'zod'
import { useTranslation } from 'react-i18next'
import { X } from 'lucide-react'
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { createContact, type CreateContactParams } from '../api/contactsService'
import { useToast } from '@/hooks/use-toast'

// ─── Schema ───────────────────────────────────────────────────────────────────

const contactSchema = z.object({
  kind: z.enum(['person', 'company']),
  display_name: z.string().min(1, 'errors.display_name_required'),
  given_name: z.string().optional(),
  family_name: z.string().optional(),
  legal_name: z.string().optional(),
  tax_id: z.string().optional(),
  email: z.string().optional(),
  phone: z.string().optional(),
  phone_alt: z.string().optional(),
  preferred_channel: z.enum(['email', 'sms', 'whatsapp', 'none']).optional(),
  source: z.enum(['manual', 'import', 'web', 'referral']),
})

type ContactFormValues = z.infer<typeof contactSchema>

// ─── ContactForm ──────────────────────────────────────────────────────────────

interface ContactFormProps {
  open: boolean
  onClose: () => void
  onCreated: (id: string) => void
}

export function ContactForm({ open, onClose, onCreated }: ContactFormProps) {
  const { t } = useTranslation('contacts')
  const { toast } = useToast()
  const [tags, setTags] = useState<string[]>([])
  const [tagInput, setTagInput] = useState('')

  const {
    register,
    handleSubmit,
    watch,
    reset,
    formState: { errors, isSubmitting },
  } = useForm<ContactFormValues>({
    resolver: zodResolver(contactSchema),
    defaultValues: { kind: 'person', source: 'manual' },
  })

  const kind = watch('kind')

  // ─── Tag input ──────────────────────────────────────────────────────────

  function addTag(value: string) {
    const trimmed = value.trim()
    if (trimmed && !tags.includes(trimmed)) {
      setTags((prev) => [...prev, trimmed])
    }
    setTagInput('')
  }

  function handleTagKeyDown(e: KeyboardEvent<HTMLInputElement>) {
    if (e.key === 'Enter' || e.key === ',') {
      e.preventDefault()
      addTag(tagInput)
    } else if (e.key === 'Backspace' && tagInput === '' && tags.length > 0) {
      setTags((prev) => prev.slice(0, -1))
    }
  }

  function removeTag(tag: string) {
    setTags((prev) => prev.filter((t) => t !== tag))
  }

  // ─── Submit ─────────────────────────────────────────────────────────────

  async function onSubmit(values: ContactFormValues) {
    // Add any pending tag input
    const finalTags = tagInput.trim()
      ? [...tags, tagInput.trim()]
      : tags

    const params: CreateContactParams = {
      p_kind: values.kind,
      p_display_name: values.display_name,
      p_source: values.source,
      ...(values.given_name && { p_given_name: values.given_name }),
      ...(values.family_name && { p_family_name: values.family_name }),
      ...(values.legal_name && { p_legal_name: values.legal_name }),
      ...(values.tax_id && { p_tax_id: values.tax_id }),
      ...(values.email && { p_email: values.email }),
      ...(values.phone && { p_phone: values.phone }),
      ...(values.phone_alt && { p_phone_alt: values.phone_alt }),
      ...(values.preferred_channel && values.preferred_channel !== 'none' && {
        p_preferred_channel: values.preferred_channel,
      }),
      ...(finalTags.length > 0 && { p_tags: finalTags }),
    }

    try {
      const id = await createContact(params)
      toast({
        title: t('contacts.success.created', 'Contacte creat correctament'),
      })
      reset()
      setTags([])
      setTagInput('')
      onCreated(id)
    } catch {
      toast({
        variant: 'destructive',
        title: t('contacts.errors.create_failed', 'Error en crear el contacte'),
      })
    }
  }

  function handleClose() {
    reset()
    setTags([])
    setTagInput('')
    onClose()
  }

  // ─── Render ─────────────────────────────────────────────────────────────

  return (
    <Dialog open={open} onOpenChange={(o) => { if (!o) handleClose() }}>
      <DialogContent className="sm:max-w-lg max-h-[90vh] overflow-y-auto">
        <DialogHeader>
          <DialogTitle>{t('contacts.form.title_create', 'Nou contacte')}</DialogTitle>
        </DialogHeader>

        <form onSubmit={handleSubmit(onSubmit)} className="space-y-4 pt-2">
          {/* Kind */}
          <div>
            <label className="text-sm font-medium text-foreground block mb-1.5">
              {t('contacts.form.kind_label', 'Tipus de contacte')}
            </label>
            <div className="flex gap-2">
              {(['person', 'company'] as const).map((k) => (
                <label key={k} className="flex-1 cursor-pointer">
                  <input type="radio" value={k} {...register('kind')} className="sr-only" />
                  <span
                    className={`block text-center py-2 px-3 rounded-lg border text-sm font-medium transition-colors ${
                      kind === k
                        ? 'bg-indigo-600 text-white border-indigo-600'
                        : 'border-border bg-background text-muted-foreground hover:bg-accent'
                    }`}
                  >
                    {k === 'person'
                      ? t('contacts.kind.person', 'Persona')
                      : t('contacts.kind.company', 'Empresa')}
                  </span>
                </label>
              ))}
            </div>
          </div>

          {/* display_name */}
          <div>
            <label className="text-sm font-medium text-foreground block mb-1">
              {t('contacts.fields.display_name', 'Nom')}
              <span className="text-destructive ml-1">*</span>
            </label>
            <Input {...register('display_name')} />
            {errors.display_name && (
              <p className="text-xs text-destructive mt-1">
                {t('contacts.errors.display_name_required', 'El nom és obligatori')}
              </p>
            )}
          </div>

          {/* Person-specific fields */}
          {kind === 'person' && (
            <div className="grid grid-cols-2 gap-3">
              <div>
                <label className="text-sm font-medium text-foreground block mb-1">
                  {t('contacts.fields.given_name', 'Nom de pila')}
                </label>
                <Input {...register('given_name')} />
              </div>
              <div>
                <label className="text-sm font-medium text-foreground block mb-1">
                  {t('contacts.fields.family_name', 'Cognoms')}
                </label>
                <Input {...register('family_name')} />
              </div>
            </div>
          )}

          {/* Company-specific fields */}
          {kind === 'company' && (
            <div className="grid grid-cols-2 gap-3">
              <div>
                <label className="text-sm font-medium text-foreground block mb-1">
                  {t('contacts.fields.legal_name', 'Raó social')}
                </label>
                <Input {...register('legal_name')} />
              </div>
              <div>
                <label className="text-sm font-medium text-foreground block mb-1">
                  {t('contacts.fields.tax_id', 'NIF/CIF')}
                </label>
                <Input {...register('tax_id')} />
              </div>
            </div>
          )}

          {/* Email + Phone */}
          <div className="grid grid-cols-2 gap-3">
            <div>
              <label className="text-sm font-medium text-foreground block mb-1">
                {t('contacts.fields.email', 'Correu electrònic')}
              </label>
              <Input type="email" {...register('email')} />
            </div>
            <div>
              <label className="text-sm font-medium text-foreground block mb-1">
                {t('contacts.fields.phone', 'Telèfon')}
              </label>
              <Input type="tel" {...register('phone')} />
            </div>
          </div>

          {/* Phone alt */}
          <div>
            <label className="text-sm font-medium text-foreground block mb-1">
              {t('contacts.fields.phone_alt', 'Telèfon alternatiu')}
            </label>
            <Input type="tel" {...register('phone_alt')} />
          </div>

          {/* Preferred channel */}
          <div>
            <label className="text-sm font-medium text-foreground block mb-1">
              {t('contacts.fields.preferred_channel', 'Canal preferit')}
            </label>
            <select
              {...register('preferred_channel')}
              className="w-full h-10 rounded-md border border-input bg-background px-3 text-sm focus:outline-none focus:ring-2 focus:ring-ring"
            >
              <option value="none">{t('contacts.channels.none', 'Cap')}</option>
              <option value="email">{t('contacts.channels.email', 'Email')}</option>
              <option value="sms">{t('contacts.channels.sms', 'SMS')}</option>
              <option value="whatsapp">{t('contacts.channels.whatsapp', 'WhatsApp')}</option>
            </select>
          </div>

          {/* Tags */}
          <div>
            <label className="text-sm font-medium text-foreground block mb-1">
              {t('contacts.fields.tags', 'Etiquetes')}
            </label>
            <div className="min-h-10 w-full rounded-md border border-input bg-background px-3 py-2 flex flex-wrap gap-1.5 focus-within:ring-2 focus-within:ring-ring">
              {tags.map((tag) => (
                <span
                  key={tag}
                  className="flex items-center gap-1 px-2 py-0.5 rounded-full bg-indigo-100 text-indigo-700 dark:bg-indigo-900/30 dark:text-indigo-300 text-xs font-medium"
                >
                  {tag}
                  <button type="button" onClick={() => removeTag(tag)} className="hover:opacity-70" title={t('contacts.actions.remove_tag', 'Eliminar etiqueta')} aria-label={t('contacts.actions.remove_tag', 'Eliminar etiqueta')}>
                    <X className="h-3 w-3" />
                  </button>
                </span>
              ))}
              <input
                type="text"
                value={tagInput}
                onChange={(e) => setTagInput(e.target.value)}
                onKeyDown={handleTagKeyDown}
                onBlur={() => { if (tagInput.trim()) addTag(tagInput) }}
                placeholder={tags.length === 0 ? t('contacts.form.tags_hint', 'Prem Enter o coma per afegir') : ''}
                className="flex-1 min-w-20 bg-transparent text-sm outline-none placeholder:text-muted-foreground"
              />
            </div>
          </div>

          {/* Source */}
          <div>
            <label className="text-sm font-medium text-foreground block mb-1">
              {t('contacts.fields.source', 'Origen')}
            </label>
            <select
              {...register('source')}
              className="w-full h-10 rounded-md border border-input bg-background px-3 text-sm focus:outline-none focus:ring-2 focus:ring-ring"
            >
              <option value="manual">{t('contacts.sources.manual', 'Manual')}</option>
              <option value="import">{t('contacts.sources.import', 'Importació')}</option>
              <option value="web">{t('contacts.sources.web', 'Web')}</option>
              <option value="referral">{t('contacts.sources.referral', 'Referència')}</option>
            </select>
          </div>

          {/* Actions */}
          <div className="flex justify-end gap-2 pt-2 border-t border-border">
            <Button type="button" variant="outline" onClick={handleClose} disabled={isSubmitting}>
              {t('contacts.form.cancel', 'Cancel·lar')}
            </Button>
            <Button type="submit" disabled={isSubmitting}>
              {isSubmitting
                ? t('contacts.form.saving', 'Desant...')
                : t('contacts.form.save', 'Desar')}
            </Button>
          </div>
        </form>
      </DialogContent>
    </Dialog>
  )
}
