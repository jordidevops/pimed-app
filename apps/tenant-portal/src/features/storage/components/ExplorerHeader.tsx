import { useRef, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { useExplorer } from '../contexts/ExplorerContext'
import { useDebounce } from '../utils/fileUtils'

interface ExplorerHeaderProps {
  onUploadClick: () => void
  onCreateFolder: (name: string) => Promise<void>
  activeDriveName: string | null
  isByosDrive: boolean
  showDriveScope: boolean
}

export function ExplorerHeader({
  onUploadClick,
  onCreateFolder,
  activeDriveName,
  isByosDrive,
  showDriveScope,
}: ExplorerHeaderProps) {
  const { t } = useTranslation('storage')
  const { state, navigateBreadcrumb, navigateUp, setSearch } = useExplorer()
  const [localQuery, setLocalQuery] = useState(state.searchQuery)
  const inputRef = useRef<HTMLInputElement>(null)
  const folderInputRef = useRef<HTMLInputElement>(null)

  const [folderModalOpen, setFolderModalOpen] = useState(false)
  const [folderName, setFolderName] = useState('')
  const [folderError, setFolderError] = useState<string | null>(null)
  const [folderPending, setFolderPending] = useState(false)

  const canGoUp = state.view === 'files' && state.currentFolderId != null

  // Debounce search input 300ms
  const debouncedQuery = useDebounce(localQuery, 300)
  // Sync debounced value to context
  if (debouncedQuery !== state.searchQuery) {
    setSearch(debouncedQuery)
  }

  function openFolderModal() {
    setFolderName('')
    setFolderError(null)
    setFolderModalOpen(true)
    setTimeout(() => folderInputRef.current?.focus(), 50)
  }

  function closeFolderModal() {
    if (!folderPending) setFolderModalOpen(false)
  }

  async function handleFolderSubmit(e: React.FormEvent) {
    e.preventDefault()
    const name = folderName.trim()
    if (!name) return
    setFolderPending(true)
    setFolderError(null)
    try {
      await onCreateFolder(name)
      setFolderModalOpen(false)
      setFolderName('')
    } catch (err) {
      const code = (err as any)?.code
      setFolderError(
        code === 'duplicate_name'
          ? t('storage.folder.error_duplicate', 'Ja existeix un element amb aquest nom')
          : t('storage.folder.error_generic', "No s'ha pogut completar l'operació"),
      )
    } finally {
      setFolderPending(false)
    }
  }

  return (
    <>
      <header className={`px-4 py-3 border-b shrink-0 ${
        isByosDrive
          ? 'border-indigo-200 bg-indigo-50/40'
          : 'border-border bg-card'
      }`}>
        {/* Top row: path/title */}
        <div className="min-h-6 mb-3">
          {state.view === 'files' && (
            <div className="flex items-center gap-2 min-w-0">
              <button
                type="button"
                onClick={() => navigateUp()}
                disabled={!canGoUp}
                className="shrink-0 inline-flex items-center justify-center rounded-md border border-border bg-card p-1.5 text-muted-foreground hover:bg-accent hover:text-foreground disabled:opacity-40 disabled:pointer-events-none transition"
                title={t('storage.explorer.go_up', 'Pujar')}
                aria-label={t('storage.explorer.go_up', 'Pujar')}
              >
                <svg className="h-4 w-4" viewBox="0 0 20 20" fill="currentColor" aria-hidden>
                  <path
                    fillRule="evenodd"
                    d="M10 17a.75.75 0 0 1-.75-.75V5.612L5.29 9.77a.75.75 0 0 1-1.08-1.04l5.25-5.5a.75.75 0 0 1 1.08 0l5.25 5.5a.75.75 0 1 1-1.08 1.04l-3.96-4.158V16.25A.75.75 0 0 1 10 17Z"
                    clipRule="evenodd"
                  />
                </svg>
              </button>
              <nav className="flex items-center gap-1 text-sm min-w-0" aria-label="Breadcrumbs">
                {state.breadcrumbs.map((crumb, i) => {
                  const isLast = i === state.breadcrumbs.length - 1
                  return (
                    <span key={crumb.id ?? 'root'} className="flex items-center gap-1 min-w-0">
                      {i > 0 && <span className="text-muted-foreground/40 shrink-0">/</span>}
                      {isLast ? (
                        <span className="font-medium text-foreground truncate max-w-[40vw] sm:max-w-[52vw]">{crumb.name}</span>
                      ) : (
                        <button
                          type="button"
                          onClick={() => navigateBreadcrumb(i)}
                          className="text-muted-foreground hover:text-primary truncate transition-colors max-w-[22vw] sm:max-w-[30vw]"
                        >
                          {crumb.name}
                        </button>
                      )}
                    </span>
                  )
                })}
              </nav>
            </div>
          )}

          {state.view === 'starred' && (
            <h2 className="text-sm font-semibold text-foreground">
              {t('storage.explorer.nav_starred', 'Destacats')}
            </h2>
          )}
          {state.view === 'trash' && (
            <h2 className="text-sm font-semibold text-foreground">
              {t('storage.explorer.nav_trash', 'Paperera')}
            </h2>
          )}
        </div>

        {/* Bottom row: drive context + search + actions */}
        <div className="flex flex-wrap items-center justify-between gap-2">
          {showDriveScope ? (
            <div
              className={`inline-flex items-center gap-2 rounded-full border px-2.5 py-1 text-xs font-medium ${
                isByosDrive
                  ? 'border-indigo-200 bg-indigo-100 text-indigo-800'
                  : 'border-emerald-200 bg-emerald-50 text-emerald-800'
              }`}
              title={t('storage.explorer.drive_scope_hint', 'Els fitxers nous es pujaran a aquesta unitat')}
            >
              <span aria-hidden>{isByosDrive ? '🪣' : '🏠'}</span>
              <span>
                {isByosDrive
                  ? t('storage.explorer.drive_scope_byos', 'Unitat activa: {{name}}', {
                    name: activeDriveName ?? t('storage.drives.app_drive_title', 'App Drive'),
                  })
                  : t('storage.explorer.drive_scope_app', 'Unitat activa: App Drive')}
              </span>
            </div>
          ) : (
            <div />
          )}

          <div className="flex flex-wrap items-center justify-end gap-2">
          <div className="relative w-full sm:w-72 sm:max-w-[55%]">
        <input
          ref={inputRef}
          type="search"
          value={localQuery}
          onChange={(e) => setLocalQuery(e.target.value)}
          placeholder={t('storage.explorer.search_placeholder', 'Cerca fitxers...')}
          className="w-full pl-8 pr-3 py-1.5 text-sm border border-input rounded-lg bg-muted/50 text-foreground focus:bg-background focus:border-primary focus:ring-1 focus:ring-primary/20 outline-none transition"
          aria-label={t('storage.explorer.search_label', 'Cerca fitxers')}
        />
        <svg className="absolute left-2.5 top-1/2 -translate-y-1/2 h-3.5 w-3.5 text-muted-foreground pointer-events-none" viewBox="0 0 20 20" fill="currentColor" aria-hidden>
          <path fillRule="evenodd" d="M9 3.5a5.5 5.5 0 1 0 0 11 5.5 5.5 0 0 0 0-11ZM2 9a7 7 0 1 1 12.452 4.391l3.328 3.329a.75.75 0 1 1-1.06 1.06l-3.329-3.328A7 7 0 0 1 2 9Z" clipRule="evenodd" />
        </svg>
          </div>

      {/* Upload button — only in files view */}
      {state.view === 'files' && (
        <>
          <button
            type="button"
            onClick={openFolderModal}
            className="flex items-center gap-1.5 rounded-lg border border-border bg-card px-3 py-1.5 text-sm font-medium text-foreground hover:bg-accent transition shrink-0"
          >
            <svg className="h-4 w-4" viewBox="0 0 20 20" fill="currentColor" aria-hidden>
              <path d="M3.75 3A1.75 1.75 0 0 0 2 4.75v10.5c0 .966.784 1.75 1.75 1.75h12.5A1.75 1.75 0 0 0 18 15.25v-8.5A1.75 1.75 0 0 0 16.25 5h-4.836a.25.25 0 0 1-.177-.073L9.823 3.513A1.75 1.75 0 0 0 8.586 3H3.75Z" />
              <path d="M10 8a.75.75 0 0 1 .75.75v1.5h1.5a.75.75 0 0 1 0 1.5h-1.5v1.5a.75.75 0 0 1-1.5 0v-1.5h-1.5a.75.75 0 0 1 0-1.5h1.5v-1.5A.75.75 0 0 1 10 8Z" />
            </svg>
            {t('storage.folder.new_btn', 'Nova carpeta')}
          </button>
          <button
            type="button"
            onClick={onUploadClick}
            className="flex items-center gap-1.5 rounded-lg bg-indigo-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-indigo-700 transition shrink-0"
          >
            <svg className="h-4 w-4" viewBox="0 0 20 20" fill="currentColor" aria-hidden>
              <path d="M9.25 13.25a.75.75 0 0 0 1.5 0V4.636l2.955 3.129a.75.75 0 0 0 1.09-1.03l-4.25-4.5a.75.75 0 0 0-1.09 0l-4.25 4.5a.75.75 0 1 0 1.09 1.03L9.25 4.636v8.614Z" />
              <path d="M3.5 12.75a.75.75 0 0 0-1.5 0v2.5A2.75 2.75 0 0 0 4.75 18h10.5A2.75 2.75 0 0 0 18 15.25v-2.5a.75.75 0 0 0-1.5 0v2.5c0 .69-.56 1.25-1.25 1.25H4.75c-.69 0-1.25-.56-1.25-1.25v-2.5Z" />
            </svg>
            {t('storage.actions.upload', 'Pujar fitxer')}
          </button>
        </>
      )}
          </div>
        </div>
      </header>

    {/* Create folder modal */}
    {folderModalOpen && (
      <div
        className="fixed inset-0 z-50 flex items-center justify-center bg-black/50 backdrop-blur-sm"
        onClick={(e) => { if (e.target === e.currentTarget) closeFolderModal() }}
      >
        <div className="bg-card rounded-xl shadow-xl w-full max-w-sm mx-4 p-6">
          <h2 className="text-base font-semibold text-foreground mb-4">
            {t('storage.folder.modal_title', 'Nova carpeta')}
          </h2>
          <form onSubmit={handleFolderSubmit}>
            <input
              ref={folderInputRef}
              type="text"
              value={folderName}
              onChange={(e) => { setFolderName(e.target.value); setFolderError(null) }}
              placeholder={t('storage.folder.name_placeholder', 'Nom de la carpeta')}
              className="w-full rounded-lg border border-input bg-background text-foreground px-3 py-2 text-sm focus:border-primary focus:ring-1 focus:ring-primary/20 outline-none"
              maxLength={255}
              disabled={folderPending}
            />
            {folderError && (
              <p className="mt-2 text-xs text-red-600">{folderError}</p>
            )}
            <div className="mt-4 flex justify-end gap-2">
              <button
                type="button"
                onClick={closeFolderModal}
                disabled={folderPending}
                className="rounded-lg border border-border px-3 py-1.5 text-sm text-foreground hover:bg-accent transition"
              >
                {t('storage.actions.cancel', 'Cancel·lar')}
              </button>
              <button
                type="submit"
                disabled={folderPending || !folderName.trim()}
                className="rounded-lg bg-indigo-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-indigo-700 disabled:opacity-50 transition"
              >
                {folderPending
                  ? t('storage.folder.creating', 'Creant...')
                  : t('storage.folder.create_btn', 'Crear')}
              </button>
            </div>
          </form>
        </div>
      </div>
    )}
  </>
  )
}
