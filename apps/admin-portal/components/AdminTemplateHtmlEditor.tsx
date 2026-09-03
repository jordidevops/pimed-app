'use client'

import { useEditor, EditorContent } from '@tiptap/react'
import StarterKit from '@tiptap/starter-kit'
import Placeholder from '@tiptap/extension-placeholder'
import { useEffect, useState } from 'react'
import {
  Bold, Italic, List, ListOrdered, Heading2, Heading3,
  PenLine, Type, Calendar, Hash, CheckSquare, ImageIcon, Variable, Code, Users, X,
} from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import DOMPurify from 'dompurify'

// ─── Tipus ─────────────────────────────────────────────────────────────────────

type SigningFieldType = 'signature' | 'text' | 'date' | 'initials' | 'number' | 'checkbox' | 'image'

const FIELD_TAG: Record<SigningFieldType, string> = {
  signature: 'signature-field',
  text:      'text-field',
  date:      'date-field',
  initials:  'initials-field',
  number:    'number-field',
  checkbox:  'checkbox-field',
  image:     'image-field',
}

const FIELD_LABEL: Record<SigningFieldType, string> = {
  signature: 'Signatura',
  text:      'Text',
  date:      'Data',
  initials:  'Inicials',
  number:    'Número',
  checkbox:  'Checkbox',
  image:     'Imatge',
}

const FIELD_ICONS: Record<SigningFieldType, React.ReactNode> = {
  signature: <PenLine     className="h-3.5 w-3.5" />,
  text:      <Type        className="h-3.5 w-3.5" />,
  date:      <Calendar    className="h-3.5 w-3.5" />,
  initials:  <Hash        className="h-3.5 w-3.5" />,
  number:    <Hash        className="h-3.5 w-3.5" />,
  checkbox:  <CheckSquare className="h-3.5 w-3.5" />,
  image:     <ImageIcon   className="h-3.5 w-3.5" />,
}

// ─── Catàleg de camps per entity_type ─────────────────────────────────────────

interface EntityField { field: string; label: string }

const ENTITY_CATALOG: Record<string, EntityField[]> = {
  employee: [
    { field: 'full_name',   label: 'Nom complet' },
    { field: 'email',       label: 'Email' },
    { field: 'phone',       label: 'Telèfon' },
    { field: 'job_title',   label: 'Càrrec' },
    { field: 'document_id', label: 'NIF/DNI' },
    { field: 'starts_on',   label: 'Data incorporació' },
    { field: 'status',      label: 'Estat' },
  ],
  contact: [
    { field: 'display_name', label: 'Nom' },
    { field: 'given_name',   label: 'Nom de pila' },
    { field: 'family_name',  label: 'Cognoms' },
    { field: 'legal_name',   label: 'Raó social' },
    { field: 'tax_id',       label: 'NIF/CIF' },
    { field: 'email',        label: 'Email' },
    { field: 'phone',        label: 'Telèfon' },
  ],
  site: [
    { field: 'name',    label: 'Nom seu' },
    { field: 'address', label: 'Adreça' },
  ],
  tenant: [
    { field: 'name', label: 'Nom empresa' },
    { field: 'slug', label: 'Identificador' },
  ],
  user: [
    { field: 'email',      label: 'Email' },
    { field: 'full_name',  label: 'Nom complet' },
    { field: 'first_name', label: 'Nom' },
    { field: 'last_name',  label: 'Cognoms' },
  ],
  asset: [
    { field: 'name',          label: 'Nom actiu' },
    { field: 'serial_number', label: 'Número de sèrie' },
    { field: 'model',         label: 'Model' },
  ],
}

const GLOBAL_VARIABLES: { key: string; label: string }[] = [
  { key: 'today', label: "Data d'avui" },
  { key: 'year',  label: 'Any' },
  { key: 'now',   label: 'Data i hora' },
]

// ─── Props ────────────────────────────────────────────────────────────────────

export interface AdminTemplateHtmlEditorProps {
  content:          string
  onChange:         (html: string) => void
  signingRolesDefs: { name: string; entity_type: string }[]
}

// Escapa valors d'atributs HTML per prevenir injecció
function escapeAttr(s: string): string {
  return s.replace(/&/g, '&amp;').replace(/"/g, '&quot;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
}

// ─── Component ────────────────────────────────────────────────────────────────

export function AdminTemplateHtmlEditor({ content, onChange, signingRolesDefs }: AdminTemplateHtmlEditorProps) {
  const [showRaw, setShowRaw]       = useState(false)
  const [rawHtml, setRawHtml]       = useState(content)
  const [catalogOpen, setCatalogOpen] = useState(false)
  const [fieldPanel, setFieldPanel] = useState<{
    open: boolean; fieldType: SigningFieldType; fieldName: string; role: string; required: boolean
  }>({ open: false, fieldType: 'signature', fieldName: 'Camp', role: signingRolesDefs[0]?.name ?? '', required: true })

  const signingRoles = signingRolesDefs.map(r => r.name)

  const editor = useEditor({
    extensions: [
      StarterKit,
      Placeholder.configure({
        placeholder: 'Escriu el contingut de la plantilla. Usa els botons per inserir variables i camps de signatura...',
      }),
    ],
    content,
    onUpdate: ({ editor }) => {
      const html = editor.getHTML()
      setRawHtml(html)
      onChange(html)
    },
    editorProps: {
      attributes: {
        class: 'focus:outline-none min-h-[300px] px-3 py-2 text-sm leading-relaxed [&_h2]:text-lg [&_h2]:font-semibold [&_h2]:mt-3 [&_h3]:text-base [&_h3]:font-semibold [&_h3]:mt-2 [&_ul]:list-disc [&_ul]:pl-5 [&_ol]:list-decimal [&_ol]:pl-5 [&_p]:my-1',
      },
    },
  })

  useEffect(() => {
    if (editor && content !== editor.getHTML()) {
      editor.commands.setContent(content)
      setRawHtml(content)
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [content])

  if (!editor) return null

  function insertVariable(key: string) {
    editor?.chain().focus().insertContent(`{{${key}}}`).run()
  }

  function insertSigningField() {
    const { fieldType, fieldName, role, required } = fieldPanel
    const tag = FIELD_TAG[fieldType]
    const html = `<${tag} name="${escapeAttr(fieldName)}" role="${escapeAttr(role)}" required="${required}" style="width:150px;height:50px;display:inline-block;"> </${tag}>`
    editor?.chain().focus().insertContent(html).run()
    setFieldPanel(p => ({ ...p, open: false }))
  }

  function applyRawHtml() {
    const clean = DOMPurify.sanitize(rawHtml, {
      ADD_TAGS: ['signature-field', 'text-field', 'date-field', 'initials-field', 'number-field', 'checkbox-field', 'image-field'],
      ADD_ATTR: ['name', 'role', 'required', 'style'],
    })
    editor?.commands.setContent(clean)
    onChange(clean)
    setShowRaw(false)
  }

  const hasCatalog = signingRolesDefs.some(r => r.name && ENTITY_CATALOG[r.entity_type])

  return (
    <div className="border rounded-md overflow-hidden">
      {/* Toolbar */}
      <div className="flex flex-wrap items-center gap-0.5 px-2 py-1.5 border-b bg-muted/40">
        <Button type="button" variant={editor.isActive('bold') ? 'secondary' : 'ghost'} size="sm" className="h-7 w-7 p-0" onClick={() => editor.chain().focus().toggleBold().run()} title="Negreta">
          <Bold className="h-3.5 w-3.5" />
        </Button>
        <Button type="button" variant={editor.isActive('italic') ? 'secondary' : 'ghost'} size="sm" className="h-7 w-7 p-0" onClick={() => editor.chain().focus().toggleItalic().run()} title="Cursiva">
          <Italic className="h-3.5 w-3.5" />
        </Button>
        <Button type="button" variant={editor.isActive('heading', { level: 2 }) ? 'secondary' : 'ghost'} size="sm" className="h-7 w-7 p-0" onClick={() => editor.chain().focus().toggleHeading({ level: 2 }).run()} title="Títol 2">
          <Heading2 className="h-3.5 w-3.5" />
        </Button>
        <Button type="button" variant={editor.isActive('heading', { level: 3 }) ? 'secondary' : 'ghost'} size="sm" className="h-7 w-7 p-0" onClick={() => editor.chain().focus().toggleHeading({ level: 3 }).run()} title="Títol 3">
          <Heading3 className="h-3.5 w-3.5" />
        </Button>
        <Button type="button" variant={editor.isActive('bulletList') ? 'secondary' : 'ghost'} size="sm" className="h-7 w-7 p-0" onClick={() => editor.chain().focus().toggleBulletList().run()} title="Llista">
          <List className="h-3.5 w-3.5" />
        </Button>
        <Button type="button" variant={editor.isActive('orderedList') ? 'secondary' : 'ghost'} size="sm" className="h-7 w-7 p-0" onClick={() => editor.chain().focus().toggleOrderedList().run()} title="Llista numerada">
          <ListOrdered className="h-3.5 w-3.5" />
        </Button>

        <span className="mx-1 border-l h-5" />

        {/* Inserir variable manual */}
        <div className="relative group">
          <Button type="button" variant="ghost" size="sm" className="h-7 px-2 gap-1 text-xs">
            <Variable className="h-3.5 w-3.5" />
            Variable
          </Button>
          <div className="absolute top-full left-0 mt-1 bg-popover border rounded-md shadow-md py-1 z-20 min-w-40 hidden group-hover:block">
            {GLOBAL_VARIABLES.map(g => (
              <button type="button" key={g.key} className="w-full text-left text-xs px-3 py-1.5 hover:bg-accent font-mono" onClick={() => insertVariable(g.key)}>
                <span className="text-muted-foreground mr-1 font-sans">{g.label}:</span>
                {`{{${g.key}}}`}
              </button>
            ))}
            {signingRolesDefs.map(role =>
              ENTITY_CATALOG[role.entity_type]?.map(f => (
                <button type="button" key={`${role.name}.${f.field}`} className="w-full text-left text-xs px-3 py-1.5 hover:bg-accent font-mono" onClick={() => insertVariable(`${role.name}.${f.field}`)}>
                  <span className="text-muted-foreground mr-1 font-sans">{f.label}:</span>
                  {`{{${role.name}.${f.field}}}`}
                </button>
              ))
            )}
          </div>
        </div>

        {/* Catàleg visual */}
        {hasCatalog && (
          <Button type="button" variant={catalogOpen ? 'secondary' : 'ghost'} size="sm" className="h-7 px-2 gap-1 text-xs" onClick={() => setCatalogOpen(v => !v)}>
            <Users className="h-3.5 w-3.5" />
            Catàleg
          </Button>
        )}

        {/* Inserir camp de signatura */}
        {signingRoles.length > 0 && (
          <Button type="button" variant={fieldPanel.open ? 'secondary' : 'ghost'} size="sm" className="h-7 px-2 gap-1 text-xs" onClick={() => setFieldPanel(p => ({ ...p, open: !p.open }))}>
            <PenLine className="h-3.5 w-3.5" />
            Camp firma
          </Button>
        )}

        <span className="flex-1" />

        <Button type="button" variant="ghost" size="sm" className="h-7 w-7 p-0" onClick={() => setShowRaw(v => !v)} title="HTML raw">
          <Code className="h-3.5 w-3.5" />
        </Button>
      </div>

      {/* Catàleg d'entitats */}
      {catalogOpen && (
        <div className="border-b px-3 py-2 bg-muted/30 space-y-2">
          <div className="flex items-center justify-between">
            <p className="text-xs font-medium">Camps per entitat</p>
            <Button type="button" variant="ghost" size="sm" className="h-6 w-6 p-0" onClick={() => setCatalogOpen(false)}>
              <X className="h-3 w-3" />
            </Button>
          </div>
          <div className="space-y-2">
            {signingRolesDefs.filter(r => r.name && ENTITY_CATALOG[r.entity_type]).map(role => (
              <div key={role.name} className="space-y-1">
                <div className="flex items-center gap-1.5">
                  <span className="text-xs font-semibold">{role.name}</span>
                  <span className="text-[10px] uppercase bg-indigo-100 text-indigo-700 px-1.5 py-0.5 rounded font-semibold">{role.entity_type}</span>
                </div>
                <div className="flex flex-wrap gap-1">
                  {ENTITY_CATALOG[role.entity_type].map(field => (
                    <button type="button" key={field.field}
                      title={`{{${role.name}.${field.field}}}`}
                      className="text-[11px] px-1.5 py-0.5 border rounded hover:bg-accent bg-background flex items-center gap-1"
                      onClick={() => insertVariable(`${role.name}.${field.field}`)}
                    >
                      <span className="text-muted-foreground">{field.label}</span>
                      <span className="font-mono text-indigo-600 text-[10px]">{`{{${role.name}.${field.field}}}`}</span>
                    </button>
                  ))}
                </div>
              </div>
            ))}
          </div>
        </div>
      )}

      {/* Panel inserir camp de signatura */}
      {fieldPanel.open && (
        <div className="border-b px-3 py-2 bg-muted/30">
          <p className="text-xs font-medium mb-2">Inserir camp de firma</p>
          <div className="flex flex-wrap gap-2 items-end">
            <div className="space-y-1">
              <label className="text-xs text-muted-foreground">Tipus</label>
              <select value={fieldPanel.fieldType} onChange={e => setFieldPanel(p => ({ ...p, fieldType: e.target.value as SigningFieldType }))} title="Tipus de camp" className="h-7 text-xs border border-input rounded-md px-1.5 bg-background">
                {(Object.keys(FIELD_TAG) as SigningFieldType[]).map(ft => (
                  <option key={ft} value={ft}>{FIELD_LABEL[ft]}</option>
                ))}
              </select>
            </div>
            <div className="space-y-1">
              <label className="text-xs text-muted-foreground">Rol</label>
              <select value={fieldPanel.role} onChange={e => setFieldPanel(p => ({ ...p, role: e.target.value }))} title="Rol de signatura" className="h-7 text-xs border border-input rounded-md px-1.5 bg-background">
                {signingRoles.map(r => <option key={r} value={r}>{r}</option>)}
              </select>
            </div>
            <div className="space-y-1">
              <label className="text-xs text-muted-foreground">Nom</label>
              <Input value={fieldPanel.fieldName} onChange={e => setFieldPanel(p => ({ ...p, fieldName: e.target.value }))} className="h-7 text-xs w-28" placeholder="Firma1" />
            </div>
            <div className="flex items-center gap-1.5 pb-1">
              <input id="field-required-admin" type="checkbox" checked={fieldPanel.required} onChange={e => setFieldPanel(p => ({ ...p, required: e.target.checked }))} className="h-3.5 w-3.5" />
              <label htmlFor="field-required-admin" className="text-xs">Obligatori</label>
            </div>
            <Button type="button" size="sm" className="h-7 text-xs" onClick={insertSigningField} disabled={!fieldPanel.role || !fieldPanel.fieldName.trim()}>
              {FIELD_ICONS[fieldPanel.fieldType]}
              <span className="ml-1">Inserir</span>
            </Button>
            <Button type="button" variant="ghost" size="sm" className="h-7 text-xs" onClick={() => setFieldPanel(p => ({ ...p, open: false }))}>
              Cancel·lar
            </Button>
          </div>
        </div>
      )}

      {/* Editor / Raw HTML */}
      {showRaw ? (
        <div className="space-y-2 p-2">
          <textarea
            className="w-full h-64 font-mono text-xs border border-input rounded-md p-2 bg-background resize-y"
            value={rawHtml}
            onChange={e => setRawHtml(e.target.value)}
            placeholder="<p>HTML de la plantilla...</p>"
            title="HTML raw"
          />
          <div className="flex gap-2">
            <Button type="button" size="sm" className="h-7 text-xs" onClick={applyRawHtml}>Aplicar HTML</Button>
            <Button type="button" variant="ghost" size="sm" className="h-7 text-xs" onClick={() => setShowRaw(false)}>Cancel·lar</Button>
          </div>
        </div>
      ) : (
        <EditorContent editor={editor} />
      )}
    </div>
  )
}
