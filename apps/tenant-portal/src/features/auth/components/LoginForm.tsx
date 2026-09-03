import { useState } from 'react'
import { useForm } from 'react-hook-form'
import { zodResolver } from '@hookform/resolvers/zod'
import { useNavigate } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { loginSchema, type LoginFormValues } from '../schemas/auth.schema'
import { useSignIn } from '../api/useSignIn'
import { useAuthSettings } from '../api/useAuthSettings'
import { supabase } from '../../../lib/supabase'

type View = 'login' | 'forgot' | 'forgot-otp' | 'forgot-update' | 'magic' | 'magic-sent'

/**
 * Formulari de login + recuperació de contrasenya (flux OTP inline) + magic link.
 *  - login:         email + contrasenya + Google OAuth + acces magic link
 *  - forgot:        email → envia codi OTP i link per correu
 *  - forgot-otp:    codi OTP 6 dígits → supabase.auth.verifyOtp( type: 'recovery' )
 *  - forgot-update: nova contrasenya → supabase.auth.updateUser
 *  - magic:         email → supabase.auth.signInWithOtp → l'usuari fa clic al link
 *  - magic-sent:    pantalla de confirmació (mira el teu correu)
 */
export function LoginForm() {
  const { t } = useTranslation('auth')
  const navigate = useNavigate()
  const [view, setView] = useState<View>('login')

  // Platform-wide auth settings — undefined while loading so we can show a spinner
  // instead of flashing providers that may be hidden by the admin.
  const { data: authSettings, isLoading: authSettingsLoading } = useAuthSettings()

  // ---- forgot state
  const [forgotEmail, setForgotEmail] = useState('')
  const [forgotError, setForgotError] = useState<string | null>(null)
  const [forgotPending, setForgotPending] = useState(false)

  // ---- OTP state
  const [otpCode, setOtpCode] = useState('')
  const [otpError, setOtpError] = useState<string | null>(null)
  const [otpPending, setOtpPending] = useState(false)
  const [resendSent, setResendSent] = useState(false)

  // ---- update password state
  const [newPassword, setNewPassword] = useState('')
  const [confirmPassword, setConfirmPassword] = useState('')
  const [updateError, setUpdateError] = useState<string | null>(null)
  const [updatePending, setUpdatePending] = useState(false)

  // ---- magic link state
  const [magicEmail, setMagicEmail] = useState('')
  const [magicError, setMagicError] = useState<string | null>(null)
  const [magicPending, setMagicPending] = useState(false)

  const {
    register,
    handleSubmit,
    formState: { errors },
  } = useForm<LoginFormValues>({
    resolver: zodResolver(loginSchema),
  })

  const { mutateAsync: signIn, isPending, error: signInError } = useSignIn()

  const onSubmit = async (data: LoginFormValues) => {
    await signIn(data)
  }

  const handleGoogleLogin = async () => {
    await supabase.auth.signInWithOAuth({
      provider: 'google',
      options: { redirectTo: `${window.location.origin}/auth/callback` },
    })
  }

  const sendResetEmail = (email: string) =>
    supabase.auth.resetPasswordForEmail(email, {
      redirectTo: `${window.location.origin}/auth/reset-password`,
    })

  // ---- magic-link: sends a sign-in link (no password needed)
  const handleMagicSubmit = async (e: React.FormEvent) => {
    e.preventDefault()
    setMagicError(null)
    const email = magicEmail.trim()
    if (!email) {
      setMagicError(t('magic.emailRequired', "L'adreça de correu és obligatòria."))
      return
    }
    setMagicPending(true)
    const { error } = await supabase.auth.signInWithOtp({
      email,
      options: {
        // Only allow existing users — do not auto-create accounts
        shouldCreateUser: false,
        emailRedirectTo: `${window.location.origin}/auth/callback`,
      },
    })
    setMagicPending(false)
    if (error) {
      setMagicError(error.message)
      return
    }
    setView('magic-sent')
  }

  // ---- forgot: sends email with OTP + link
  const handleForgotSubmit = async (e: React.FormEvent) => {
    e.preventDefault()
    setForgotError(null)
    const email = forgotEmail.trim()
    if (!email) {
      setForgotError(t('forgot.emailRequired', "L'adreça de correu és obligatòria."))
      return
    }
    setForgotPending(true)
    const { error } = await sendResetEmail(email)
    setForgotPending(false)
    if (error) {
      setForgotError(error.message)
      return
    }
    setView('forgot-otp')
  }

  // ---- forgot-otp: verifies the 6-digit code
  const handleOtpSubmit = async (e: React.FormEvent) => {
    e.preventDefault()
    setOtpError(null)
    const token = otpCode.trim()
    if (!token) {
      setOtpError(t('forgotOtp.otpRequired', 'El codi de verificació és obligatori.'))
      return
    }
    setOtpPending(true)
    const { error } = await supabase.auth.verifyOtp({
      email: forgotEmail,
      token,
      type: 'recovery',
    })
    setOtpPending(false)
    if (error) {
      setOtpError(error.message)
      return
    }
    setView('forgot-update')
  }

  const handleResendCode = async () => {
    setResendSent(false)
    const { error } = await sendResetEmail(forgotEmail)
    if (!error) setResendSent(true)
  }

  // ---- forgot-update: sets the new password
  const handleUpdatePassword = async (e: React.FormEvent) => {
    e.preventDefault()
    setUpdateError(null)
    if (newPassword.length < 8) {
      setUpdateError(t('updatePassword.minLength', 'La contrasenya ha de tenir com a mínim 8 caràcters.'))
      return
    }
    if (newPassword !== confirmPassword) {
      setUpdateError(t('updatePassword.mismatch', 'Les contrasenyes no coincideixen.'))
      return
    }
    setUpdatePending(true)
    const { error } = await supabase.auth.updateUser({ password: newPassword })
    setUpdatePending(false)
    if (error) {
      setUpdateError(error.message)
      return
    }
    navigate('/dashboard', { replace: true })
  }

  // ---- magic-sent view: confirmation after OTP email sent --------------------
  if (view === 'magic-sent') {
    return (
      <div className="bg-card rounded-2xl shadow-xl p-8 text-center space-y-4">
        <div className="inline-flex items-center justify-center w-12 h-12 bg-indigo-50 rounded-full mx-auto">
          <svg className="w-6 h-6 text-indigo-600" fill="none" viewBox="0 0 24 24" stroke="currentColor" aria-hidden="true">
            <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M3 8l7.89 5.26a2 2 0 002.22 0L21 8M5 19h14a2 2 0 002-2V7a2 2 0 00-2-2H5a2 2 0 00-2 2v10a2 2 0 002 2z" />
          </svg>
        </div>
        <h2 className="text-base font-semibold text-foreground">
          {t('magic.sentTitle', 'Comprova el teu correu')}
        </h2>
        <p className="text-sm text-muted-foreground">
          {t('magic.sentDescription', "Hem enviat un link d'accés a {{email}}. Fes clic al link per entrar directament.", { email: magicEmail })}
        </p>
        <button
          type="button"
          onClick={() => { setView('magic'); setMagicError(null) }}
          className="text-sm text-muted-foreground hover:text-foreground"
        >
          {t('magic.back', '← Tornar')}
        </button>
      </div>
    )
  }

  // ---- magic view: email input to request a sign-in link --------------------
  if (view === 'magic') {
    return (
      <div className="bg-card rounded-2xl shadow-xl p-8">
        <h2 className="text-base font-semibold text-foreground mb-1">
          {t('magic.title', 'Accés sense contrasenya')}
        </h2>
        <p className="text-sm text-muted-foreground mb-5">
          {t('magic.description', "Introdueix el teu correu i t'enviarem un link per entrar directament.")}
        </p>
        <form onSubmit={handleMagicSubmit} noValidate className="space-y-4">
          <div>
            <label htmlFor="magic-email" className="block text-sm font-medium text-foreground mb-1">
              {t('magic.emailLabel', 'Correu electrònic')}
            </label>
            <input
              id="magic-email"
              type="email"
              autoComplete="email"
              value={magicEmail}
              onChange={(e) => setMagicEmail(e.target.value)}
              placeholder={t('magic.emailPlaceholder', 'tu@empresa.com')}
              className="w-full px-4 py-2.5 border border-input rounded-lg focus:ring-2 focus:ring-primary focus:border-transparent outline-none transition bg-background text-foreground"
            />
          </div>
          {magicError && (
            <div role="alert" className="bg-red-50 border border-red-200 text-red-700 px-4 py-3 rounded-lg text-sm dark:bg-red-950/50 dark:border-red-800 dark:text-red-400">
              {magicError}
            </div>
          )}
          <button
            type="submit"
            disabled={magicPending}
            className="w-full bg-indigo-600 hover:bg-indigo-700 disabled:opacity-50 text-white font-semibold py-2.5 rounded-lg transition"
          >
            {magicPending
              ? t('magic.submitting', 'Enviant...')
              : t('magic.submit', 'Enviar link d\'accés')}
          </button>
        </form>
        <button
          type="button"
          onClick={() => { setView('login'); setMagicError(null) }}
          className="mt-4 w-full text-sm text-muted-foreground hover:text-foreground text-center"
        >
          {t('magic.backToLogin', '← Tornar al login')}
        </button>
      </div>
    )
  }

  // ---- forgot-update view: new password form after OTP verified --------------
  if (view === 'forgot-update') {
    return (
      <div className="bg-card rounded-2xl shadow-xl p-8">
        <div className="text-center mb-6">
          <div className="inline-flex items-center justify-center w-12 h-12 bg-green-50 rounded-full mb-3">
            <svg className="w-6 h-6 text-green-600" fill="none" viewBox="0 0 24 24" stroke="currentColor" aria-hidden="true">
              <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M5 13l4 4L19 7" />
            </svg>
          </div>
          <h2 className="text-base font-semibold text-foreground">
            {t('updatePassword.title', 'Crea la nova contrasenya')}
          </h2>
        </div>
        <form onSubmit={handleUpdatePassword} noValidate className="space-y-4">
          <div>
            <label htmlFor="new-password" className="block text-sm font-medium text-foreground mb-1">
              {t('updatePassword.newPasswordLabel', 'Nova contrasenya')}
            </label>
            <input
              id="new-password"
              type="password"
              autoComplete="new-password"
              value={newPassword}
              onChange={(e) => setNewPassword(e.target.value)}
              placeholder={t('updatePassword.newPasswordPlaceholder', 'Mínim 8 caràcters')}
              className="w-full px-4 py-2.5 border border-input rounded-lg focus:ring-2 focus:ring-primary focus:border-transparent outline-none transition bg-background text-foreground"
            />
          </div>
          <div>
            <label htmlFor="confirm-password" className="block text-sm font-medium text-foreground mb-1">
              {t('updatePassword.confirmPasswordLabel', 'Confirmar contrasenya')}
            </label>
            <input
              id="confirm-password"
              type="password"
              autoComplete="new-password"
              value={confirmPassword}
              onChange={(e) => setConfirmPassword(e.target.value)}
              placeholder={t('updatePassword.confirmPasswordPlaceholder', 'Repeteix la contrasenya')}
              className="w-full px-4 py-2.5 border border-input rounded-lg focus:ring-2 focus:ring-primary focus:border-transparent outline-none transition bg-background text-foreground"
            />
          </div>
          {updateError && (
            <div role="alert" className="bg-red-50 border border-red-200 text-red-700 px-4 py-3 rounded-lg text-sm dark:bg-red-950/50 dark:border-red-800 dark:text-red-400">
              {updateError}
            </div>
          )}
          <button
            type="submit"
            disabled={updatePending || !newPassword || !confirmPassword}
            className="w-full bg-indigo-600 hover:bg-indigo-700 disabled:opacity-50 text-white font-semibold py-2.5 rounded-lg transition"
          >
            {updatePending
              ? t('updatePassword.submitting', 'Desant...')
              : t('updatePassword.submit', 'Desar contrasenya')}
          </button>
        </form>
      </div>
    )
  }

  // ---- forgot-otp view: OTP code input ---------------------------------------
  if (view === 'forgot-otp') {
    return (
      <div className="bg-card rounded-2xl shadow-xl p-8">
        <h2 className="text-base font-semibold text-foreground mb-1">
          {t('forgotOtp.title', 'Comprova el teu correu')}
        </h2>
        <p className="text-sm text-muted-foreground mb-5">
          {t('forgotOtp.description', "Hem enviat un codi de 6 dígits a {{email}}. Introdueix-lo aquí o fes clic a l'enllaç del correu.", { email: forgotEmail })}
        </p>
        <form onSubmit={handleOtpSubmit} noValidate className="space-y-4">
          <div>
            <label htmlFor="otp-code" className="block text-sm font-medium text-foreground mb-1">
              {t('forgotOtp.otpLabel', 'Codi de verificació (6 dígits)')}
            </label>
            <input
              id="otp-code"
              type="text"
              inputMode="numeric"
              maxLength={6}
              autoComplete="one-time-code"
              value={otpCode}
              onChange={(e) => setOtpCode(e.target.value.replace(/\D/g, '').slice(0, 6))}
              placeholder={t('forgotOtp.otpPlaceholder', '000000')}
              className="w-full px-4 py-2.5 border border-input rounded-lg focus:ring-2 focus:ring-primary focus:border-transparent outline-none transition bg-background text-foreground text-center tracking-widest text-lg font-mono"
            />
          </div>
          {otpError && (
            <div role="alert" className="bg-red-50 border border-red-200 text-red-700 px-4 py-3 rounded-lg text-sm dark:bg-red-950/50 dark:border-red-800 dark:text-red-400">
              {otpError}
            </div>
          )}
          <button
            type="submit"
            disabled={otpPending || otpCode.length < 6}
            className="w-full bg-indigo-600 hover:bg-indigo-700 disabled:opacity-50 text-white font-semibold py-2.5 rounded-lg transition"
          >
            {otpPending
              ? t('forgotOtp.submitting', 'Verificant...')
              : t('forgotOtp.submit', 'Verificar codi')}
          </button>
        </form>
        <div className="mt-4 space-y-2 text-center">
          <button
            type="button"
            onClick={handleResendCode}
            className="text-sm text-indigo-600 hover:underline"
          >
            {resendSent
              ? t('forgotOtp.resendSent', 'Codi reenviat ✓')
              : t('forgotOtp.resend', 'Tornar a enviar el codi')}
          </button>
          <br />
          <button
            type="button"
            onClick={() => { setView('forgot'); setOtpCode(''); setOtpError(null) }}
            className="text-sm text-muted-foreground hover:text-foreground"
          >
            {t('forgotOtp.back', '← Canviar correu')}
          </button>
        </div>
      </div>
    )
  }

  // ---- forgot view: email input form -----------------------------------------
  if (view === 'forgot') {
    return (
      <div className="bg-card rounded-2xl shadow-xl p-8">
        <h2 className="text-base font-semibold text-foreground mb-1">
          {t('forgot.title', 'Has oblidat la contrasenya?')}
        </h2>
        <p className="text-sm text-muted-foreground mb-5">
          {t('forgot.description', "Introdueix el teu correu i t'enviarem un codi de verificació de 6 dígits.")}
        </p>
        <form onSubmit={handleForgotSubmit} noValidate className="space-y-4">
          <div>
            <label htmlFor="forgot-email" className="block text-sm font-medium text-foreground mb-1">
              {t('forgot.emailLabel', 'Correu electrònic')}
            </label>
            <input
              id="forgot-email"
              type="email"
              autoComplete="email"
              value={forgotEmail}
              onChange={(e) => setForgotEmail(e.target.value)}
              placeholder={t('forgot.emailPlaceholder', 'tu@empresa.com')}
              className="w-full px-4 py-2.5 border border-input rounded-lg focus:ring-2 focus:ring-primary focus:border-transparent outline-none transition bg-background text-foreground"
            />
          </div>
          {forgotError && (
            <div role="alert" className="bg-red-50 border border-red-200 text-red-700 px-4 py-3 rounded-lg text-sm dark:bg-red-950/50 dark:border-red-800 dark:text-red-400">
              {forgotError}
            </div>
          )}
          <button
            type="submit"
            disabled={forgotPending}
            className="w-full bg-indigo-600 hover:bg-indigo-700 disabled:opacity-50 text-white font-semibold py-2.5 rounded-lg transition"
          >
            {forgotPending
              ? t('forgot.submitting', 'Enviant...')
              : t('forgot.submit', 'Enviar codi')}
          </button>
        </form>
        <button
          type="button"
          onClick={() => { setView('login'); setForgotError(null) }}
          className="mt-4 w-full text-sm text-muted-foreground hover:text-foreground text-center"
        >
          {t('forgot.back', '← Tornar al login')}
        </button>
      </div>
    )
  }

  // ---- login view ------------------------------------------------------------
  // Show a spinner while auth settings load to avoid flashing providers that
  // the admin may have disabled. staleTime=5min means this only shows on the
  // very first page load per session.
  if (authSettingsLoading) {
    return (
      <div className="bg-card rounded-2xl shadow-xl p-8 flex items-center justify-center min-h-55">
        <div className="w-6 h-6 border-2 border-border border-t-primary rounded-full animate-spin" aria-label="Carregant..." />
      </div>
    )
  }

  const showPasswordForm = authSettings?.password_login_enabled !== false
  const showSocial = !!(authSettings?.google_oauth_enabled || authSettings?.magic_link_enabled)

  return (
    <div className="bg-card rounded-2xl shadow-xl p-8">
      {showPasswordForm && (
        <form onSubmit={handleSubmit(onSubmit)} noValidate className="space-y-5">
          <div>
            <label htmlFor="email" className="block text-sm font-medium text-foreground mb-1">
              {t('login.emailLabel', 'Correu electrònic')}
            </label>
            <input
              id="email"
              type="email"
              autoComplete="email"
              {...register('email')}
              className="w-full px-4 py-2.5 border border-input rounded-lg focus:ring-2 focus:ring-primary focus:border-transparent outline-none transition bg-background text-foreground aria-[invalid]:border-red-400"
              placeholder={t('login.emailPlaceholder', 'tu@empresa.com')}
              {...(errors.email ? { 'aria-invalid': 'true' } : {})}
            />
            {errors.email && (
              <p role="alert" className="mt-1 text-xs text-red-600">
                {errors.email.message}
              </p>
            )}
          </div>

          <div>
            <div className="flex items-center justify-between mb-1">
              <label htmlFor="password" className="block text-sm font-medium text-foreground">
                {t('login.passwordLabel', 'Contrasenya')}
              </label>
              <button
                type="button"
                onClick={() => setView('forgot')}
                className="text-xs text-indigo-600 hover:underline"
              >
                {t('login.forgotLink', 'Has oblidat la contrasenya?')}
              </button>
            </div>
            <input
              id="password"
              type="password"
              autoComplete="current-password"
              {...register('password')}
              className="w-full px-4 py-2.5 border border-input rounded-lg focus:ring-2 focus:ring-primary focus:border-transparent outline-none transition bg-background text-foreground aria-[invalid]:border-red-400"
              placeholder={t('login.passwordPlaceholder', '••••••••')}
              {...(errors.password ? { 'aria-invalid': 'true' } : {})}
            />
            {errors.password && (
              <p role="alert" className="mt-1 text-xs text-red-600">
                {errors.password.message}
              </p>
            )}
          </div>

          {signInError && (
            <div role="alert" className="bg-red-50 border border-red-200 text-red-700 px-4 py-3 rounded-lg text-sm dark:bg-red-950/50 dark:border-red-800 dark:text-red-400">
              {signInError.message}
            </div>
          )}

          <button
            type="submit"
            disabled={isPending}
            className="w-full bg-indigo-600 hover:bg-indigo-700 disabled:opacity-50 text-white font-semibold py-2.5 rounded-lg transition"
          >
            {isPending ? t('login.submitting', 'Accedint...') : t('login.submit', 'Iniciar sessió')}
          </button>
        </form>
      )}

      {showSocial && (
        <>
          {showPasswordForm && (
            <div className="relative my-6">
              <div className="absolute inset-0 flex items-center">
                <div className="w-full border-t border-border" />
              </div>
              <div className="relative flex justify-center text-sm">
                <span className="bg-card px-3 text-muted-foreground">{t('login.or', 'o continua amb')}</span>
              </div>
            </div>
          )}

          {authSettings?.google_oauth_enabled && (
            <button
              type="button"
              onClick={handleGoogleLogin}
              disabled={isPending}
              className="w-full flex items-center justify-center gap-3 border border-border hover:bg-accent disabled:opacity-50 text-foreground font-semibold py-2.5 rounded-lg transition"
            >
              <GoogleIcon />
              {t('login.googleButton', 'Continuar amb Google')}
            </button>
          )}

          {authSettings?.magic_link_enabled && (
            <button
              type="button"
              onClick={() => { setMagicEmail(''); setMagicError(null); setView('magic') }}
              className="mt-4 w-full text-sm text-indigo-600 hover:underline text-center"
            >
              {t('login.magicLinkButton', 'Accedir sense contrasenya →')}
            </button>
          )}
        </>
      )}
    </div>
  )
}

function GoogleIcon() {
  return (
    <svg className="w-5 h-5" viewBox="0 0 24 24" aria-hidden="true">
      <path fill="#4285F4" d="M22.56 12.25c0-.78-.07-1.53-.2-2.25H12v4.26h5.92c-.26 1.37-1.04 2.53-2.21 3.31v2.77h3.57c2.08-1.92 3.28-4.74 3.28-8.09z" />
      <path fill="#34A853" d="M12 23c2.97 0 5.46-.98 7.28-2.66l-3.57-2.77c-.98.66-2.23 1.06-3.71 1.06-2.86 0-5.29-1.93-6.16-4.53H2.18v2.84C3.99 20.53 7.7 23 12 23z" />
      <path fill="#FBBC05" d="M5.84 14.09c-.22-.66-.35-1.36-.35-2.09s.13-1.43.35-2.09V7.07H2.18C1.43 8.55 1 10.22 1 12s.43 3.45 1.18 4.93l2.85-2.22.81-.62z" />
      <path fill="#EA4335" d="M12 5.38c1.62 0 3.06.56 4.21 1.64l3.15-3.15C17.45 2.09 14.97 1 12 1 7.7 1 3.99 3.47 2.18 7.07l3.66 2.84c.87-2.6 3.3-4.53 6.16-4.53z" />
    </svg>
  )
}

