import { useEffect, useRef, useState } from 'react'
import { useTranslation } from 'react-i18next'
import type { User } from '@supabase/supabase-js'
import { Camera, Trash2 } from 'lucide-react'
import { useAuth } from '../contexts/AuthContext'
import { useTenant } from '../contexts/TenantContext'
import { supabase } from '../lib/supabase'
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from '../components/ui/dropdown-menu'
import { compressImage } from '../utils/imageOptimizer'

function InfoItem({ label, value, mono }: { label: string; value: string; mono?: boolean }) {
  return (
    <div className="bg-muted/50 rounded-xl p-4">
      <p className="text-xs text-muted-foreground font-medium uppercase tracking-wide mb-1">{label}</p>
      <p className={`text-sm text-foreground ${mono ? 'font-mono break-all' : ''}`}>{value}</p>
    </div>
  )
}

interface AvatarUploadProps {
  user: User
  initials: string
  /** URL canònica carregada de data.profiles (prioritat sobre auth metadata) */
  initialUrl: string | null
  /** Notifica el pare quan la URL canvia (per actualitzar la capçalera del perfil) */
  onUrlChange: (url: string | null) => void
}

function AvatarUpload({ user, initials, initialUrl, onUrlChange }: AvatarUploadProps) {
  const { t } = useTranslation('auth')
  const { activeTenant } = useTenant()
  const inputRef = useRef<HTMLInputElement>(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  // localUrl: blob URL per a preview optimista; null = usar initialUrl
  const [localUrl, setLocalUrl] = useState<string | null>(null)
  // Sincronitza quan el pare carrega la URL des de DB
  const [syncedUrl, setSyncedUrl] = useState<string | null>(initialUrl)
  useEffect(() => {
    if (localUrl === null) setSyncedUrl(initialUrl)
  }, [initialUrl, localUrl])

  const displayUrl = localUrl ?? syncedUrl
  const hasAvatar = displayUrl !== null

  const storagePath = `${activeTenant?.id}/${user.id}/avatar`

  const handleFileChange = async (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0]
    if (inputRef.current) inputRef.current.value = ''
    if (!file) return

    if (!['image/jpeg', 'image/png', 'image/webp'].includes(file.type)) {
      setError(t('avatar.invalidType', "Només s'accepten imatges JPEG, PNG o WebP."))
      return
    }
    if (!activeTenant) {
      setError(t('avatar.noTenant', 'Selecciona un tenant abans de canviar la foto.'))
      return
    }

    setError(null)
    setBusy(true)
    try {
      const compressed = await compressImage(file)

      const { error: uploadError } = await supabase.storage
        .from('avatars')
        .upload(storagePath, compressed, { upsert: true, contentType: compressed.type })
      if (uploadError) throw uploadError

      const { data } = supabase.storage.from('avatars').getPublicUrl(storagePath)
      const urlWithBust = `${data.publicUrl}?t=${Date.now()}`

      // Persistir a data.profiles via RPC (font canònica)
      const { error: rpcError } = await supabase.rpc('update_my_avatar', { p_avatar_url: urlWithBust })
      if (rpcError) throw rpcError

      // Persistir a auth.users.raw_user_meta_data (fallback / OAuth)
      await supabase.auth.updateUser({ data: { avatar_url: urlWithBust } })

      // Preview optimista: blob URL fins que el navegador carregui la CDN
      if (localUrl) URL.revokeObjectURL(localUrl)
      const blobUrl = URL.createObjectURL(compressed)
      setLocalUrl(blobUrl)
      setSyncedUrl(urlWithBust)
      onUrlChange(urlWithBust)
    } catch {
      setError(t('avatar.uploadError', 'Error en pujar la imatge. Torna-ho a intentar.'))
    } finally {
      setBusy(false)
    }
  }

  const handleDelete = async () => {
    if (!activeTenant || !hasAvatar) return
    setError(null)
    setBusy(true)
    try {
      const { error: removeError } = await supabase.storage
        .from('avatars')
        .remove([storagePath])
      if (removeError) throw removeError

      // Netejar a data.profiles
      const { error: rpcError } = await supabase.rpc('update_my_avatar', { p_avatar_url: null as unknown as string })
      if (rpcError) throw rpcError

      // Netejar a auth metadata
      await supabase.auth.updateUser({ data: { avatar_url: null } })

      if (localUrl) URL.revokeObjectURL(localUrl)
      setLocalUrl(null)
      setSyncedUrl(null)
      onUrlChange(null)
    } catch {
      setError(t('avatar.deleteError', "Error en eliminar la foto. Torna-ho a intentar."))
    } finally {
      setBusy(false)
    }
  }

  const avatarContent = displayUrl ? (
    <img src={displayUrl} alt="" className="w-full h-full object-cover" />
  ) : (
    <div className="w-full h-full bg-indigo-100 flex items-center justify-center text-indigo-700 font-bold text-xl select-none">
      {initials}
    </div>
  )

  return (
    <div className="flex flex-col items-center gap-2">
      <DropdownMenu>
        <DropdownMenuTrigger asChild>
          <button
            type="button"
            disabled={busy}
            className="relative w-20 h-20 rounded-full overflow-hidden group focus:outline-none focus-visible:ring-2 focus-visible:ring-indigo-500 focus-visible:ring-offset-2 cursor-pointer disabled:cursor-not-allowed"
            aria-label={t('avatar.menuLabel', 'Opcions de foto de perfil')}
          >
            {avatarContent}

            {!busy && (
              <div className="absolute inset-0 bg-black/45 flex items-center justify-center opacity-0 group-hover:opacity-100 transition-opacity duration-200">
                <Camera className="w-6 h-6 text-white" />
              </div>
            )}

            {busy && (
              <div className="absolute inset-0 bg-black/60 flex items-center justify-center">
                <div className="w-6 h-6 border-2 border-white border-t-transparent rounded-full animate-spin" />
              </div>
            )}
          </button>
        </DropdownMenuTrigger>

        <DropdownMenuContent align="center" className="w-48">
          <DropdownMenuItem
            onSelect={() => inputRef.current?.click()}
            className="cursor-pointer gap-2"
          >
            <Camera className="w-4 h-4" />
            {t('avatar.changePhoto', 'Canviar foto')}
          </DropdownMenuItem>

          {hasAvatar && (
            <>
              <DropdownMenuSeparator />
              <DropdownMenuItem
                onSelect={handleDelete}
                className="cursor-pointer gap-2 text-destructive focus:text-destructive"
              >
                <Trash2 className="w-4 h-4" />
                {t('avatar.deletePhoto', 'Eliminar foto')}
              </DropdownMenuItem>
            </>
          )}
        </DropdownMenuContent>
      </DropdownMenu>

      {error && (
        <p role="alert" className="text-xs text-red-600 text-center max-w-40">{error}</p>
      )}

      <input
        ref={inputRef}
        type="file"
        accept="image/jpeg,image/png,image/webp"
        className="hidden"
        onChange={handleFileChange}
        title={t('avatar.selectPhoto', 'Seleccionar foto')}
        aria-label={t('avatar.selectPhoto', 'Seleccionar foto')}
      />
    </div>
  )
}

function ChangePasswordSection({ user }: { user: User }) {
  const { t } = useTranslation('auth')
  const [currentPwd, setCurrentPwd] = useState('')
  const [newPwd, setNewPwd] = useState('')
  const [confirmPwd, setConfirmPwd] = useState('')
  const [pending, setPending] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [success, setSuccess] = useState(false)

  const provider = (user.app_metadata?.provider as string | undefined) ?? 'email'

  if (provider !== 'email') {
    return (
      <div className="mt-6 rounded-xl bg-amber-50 border border-amber-200 px-4 py-3 text-sm text-amber-700 dark:bg-amber-950/50 dark:border-amber-800 dark:text-amber-400">
        {t('changePassword.oauthHint', 'El teu compte usa un proveïdor extern (Google) per autenticar-se. No pots canviar la contrasenya aquí.')}
      </div>
    )
  }

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault()
    setError(null)
    setSuccess(false)

    if (!currentPwd) {
      setError(t('changePassword.currentRequired', 'La contrasenya actual és obligatòria.'))
      return
    }
    if (newPwd.length < 8) {
      setError(t('changePassword.minLength', 'La contrasenya ha de tenir com a mínim 8 caràcters.'))
      return
    }
    if (newPwd !== confirmPwd) {
      setError(t('changePassword.mismatch', 'Les contrasenyes no coincideixen.'))
      return
    }

    setPending(true)
    // Re-authenticate to verify the current password before updating
    const { error: authError } = await supabase.auth.signInWithPassword({
      email: user.email!,
      password: currentPwd,
    })
    if (authError) {
      setPending(false)
      setError(t('changePassword.wrongPassword', 'La contrasenya actual no és correcta.'))
      return
    }

    const { error: updateError } = await supabase.auth.updateUser({ password: newPwd })
    setPending(false)
    if (updateError) {
      setError(updateError.message)
      return
    }

    setSuccess(true)
    setCurrentPwd('')
    setNewPwd('')
    setConfirmPwd('')
  }

  return (
    <div className="mt-6 border-t border-border pt-6">
      <h2 className="text-sm font-semibold text-foreground mb-4">
        {t('changePassword.title', 'Canviar contrasenya')}
      </h2>
      {success && (
        <div className="mb-4 bg-green-50 border border-green-200 text-green-700 px-4 py-3 rounded-lg text-sm dark:bg-green-950/50 dark:border-green-800 dark:text-green-400">
          {t('changePassword.success', 'Contrasenya canviada correctament.')}
        </div>
      )}
      <form onSubmit={handleSubmit} noValidate className="space-y-4 max-w-sm">
        <div>
          <label htmlFor="current-pwd" className="block text-sm font-medium text-foreground mb-1">
            {t('changePassword.currentLabel', 'Contrasenya actual')}
          </label>
          <input
            id="current-pwd"
            type="password"
            autoComplete="current-password"
            value={currentPwd}
            onChange={(e) => setCurrentPwd(e.target.value)}
            placeholder={t('changePassword.currentPlaceholder', 'La teva contrasenya actual')}
            className="w-full px-4 py-2.5 border border-input rounded-lg focus:ring-2 focus:ring-primary focus:border-transparent outline-none transition bg-background text-foreground"
          />
        </div>
        <div>
          <label htmlFor="new-pwd" className="block text-sm font-medium text-foreground mb-1">
            {t('changePassword.newLabel', 'Nova contrasenya')}
          </label>
          <input
            id="new-pwd"
            type="password"
            autoComplete="new-password"
            value={newPwd}
            onChange={(e) => setNewPwd(e.target.value)}
            placeholder={t('changePassword.newPlaceholder', 'Mínim 8 caràcters')}
            className="w-full px-4 py-2.5 border border-input rounded-lg focus:ring-2 focus:ring-primary focus:border-transparent outline-none transition bg-background text-foreground"
          />
        </div>
        <div>
          <label htmlFor="confirm-pwd" className="block text-sm font-medium text-foreground mb-1">
            {t('changePassword.confirmLabel', 'Confirmar nova contrasenya')}
          </label>
          <input
            id="confirm-pwd"
            type="password"
            autoComplete="new-password"
            value={confirmPwd}
            onChange={(e) => setConfirmPwd(e.target.value)}
            placeholder={t('changePassword.confirmPlaceholder', 'Repeteix la nova contrasenya')}
            className="w-full px-4 py-2.5 border border-input rounded-lg focus:ring-2 focus:ring-primary focus:border-transparent outline-none transition bg-background text-foreground"
          />
        </div>
        {error && (
          <div role="alert" className="bg-red-50 border border-red-200 text-red-700 px-4 py-3 rounded-lg text-sm dark:bg-red-950/50 dark:border-red-800 dark:text-red-400">
            {error}
          </div>
        )}
        <button
          type="submit"
          disabled={pending || !currentPwd || !newPwd || !confirmPwd}
          className="bg-indigo-600 hover:bg-indigo-700 disabled:opacity-50 text-white text-sm font-semibold px-5 py-2.5 rounded-lg transition"
        >
          {pending
            ? t('changePassword.submitting', 'Desant...')
            : t('changePassword.submit', 'Canviar contrasenya')}
        </button>
      </form>
    </div>
  )
}

export function ProfilePage() {
  const { t } = useTranslation('auth')
  const { user } = useAuth()
  // URL canònica de data.profiles. undefined = encara carregant, null = no té avatar.
  const [dbAvatarUrl, setDbAvatarUrl] = useState<string | null | undefined>(undefined)

  useEffect(() => {
    if (!user) return
    // Llegir avatar_url de la font canònica (data.profiles via api.my_profile)
    supabase
      .from('my_profile')
      .select('avatar_url')
      .maybeSingle()
      .then(({ data }) => {
        setDbAvatarUrl(data?.avatar_url ?? null)
      })
  }, [user?.id])

  if (!user) return null

  // Prioritat: DB (data.profiles) → auth metadata → null
  // ?? permet caure a auth metadata si DB retorna null (perfil sense avatar ancora
  // sincronitzat, p. ex. uploads anteriors fallits) i evita el flicker.
  const canonicalAvatarUrl =
    dbAvatarUrl ??
    (user.user_metadata?.avatar_url as string | undefined) ??
    null

  const provider = (user.app_metadata?.provider as string | undefined) ?? 'email'
  const createdAt = new Date(user.created_at).toLocaleDateString('ca-ES', {
    year: 'numeric',
    month: 'long',
    day: 'numeric',
  })
  const lastSignIn = user.last_sign_in_at
    ? new Date(user.last_sign_in_at).toLocaleString('ca-ES')
    : '—'
  const initials =
    (user.user_metadata?.full_name as string | undefined)
      ?.split(' ')
      .map((n: string) => n[0])
      .join('')
      .slice(0, 2)
      .toUpperCase() ??
    user.email?.slice(0, 2).toUpperCase() ??
    '??'

  return (
    <div className="max-w-4xl mx-auto px-4 py-10">
      <div className="bg-card rounded-2xl shadow-sm border border-border p-6">
          <div className="flex items-center gap-5 mb-6">
            <AvatarUpload
              user={user}
              initials={initials}
              initialUrl={canonicalAvatarUrl}
              onUrlChange={setDbAvatarUrl}
            />
            <div>
              <p className="text-xl font-semibold text-foreground">
                {(user.user_metadata?.full_name as string | undefined) ?? user.email}
              </p>
              <p className="text-muted-foreground text-sm">{user.email}</p>
            </div>
          </div>

          <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
            <InfoItem label={t('profile.userId', "ID d'usuari")} value={user.id} mono />
            <InfoItem label={t('profile.authProvider', "Proveïdor d'autenticació")} value={provider} />
            <InfoItem label={t('profile.accountCreated', 'Compte creat')} value={createdAt} />
            <InfoItem label={t('profile.lastAccess', 'Últim accés')} value={lastSignIn} />
            <InfoItem
              label={t('profile.emailVerified', 'Correu verificat')}
              value={user.email_confirmed_at
                ? t('profile.emailVerifiedYes', '✓ Verificat')
                : t('profile.emailVerifiedNo', 'Pendent de verificació')}
            />
          </div>

          <ChangePasswordSection user={user} />
        </div>
    </div>
  )
}

