import { useEditor, EditorContent } from '@tiptap/react'
import StarterKit from '@tiptap/starter-kit'
import Placeholder from '@tiptap/extension-placeholder'
import { Table, TableRow, TableHeader, TableCell } from '@tiptap/extension-table'
import TextAlign from '@tiptap/extension-text-align'
import UnderlineExt from '@tiptap/extension-underline'
import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import {
  Bold, Italic, List, ListOrdered, Heading2, Heading3,
  PenLine, Type, Calendar, Hash, CheckSquare, ImageIcon, Variable, Code,
  Users, X, Underline, HelpCircle,
  AlignLeft, AlignCenter, AlignRight, AlignJustify,
  Table2, Plus, Minus, Trash2,
} from 'lucide-react'
import DOMPurify from 'dompurify'

// ─── Tipus ─────────────────────────────────────────────────────────────────────

type SigningFieldType =
  | 'signature'
  | 'text'
  | 'date'
  | 'initials'
  | 'number'
  | 'checkbox'
  | 'image'

const FIELD_TAG: Record<SigningFieldType, string> = {
  signature: 'signature-field',
  text:      'text-field',
  date:      'date-field',
  initials:  'initials-field',
  number:    'number-field',
  checkbox:  'checkbox-field',
  image:     'image-field',
}

const FIELD_ICONS: Record<SigningFieldType, React.ReactNode> = {
  signature: <PenLine    className="h-3.5 w-3.5" />,
  text:      <Type       className="h-3.5 w-3.5" />,
  date:      <Calendar   className="h-3.5 w-3.5" />,
  initials:  <Hash       className="h-3.5 w-3.5" />,
  number:    <Hash       className="h-3.5 w-3.5" />,
  checkbox:  <CheckSquare className="h-3.5 w-3.5" />,
  image:     <ImageIcon  className="h-3.5 w-3.5" />,
}

// ─── Catàleg estàtic de camps per entity_type ─────────────────────────────────

interface EntityField {
  field: string
  label: string
}

const ENTITY_CATALOG: Record<string, EntityField[]> = {
  employee: [
    { field: 'full_name',   label: 'Nom complet' },
    { field: 'email',       label: 'Email' },
    { field: 'phone',       label: 'Telèfon' },
    /** Alias: resolt com a nom del lloc de treball (job_positions.name) per plantilles antigues */
    { field: 'job_title',   label: 'Lloc de treball' },
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
  asset: [
    { field: 'name',          label: 'Nom actiu' },
    { field: 'serial_number', label: 'Número de sèrie' },
    { field: 'model',         label: 'Model' },
  ],
}

/** Variables globals sempre disponibles al servidor (resolució automàtica sense context_refs) */
const GLOBAL_VARIABLES: { key: string; label: string }[] = [
  { key: 'today', label: "Data d'avui" },
  { key: 'year',  label: 'Any' },
  { key: 'now',   label: 'Data i hora' },
]

interface InsertFieldState {
  open:      boolean
  fieldType: SigningFieldType
  fieldName: string
  role:      string
  required:  boolean
}

interface InsertTableState {
  open: boolean
  rows: number
  cols: number
}

interface TemplateHtmlEditorProps {
  content:           string
  onChange:          (html: string) => void
  signingRoles:      string[]
  variableKeys:      string[]
  /** Rols de signatura amb el seu entity_type per construir el catàleg de camps path-based */
  signingRolesDefs?: { name: string; entity_type: string }[]
  /** Crida automàticament en inserir un camp path-based des del catàleg perquè el pare
   *  el pugui registrar a variables_schema i garantir la resolució server-side */
  onAddVariable?:    (key: string) => void
}

// Escapa valors d'atributs HTML per prevenir injecció
function escapeAttr(s: string): string {
  return s.replace(/&/g, '&amp;').replace(/"/g, '&quot;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
}

// ─── Editor principal ──────────────────────────────────────────────────────────

export function TemplateHtmlEditor({
  content,
  onChange,
  signingRoles,
  variableKeys,
  signingRolesDefs,
  onAddVariable: _onAddVariable,
}: TemplateHtmlEditorProps) {
  const { t } = useTranslation('signing')
  const [showRaw, setShowRaw] = useState(false)
  const [rawHtml, setRawHtml] = useState(content)
  const [catalogOpen, setCatalogOpen] = useState(false)
  const [fieldDialog, setFieldDialog] = useState<InsertFieldState>({
    open: false, fieldType: 'signature', fieldName: 'Camp', role: signingRoles[0] ?? '', required: true,
  })
  const [tableDialog, setTableDialog] = useState<InsertTableState>({ open: false, rows: 3, cols: 3 })
  const [showLiquidHelp, setShowLiquidHelp] = useState(false)

  const editor = useEditor({
    extensions: [
      StarterKit,
      Placeholder.configure({
        placeholder: t('html.placeholder', 'Escriu el contingut de la plantilla. Usa els botons per inserir variables i camps de signatura...'),
      }),
      UnderlineExt,
      TextAlign.configure({ types: ['heading', 'paragraph'] }),
      Table.configure({ resizable: false }),
      TableRow,
      TableHeader,
      TableCell,
    ],
    content,
    onUpdate: ({ editor }) => {
      const html = editor.getHTML()
      setRawHtml(html)
      onChange(html)
    },
    editorProps: {
      attributes: {
        class: 'prose prose-sm max-w-none focus:outline-none min-h-[200px] px-3 py-2',
      },
    },
  })

  // Sync content from parent (per edicions existents)
  useEffect(() => {
    if (editor && content !== editor.getHTML()) {
      editor.commands.setContent(content)
      setRawHtml(content)
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [content])

  if (!editor) return null

  // ── Inserció de variable ────────────────────────────────────────────────────

  function insertVariable(key: string) {
    editor?.chain().focus().insertContent(`{{${key}}}`).run()
  }

  // ── Inserció de camp de signatura ──────────────────────────────────────────
  // TipTap no coneix els elements personalitzats (<signature-field> etc.), de manera
  // que s'han d'inserir directament al codi raw HTML i no al model WYSIWYG.

  function insertSigningField() {
    const { fieldType, fieldName, role, required } = fieldDialog
    const tag = FIELD_TAG[fieldType]
    const fieldHtml = `<${tag} name="${escapeAttr(fieldName)}" role="${escapeAttr(role)}" required="${required}" style="width:150px;height:50px;display:inline-block;"> </${tag}>`
    const current = rawHtml || editor?.getHTML() || ''
    const newHtml = current + '\n' + fieldHtml
    const clean = DOMPurify.sanitize(newHtml, {
      ADD_TAGS: ['signature-field', 'text-field', 'date-field', 'initials-field', 'number-field', 'checkbox-field', 'image-field',
                 'table', 'thead', 'tbody', 'tr', 'th', 'td', 'colgroup', 'col'],
      ADD_ATTR: ['name', 'role', 'required', 'style', 'colspan', 'rowspan', 'data-type'],
    })
    setRawHtml(clean)
    editor?.commands.setContent(clean)
    onChange(clean)
    setShowRaw(true)
    setFieldDialog(d => ({ ...d, open: false }))
  }

  // ── Inserció de taula ──────────────────────────────────────────────────────

  function insertTable() {
    const { rows, cols } = tableDialog
    editor?.chain().focus().insertTable({ rows, cols, withHeaderRow: true }).run()
    setTableDialog(d => ({ ...d, open: false }))
  }

  // ── Toggle raw HTML ─────────────────────────────────────────────────────────

  function applyRawHtml() {
    // Sanitize before loading into TipTap (XSS prevention)
    const clean = DOMPurify.sanitize(rawHtml, {
      ADD_TAGS: ['signature-field', 'text-field', 'date-field', 'initials-field', 'number-field', 'checkbox-field', 'image-field',
                 'table', 'thead', 'tbody', 'tr', 'th', 'td', 'colgroup', 'col'],
      ADD_ATTR: ['name', 'role', 'required', 'style', 'colspan', 'rowspan', 'data-type'],
    })
    editor?.commands.setContent(clean)
    onChange(clean)
    setShowRaw(false)
  }

  // ── Render ──────────────────────────────────────────────────────────────────

  return (
    <div className="border rounded-md overflow-hidden space-y-0 tiptap-html-editor">
      <style>{`
        .tiptap-html-editor .ProseMirror table { border-collapse: collapse; width: 100%; margin: 0; }
        .tiptap-html-editor .ProseMirror th,
        .tiptap-html-editor .ProseMirror td { border: 1px solid #e2e8f0; padding: 4px 8px; min-width: 60px; vertical-align: top; }
        .tiptap-html-editor .ProseMirror th { background: #f8fafc; font-weight: 600; }
        .dark .tiptap-html-editor .ProseMirror th { background: #1e293b; }
        .dark .tiptap-html-editor .ProseMirror th,
        .dark .tiptap-html-editor .ProseMirror td { border-color: #334155; }
        .tiptap-html-editor .ProseMirror .selectedCell { background-color: rgba(99,102,241,0.12); }
        .tiptap-html-editor .ProseMirror .column-resize-handle { width: 4px; background-color: rgba(99,102,241,0.4); }
      `}</style>
      {/* Toolbar */}
      <div className="flex flex-wrap items-center gap-0.5 px-2 py-1.5 border-b bg-muted/40">
        {/* Format */}
        <Button type="button" variant={editor.isActive('bold') ? 'secondary' : 'ghost'} size="sm" className="h-7 w-7 p-0" onClick={() => editor.chain().focus().toggleBold().run()} title={t('html.bold', 'Negreta')}>
          <Bold className="h-3.5 w-3.5" />
        </Button>
        <Button type="button" variant={editor.isActive('italic') ? 'secondary' : 'ghost'} size="sm" className="h-7 w-7 p-0" onClick={() => editor.chain().focus().toggleItalic().run()} title={t('html.italic', 'Cursiva')}>
          <Italic className="h-3.5 w-3.5" />
        </Button>
        <Button type="button" variant={editor.isActive('underline') ? 'secondary' : 'ghost'} size="sm" className="h-7 w-7 p-0" onClick={() => editor.chain().focus().toggleUnderline().run()} title={t('html.underline', 'Subratllat')}>
          <Underline className="h-3.5 w-3.5" />
        </Button>
        <Button type="button" variant={editor.isActive('heading', { level: 2 }) ? 'secondary' : 'ghost'} size="sm" className="h-7 w-7 p-0" onClick={() => editor.chain().focus().toggleHeading({ level: 2 }).run()} title={t('html.heading2', 'Títol 2')}>
          <Heading2 className="h-3.5 w-3.5" />
        </Button>
        <Button type="button" variant={editor.isActive('heading', { level: 3 }) ? 'secondary' : 'ghost'} size="sm" className="h-7 w-7 p-0" onClick={() => editor.chain().focus().toggleHeading({ level: 3 }).run()} title={t('html.heading3', 'Títol 3')}>
          <Heading3 className="h-3.5 w-3.5" />
        </Button>
        <Button type="button" variant={editor.isActive('bulletList') ? 'secondary' : 'ghost'} size="sm" className="h-7 w-7 p-0" onClick={() => editor.chain().focus().toggleBulletList().run()} title={t('html.bulletList', 'Llista')}>
          <List className="h-3.5 w-3.5" />
        </Button>
        <Button type="button" variant={editor.isActive('orderedList') ? 'secondary' : 'ghost'} size="sm" className="h-7 w-7 p-0" onClick={() => editor.chain().focus().toggleOrderedList().run()} title={t('html.orderedList', 'Llista numerada')}>
          <ListOrdered className="h-3.5 w-3.5" />
        </Button>

        <span className="mx-1 border-l h-5" />

        {/* Alineació de text */}
        <Button type="button" variant={editor.isActive({ textAlign: 'left' }) ? 'secondary' : 'ghost'} size="sm" className="h-7 w-7 p-0" onClick={() => editor.chain().focus().setTextAlign('left').run()} title={t('html.alignLeft', 'Alinear esquerra')}>
          <AlignLeft className="h-3.5 w-3.5" />
        </Button>
        <Button type="button" variant={editor.isActive({ textAlign: 'center' }) ? 'secondary' : 'ghost'} size="sm" className="h-7 w-7 p-0" onClick={() => editor.chain().focus().setTextAlign('center').run()} title={t('html.alignCenter', 'Centrar')}>
          <AlignCenter className="h-3.5 w-3.5" />
        </Button>
        <Button type="button" variant={editor.isActive({ textAlign: 'right' }) ? 'secondary' : 'ghost'} size="sm" className="h-7 w-7 p-0" onClick={() => editor.chain().focus().setTextAlign('right').run()} title={t('html.alignRight', 'Alinear dreta')}>
          <AlignRight className="h-3.5 w-3.5" />
        </Button>
        <Button type="button" variant={editor.isActive({ textAlign: 'justify' }) ? 'secondary' : 'ghost'} size="sm" className="h-7 w-7 p-0" onClick={() => editor.chain().focus().setTextAlign('justify').run()} title={t('html.alignJustify', 'Justificar')}>
          <AlignJustify className="h-3.5 w-3.5" />
        </Button>

        <span className="mx-1 border-l h-5" />

        {/* Inserir variable manual (llista plana — exclou path-based, cobertes pel catàleg) */}
        {variableKeys.filter(k => !k.includes('.')).length > 0 && (
          <div className="relative group">
            <Button type="button" variant="ghost" size="sm" className="h-7 px-2 gap-1 text-xs">
              <Variable className="h-3.5 w-3.5" />
              {t('html.insertVariable', 'Variable')}
            </Button>
            <div className="absolute top-full left-0 mt-1 bg-popover border rounded-md shadow-md py-1 z-10 min-w-32 hidden group-hover:block">
              {variableKeys.filter(k => !k.includes('.')).map(key => (
                <button
                  type="button"
                  key={key}
                  className="w-full text-left text-xs px-3 py-1.5 hover:bg-accent font-mono"
                  onClick={() => insertVariable(key)}
                >
                  {`{{${key}}}`}
                </button>
              ))}
            </div>
          </div>
        )}

        {/* Catàleg d'entitats: inserir camps path-based per rol */}
        {signingRolesDefs?.some(r => r.name && ENTITY_CATALOG[r.entity_type]) && (
          <Button
            type="button"
            variant={catalogOpen ? 'secondary' : 'ghost'}
            size="sm"
            className="h-7 px-2 gap-1 text-xs"
            onClick={() => setCatalogOpen(v => !v)}
          >
            <Users className="h-3.5 w-3.5" />
            {t('html.catalog', 'Entitat')}
          </Button>
        )}

        {/* Inserir camp de signatura */}
        {signingRoles.length > 0 && (
          <Button
            type="button"
            variant="ghost"
            size="sm"
            className="h-7 px-2 gap-1 text-xs"
            onClick={() => setFieldDialog(d => ({
              ...d,
              open: !d.open,
              // Quan s'obre, sincronitza el rol si el valor actual no és vàlid (corregeix bug: role '' quan roles s'afegeixen després del mount)
              role: !d.open && (!d.role || !signingRoles.includes(d.role))
                ? (signingRoles[0] ?? '')
                : d.role,
            }))}
          >
            <PenLine className="h-3.5 w-3.5" />
            {t('html.insertField', 'Camp firma')}
          </Button>
        )}

        {/* Taula */}
        <Button
          type="button"
          variant={tableDialog.open ? 'secondary' : 'ghost'}
          size="sm"
          className="h-7 px-2 gap-1 text-xs"
          onClick={() => setTableDialog(d => ({ ...d, open: !d.open }))}
          title={t('html.insertTable', 'Inserir taula')}
        >
          <Table2 className="h-3.5 w-3.5" />
          {t('html.table', 'Taula')}
        </Button>

        <span className="flex-1" />

        {/* Ajuda sintaxi Liquid */}
        <Button
          type="button"
          variant={showLiquidHelp ? 'secondary' : 'ghost'}
          size="sm"
          className="h-7 px-2 gap-1 text-xs"
          onClick={() => setShowLiquidHelp(v => !v)}
          title={t('html.liquidHelp', 'Ajuda Liquid')}
        >
          <HelpCircle className="h-3.5 w-3.5" />
          {t('html.liquidHelpBtn', 'Liquid')}
        </Button>

        {/* Toggle raw HTML */}
        <Button type="button" variant="ghost" size="sm" className="h-7 w-7 p-0" onClick={() => setShowRaw(v => !v)} title={t('html.rawHtml', 'HTML raw')}>
          <Code className="h-3.5 w-3.5" />
        </Button>
      </div>

      {/* Ajuda sintaxi Liquid (condicionals, bucles, filtres) */}
      {showLiquidHelp && (
        <div className="border-b px-3 py-2 bg-amber-50 dark:bg-amber-900/20 space-y-2">
          <div className="flex items-center justify-between">
            <p className="text-xs font-semibold text-amber-800 dark:text-amber-200">
              {t('html.liquidHelpTitle', 'Sintaxi Liquid — condicionals, bucles i filtres')}
            </p>
            <Button type="button" variant="ghost" size="sm" className="h-6 w-6 p-0"
              onClick={() => setShowLiquidHelp(false)}>
              <X className="h-3 w-3" />
            </Button>
          </div>
          <div className="space-y-1.5 text-xs">
            <div>
              <span className="font-medium text-muted-foreground">{t('html.liquidHelpIf', 'Condicional:')}</span>
              <code className="ml-2 bg-white dark:bg-black/30 rounded px-1.5 py-0.5 font-mono text-[11px]">
                {`{% if variable %}...{% endif %}`}
              </code>
            </div>
            <div>
              <span className="font-medium text-muted-foreground">{t('html.liquidHelpIfElse', 'Condicional amb alternativa:')}</span>
              <code className="ml-2 bg-white dark:bg-black/30 rounded px-1.5 py-0.5 font-mono text-[11px]">
                {`{% if variable == "valor" %}...{% else %}...{% endif %}`}
              </code>
            </div>
            <div>
              <span className="font-medium text-muted-foreground">{t('html.liquidHelpUnless', 'Menys si:')}</span>
              <code className="ml-2 bg-white dark:bg-black/30 rounded px-1.5 py-0.5 font-mono text-[11px]">
                {`{% unless variable %}...{% endunless %}`}
              </code>
            </div>
            <div>
              <span className="font-medium text-muted-foreground">{t('html.liquidHelpFor', 'Bucle:')}</span>
              <code className="ml-2 bg-white dark:bg-black/30 rounded px-1.5 py-0.5 font-mono text-[11px]">
                {`{% for item in llista %}{{ item }}{% endfor %}`}
              </code>
            </div>
            <div className="pt-0.5">
              <span className="font-medium text-muted-foreground">{t('html.liquidHelpFilters', 'Filtres útils:')}</span>
              <div className="flex flex-wrap gap-1.5 mt-1">
                {[
                  { ex: `{{ variable | default: "—" }}`, desc: t('html.filterDefault', 'valor per defecte') },
                  { ex: `{{ data | date: "%d/%m/%Y" }}`, desc: t('html.filterDate', 'format data') },
                  { ex: `{{ text | upcase }}`, desc: t('html.filterUpcase', 'majúscules') },
                  { ex: `{{ text | capitalize }}`, desc: t('html.filterCapitalize', 'primera majúscula') },
                ].map(f => (
                  <span key={f.ex} className="inline-flex items-center gap-1 bg-white dark:bg-black/30 rounded px-1.5 py-0.5 border text-[10px]">
                    <code className="font-mono">{f.ex}</code>
                    <span className="text-muted-foreground">— {f.desc}</span>
                  </span>
                ))}
              </div>
            </div>
          </div>
        </div>
      )}

      {/* Catàleg de camps per entitat (path-based: {{Rol.camp}}) */}
      {catalogOpen && (
        <div className="border-b px-3 py-2 bg-muted/30 space-y-2">
          <div className="flex items-center justify-between">
            <p className="text-xs font-medium">{t('html.catalogTitle', 'Camps per entitat')}</p>
            <Button type="button" variant="ghost" size="sm" className="h-6 w-6 p-0"
              onClick={() => setCatalogOpen(false)}>
              <X className="h-3 w-3" />
            </Button>
          </div>
          <div className="space-y-2.5">
            {signingRolesDefs?.filter(r => r.name && ENTITY_CATALOG[r.entity_type]).map(role => (
              <div key={role.name} className="space-y-1">
                <div className="flex items-center gap-1.5">
                  <span className="text-xs font-semibold">{role.name}</span>
                  <span className="text-[10px] uppercase bg-indigo-100 text-indigo-700 dark:bg-indigo-900 dark:text-indigo-300 px-1.5 py-0.5 rounded font-semibold">
                    {t(`html.entity_${role.entity_type}`, role.entity_type)}
                  </span>
                </div>
                <div className="flex flex-wrap gap-1">
                  {ENTITY_CATALOG[role.entity_type].map(field => (
                    <button
                      type="button"
                      key={field.field}
                      title={`{{${role.name}.${field.field}}}`}
                      className="text-[11px] px-1.5 py-0.5 border rounded hover:bg-accent bg-background flex items-center gap-1"
                      onClick={() => {
                        // Path-based: inserim al HTML però NO registrem al schema (resolució automàtica)
                        insertVariable(`${role.name}.${field.field}`)
                      }}
                    >
                      <span className="text-muted-foreground">{t(`html.fields.${role.entity_type}_${field.field}`, field.label)}</span>
                      <span className="font-mono text-indigo-600 dark:text-indigo-400 text-[10px]">{`{{${role.name}.${field.field}}}`}</span>
                    </button>
                  ))}
                </div>
              </div>
            ))}
            {/* Variables globals: sempre disponibles (resoltes automàticament pel servidor) */}
            <div className="space-y-1 pt-1 border-t">
              <span className="text-xs font-semibold text-muted-foreground">{t('html.globals', 'Variables globals')}</span>
              <div className="flex flex-wrap gap-1">
                {GLOBAL_VARIABLES.map(g => (
                  <button
                    type="button"
                    key={g.key}
                    title={`{{${g.key}}}`}
                    className="text-[11px] px-1.5 py-0.5 border rounded hover:bg-accent bg-background flex items-center gap-1"
                    onClick={() => insertVariable(g.key)}
                  >
                    <span className="text-muted-foreground">{t(`html.global_${g.key}`, g.label)}</span>
                    <span className="font-mono text-green-600 dark:text-green-400 text-[10px]">{`{{${g.key}}}`}</span>
                  </button>
                ))}
              </div>
            </div>
          </div>
        </div>
      )}

      {/* Panel de taula: inserir o controlar taula existent */}
      {tableDialog.open && (
        <div className="border-b px-3 py-2 bg-muted/30 space-y-2">
          <div className="flex items-center justify-between">
            <p className="text-xs font-medium">{t('html.tableTitle', 'Taula')}</p>
            <Button type="button" variant="ghost" size="sm" className="h-6 w-6 p-0"
              onClick={() => setTableDialog(d => ({ ...d, open: false }))}>
              <X className="h-3 w-3" />
            </Button>
          </div>
          {editor.can().deleteTable() ? (
            <div className="space-y-1.5">
              <p className="text-[11px] text-muted-foreground">{t('html.tableControls', 'Controls de taula activa')}</p>
              <div className="flex flex-wrap gap-1.5">
                <Button type="button" variant="outline" size="sm" className="h-7 text-xs gap-1"
                  onClick={() => { editor.chain().focus().addRowAfter().run(); setTableDialog(d => ({ ...d, open: false })) }}>
                  <Plus className="h-3 w-3" />{t('html.addRowAfter', '+Fila')}
                </Button>
                <Button type="button" variant="outline" size="sm" className="h-7 text-xs gap-1"
                  onClick={() => { editor.chain().focus().deleteRow().run(); setTableDialog(d => ({ ...d, open: false })) }}>
                  <Minus className="h-3 w-3" />{t('html.deleteRow', '−Fila')}
                </Button>
                <Button type="button" variant="outline" size="sm" className="h-7 text-xs gap-1"
                  onClick={() => { editor.chain().focus().addColumnAfter().run(); setTableDialog(d => ({ ...d, open: false })) }}>
                  <Plus className="h-3 w-3" />{t('html.addColAfter', '+Col')}
                </Button>
                <Button type="button" variant="outline" size="sm" className="h-7 text-xs gap-1"
                  onClick={() => { editor.chain().focus().deleteColumn().run(); setTableDialog(d => ({ ...d, open: false })) }}>
                  <Minus className="h-3 w-3" />{t('html.deleteCol', '−Col')}
                </Button>
                <Button type="button" variant="outline" size="sm" className="h-7 text-xs gap-1 text-destructive hover:text-destructive"
                  onClick={() => { editor.chain().focus().deleteTable().run(); setTableDialog(d => ({ ...d, open: false })) }}>
                  <Trash2 className="h-3 w-3" />{t('html.deleteTable', 'Eliminar taula')}
                </Button>
              </div>
            </div>
          ) : (
            <div className="flex flex-wrap gap-2 items-end">
              <div className="space-y-1">
                <label className="text-xs text-muted-foreground">{t('html.tableRows', 'Files')}</label>
                <Input type="number" min={1} max={20} value={tableDialog.rows}
                  onChange={e => setTableDialog(d => ({ ...d, rows: Math.max(1, parseInt(e.target.value) || 1) }))}
                  className="h-7 text-xs w-16" />
              </div>
              <div className="space-y-1">
                <label className="text-xs text-muted-foreground">{t('html.tableCols', 'Columnes')}</label>
                <Input type="number" min={1} max={10} value={tableDialog.cols}
                  onChange={e => setTableDialog(d => ({ ...d, cols: Math.max(1, parseInt(e.target.value) || 1) }))}
                  className="h-7 text-xs w-16" />
              </div>
              <Button type="button" size="sm" className="h-7 text-xs" onClick={insertTable}>
                <Table2 className="h-3.5 w-3.5 mr-1" />{t('html.insertTableNow', 'Inserir')}
              </Button>
            </div>
          )}
        </div>
      )}

      {/* Mini-dialog per inserir camp de signatura */}
      {fieldDialog.open && (
        <div className="border-b px-3 py-2 bg-muted/30 space-y-2">
          <p className="text-xs font-medium">{t('html.insertField', 'Inserir camp de firma')}</p>
          <div className="flex flex-wrap gap-2 items-end">
            {/* Tipus de camp */}
            <div className="space-y-1">
              <label className="text-xs text-muted-foreground">{t('html.fieldType', 'Tipus')}</label>
              <select
                title={t('html.fieldType', 'Tipus')}
                value={fieldDialog.fieldType}
                onChange={e => setFieldDialog(d => ({ ...d, fieldType: e.target.value as SigningFieldType }))}
                className="h-7 text-xs border border-input rounded-md px-1.5 bg-background"
              >
                {(Object.keys(FIELD_TAG) as SigningFieldType[]).map(ft => (
                  <option key={ft} value={ft}>
                    {t(`html.fieldType_${ft}`, ft.charAt(0).toUpperCase() + ft.slice(1))}
                  </option>
                ))}
              </select>
            </div>
            {/* Rol */}
            <div className="space-y-1">
              <label className="text-xs text-muted-foreground">{t('html.fieldRole', 'Rol')}</label>
              <select
                title={t('html.fieldRole', 'Rol de signatura')}
                value={fieldDialog.role}
                onChange={e => setFieldDialog(d => ({ ...d, role: e.target.value }))}
                className="h-7 text-xs border border-input rounded-md px-1.5 bg-background"
              >
                {signingRoles.map(r => <option key={r} value={r}>{r}</option>)}
              </select>
            </div>
            {/* Nom del camp */}
            <div className="space-y-1">
              <label className="text-xs text-muted-foreground">{t('html.fieldName', 'Nom')}</label>
              <Input
                value={fieldDialog.fieldName}
                onChange={e => setFieldDialog(d => ({ ...d, fieldName: e.target.value }))}
                className="h-7 text-xs w-28"
                placeholder={t('html.fieldNamePlaceholder', 'Firma1')}
              />
            </div>
            {/* Obligatori */}
            <div className="flex items-center gap-1.5 pb-1">
              <input
                id="field-required"
                type="checkbox"
                checked={fieldDialog.required}
                onChange={e => setFieldDialog(d => ({ ...d, required: e.target.checked }))}
                className="h-3.5 w-3.5"
              />
              <label htmlFor="field-required" className="text-xs">{t('html.fieldRequired', 'Obligatori')}</label>
            </div>
            <Button type="button" size="sm" className="h-7 text-xs" onClick={insertSigningField}
              disabled={!fieldDialog.role || !fieldDialog.fieldName.trim()}
            >
              {FIELD_ICONS[fieldDialog.fieldType]}
              <span className="ml-1">{t('html.insertNow', 'Inserir')}</span>
            </Button>
            <Button type="button" variant="ghost" size="sm" className="h-7 text-xs"
              onClick={() => setFieldDialog(d => ({ ...d, open: false }))}
            >
              {t('common.cancel', 'Cancel·lar')}
            </Button>
          </div>
        </div>
      )}

      {/* Editor o raw HTML */}
      {showRaw ? (
        <div className="space-y-2 p-2">
          <textarea
            className="w-full h-48 font-mono text-xs border border-input rounded-md p-2 bg-background resize-y"
            value={rawHtml}
            onChange={e => setRawHtml(e.target.value)}
            placeholder={t('html.rawPlaceholder', '<p>HTML de la plantilla...</p>')}
            title={t('html.rawHtml', 'HTML raw')}
          />
          <div className="flex gap-2">
            <Button type="button" size="sm" className="h-7 text-xs" onClick={applyRawHtml}>
              {t('html.applyRaw', 'Aplicar HTML')}
            </Button>
            <Button type="button" variant="ghost" size="sm" className="h-7 text-xs" onClick={() => setShowRaw(false)}>
              {t('common.cancel', 'Cancel·lar')}
            </Button>
          </div>
        </div>
      ) : (
        <EditorContent editor={editor} />
      )}
    </div>
  )
}
