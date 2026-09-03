'use client'

import { useEditor, EditorContent } from '@tiptap/react'
import StarterKit from '@tiptap/starter-kit'
import Placeholder from '@tiptap/extension-placeholder'
import Link from '@tiptap/extension-link'
import { Bold, Italic, Heading2, Heading3, List, ListOrdered, Link2, Link2Off } from 'lucide-react'
import { useCallback, useState } from 'react'
import { Popover, PopoverContent, PopoverTrigger } from '@/components/ui/popover'
import { Input } from '@/components/ui/input'
import { Button } from '@/components/ui/button'

interface RichTextEditorProps {
  value: string
  onChange: (html: string) => void
  placeholder?: string
  maxChars?: number
  disabled?: boolean
  className?: string
  onBlur?: () => void
  linkHint?: string
}

/**
 * Editor de text enriquit basat en TipTap.
 * Desa el contingut com a HTML (compatible amb PortalPageContent del public-portal).
 * Mostra un comptador de caràcters si maxChars > 0.
 */
export function RichTextEditor({
  value,
  onChange,
  placeholder = '',
  maxChars = 0,
  disabled = false,
  className = '',
  onBlur,
  linkHint,
}: RichTextEditorProps) {
  const [linkOpen, setLinkOpen] = useState(false)
  const [linkUrl, setLinkUrl] = useState('https://')

  const editor = useEditor({
    extensions: [
      StarterKit.configure({ codeBlock: false }),
      Placeholder.configure({ placeholder }),
      Link.configure({
        openOnClick: false,
        autolink: true,
        HTMLAttributes: {
          target: '_blank',
          rel: 'noopener noreferrer',
        },
      }),
    ],
    content: value || '',
    editable: !disabled,
    onUpdate: ({ editor: ed }) => {
      const html = ed.getHTML()
      onChange(html === '<p></p>' ? '' : html)
    },
    onCreate: ({ editor: ed }) => {
      if (value && ed.getHTML() !== value) {
        ed.commands.setContent(value)
      }
    },
    onBlur: () => {
      onBlur?.()
    },
  })

  if (editor && value !== editor.getHTML() && value !== (editor.getHTML() === '<p></p>' ? '' : editor.getHTML())) {
    editor.commands.setContent(value || '')
  }

  const openLinkPopover = useCallback(() => {
    if (!editor) return
    const previousUrl = editor.getAttributes('link').href as string | undefined
    setLinkUrl(previousUrl || 'https://')
    setLinkOpen(true)
  }, [editor])

  function applyLink() {
    if (!editor) return
    const url = linkUrl.trim()
    if (!url || url === 'https://') {
      editor.chain().focus().extendMarkRange('link').unsetLink().run()
    } else {
      const href = /^https?:\/\//i.test(url) ? url : `https://${url}`
      editor.chain().focus().extendMarkRange('link').setLink({ href }).run()
    }
    setLinkOpen(false)
  }

  const charCount = editor ? editor.getText().length : 0
  const isOverLimit = maxChars > 0 && charCount > maxChars
  const isNearLimit = maxChars > 0 && charCount > maxChars * 0.8 && !isOverLimit

  return (
    <div className={`rounded-md border border-input bg-background ${isOverLimit ? 'border-destructive' : ''} ${className}`}>
      {!disabled && editor && (
        <div className="flex items-center gap-0.5 px-2 py-1.5 border-b border-input flex-wrap">
          <ToolbarButton
            active={editor.isActive('bold')}
            onClick={() => editor.chain().focus().toggleBold().run()}
            title="Negreta"
          >
            <Bold className="h-3.5 w-3.5" />
          </ToolbarButton>
          <ToolbarButton
            active={editor.isActive('italic')}
            onClick={() => editor.chain().focus().toggleItalic().run()}
            title="Cursiva"
          >
            <Italic className="h-3.5 w-3.5" />
          </ToolbarButton>
          <div className="w-px h-4 bg-border mx-0.5" />
          <ToolbarButton
            active={editor.isActive('heading', { level: 2 })}
            onClick={() => editor.chain().focus().toggleHeading({ level: 2 }).run()}
            title="Títol H2"
          >
            <Heading2 className="h-3.5 w-3.5" />
          </ToolbarButton>
          <ToolbarButton
            active={editor.isActive('heading', { level: 3 })}
            onClick={() => editor.chain().focus().toggleHeading({ level: 3 }).run()}
            title="Títol H3"
          >
            <Heading3 className="h-3.5 w-3.5" />
          </ToolbarButton>
          <div className="w-px h-4 bg-border mx-0.5" />
          <ToolbarButton
            active={editor.isActive('bulletList')}
            onClick={() => editor.chain().focus().toggleBulletList().run()}
            title="Llista"
          >
            <List className="h-3.5 w-3.5" />
          </ToolbarButton>
          <ToolbarButton
            active={editor.isActive('orderedList')}
            onClick={() => editor.chain().focus().toggleOrderedList().run()}
            title="Llista numerada"
          >
            <ListOrdered className="h-3.5 w-3.5" />
          </ToolbarButton>
          <div className="w-px h-4 bg-border mx-0.5" />
          <Popover open={linkOpen} onOpenChange={setLinkOpen}>
            <PopoverTrigger asChild>
              <button
                type="button"
                onMouseDown={(e) => {
                  e.preventDefault()
                  openLinkPopover()
                }}
                title="Afegir enllaç"
                className={[
                  'p-1 rounded transition-colors',
                  editor.isActive('link')
                    ? 'bg-primary text-primary-foreground'
                    : 'text-muted-foreground hover:bg-muted hover:text-foreground',
                ].join(' ')}
              >
                <Link2 className="h-3.5 w-3.5" />
              </button>
            </PopoverTrigger>
            <PopoverContent className="w-80 space-y-2 p-3" align="start">
              <p className="text-xs text-muted-foreground">
                {linkHint ??
                  'Pots enllaçar Drive, YouTube, manuals o altres documents externs.'}
              </p>
              <Input
                value={linkUrl}
                onChange={(e) => setLinkUrl(e.target.value)}
                placeholder="https://"
                className="h-8 text-sm"
                onKeyDown={(e) => {
                  if (e.key === 'Enter') {
                    e.preventDefault()
                    applyLink()
                  }
                }}
                autoFocus
              />
              <div className="flex justify-end gap-2">
                <Button type="button" size="sm" variant="ghost" className="h-7" onClick={() => setLinkOpen(false)}>
                  Cancel·lar
                </Button>
                <Button type="button" size="sm" className="h-7" onClick={applyLink}>
                  Aplicar
                </Button>
              </div>
            </PopoverContent>
          </Popover>
          {editor.isActive('link') && (
            <ToolbarButton
              active={false}
              onClick={() => editor.chain().focus().unsetLink().run()}
              title="Eliminar enllaç"
            >
              <Link2Off className="h-3.5 w-3.5" />
            </ToolbarButton>
          )}
        </div>
      )}

      <EditorContent
        editor={editor}
        className={`prose prose-sm max-w-none px-3 py-2 min-h-[120px] focus-within:outline-none [&_.tiptap]:outline-none [&_.tiptap_p.is-editor-empty:first-child]:before:content-[attr(data-placeholder)] [&_.tiptap_p.is-editor-empty:first-child]:before:text-muted-foreground [&_.tiptap_p.is-editor-empty:first-child]:before:pointer-events-none [&_.tiptap_p.is-editor-empty:first-child]:before:float-left [&_.tiptap_p.is-editor-empty:first-child]:before:h-0 ${disabled ? 'opacity-50 cursor-not-allowed' : ''}`}
      />

      {maxChars > 0 && (
        <div
          className={`px-3 py-1 text-xs text-right border-t border-input ${
            isOverLimit
              ? 'text-destructive bg-destructive/5'
              : isNearLimit
              ? 'text-amber-600 bg-amber-50'
              : 'text-muted-foreground'
          }`}
        >
          {charCount.toLocaleString()} / {maxChars.toLocaleString()}
        </div>
      )}
    </div>
  )
}

function ToolbarButton({
  active,
  onClick,
  title,
  children,
}: {
  active: boolean
  onClick: () => void
  title: string
  children: React.ReactNode
}) {
  return (
    <button
      type="button"
      onMouseDown={(e) => {
        e.preventDefault()
        onClick()
      }}
      title={title}
      className={[
        'p-1 rounded transition-colors',
        active
          ? 'bg-primary text-primary-foreground'
          : 'text-muted-foreground hover:bg-muted hover:text-foreground',
      ].join(' ')}
    >
      {children}
    </button>
  )
}
