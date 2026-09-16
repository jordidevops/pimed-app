type Translate = (key: string, fallback: string) => string

interface AuthErrorCopy {
  key: string
  fallback: string
}

const BY_CODE: Record<string, AuthErrorCopy> = {
  invalid_credentials: {
    key: 'errors.invalid_credentials',
    fallback: 'Correu o contrasenya incorrectes.',
  },
  email_not_confirmed: {
    key: 'errors.email_not_confirmed',
    fallback: 'Cal confirmar el correu abans d’entrar.',
  },
  user_not_found: {
    key: 'errors.invalid_credentials',
    fallback: 'Correu o contrasenya incorrectes.',
  },
  user_banned: {
    key: 'errors.user_banned',
    fallback: 'Aquest compte està desactivat. Contacta amb l’administrador.',
  },
  otp_expired: {
    key: 'errors.otp_expired',
    fallback: 'El codi o l’enllaç ha caducat. Torna a demanar-lo.',
  },
  otp_disabled: {
    key: 'errors.otp_disabled',
    fallback: 'Aquest mètode d’accés no està disponible.',
  },
  over_request_rate_limit: {
    key: 'errors.rate_limit',
    fallback: 'Massa intents. Espera uns segons i torna-ho a provar.',
  },
  over_email_send_rate_limit: {
    key: 'errors.email_rate_limit',
    fallback: 'S’han enviat massa correus. Espera uns minuts i torna-ho a provar.',
  },
  validation_failed: {
    key: 'errors.validation_failed',
    fallback: 'Les dades no són vàlides. Revisa el correu i torna-ho a provar.',
  },
  weak_password: {
    key: 'errors.weak_password',
    fallback: 'La contrasenya no és prou segura. Tria’n una de més llarga.',
  },
  same_password: {
    key: 'errors.same_password',
    fallback: 'La nova contrasenya ha de ser diferent de l’actual.',
  },
  reauthentication_needed: {
    key: 'errors.reauthentication_needed',
    fallback: 'Torna a identificar-te per canviar la contrasenya.',
  },
  session_not_found: {
    key: 'errors.session_expired',
    fallback: 'La sessió ha caducat. Torna a iniciar sessió.',
  },
  refresh_token_not_found: {
    key: 'errors.session_expired',
    fallback: 'La sessió ha caducat. Torna a iniciar sessió.',
  },
  signup_disabled: {
    key: 'errors.signup_disabled',
    fallback: 'El registre no està habilitat.',
  },
  email_exists: {
    key: 'errors.email_exists',
    fallback: 'Aquest correu ja té un compte.',
  },
  email_address_invalid: {
    key: 'errors.email_invalid',
    fallback: 'L’adreça de correu no és vàlida.',
  },
  provider_disabled: {
    key: 'errors.provider_disabled',
    fallback: 'Aquest mètode d’accés no està habilitat.',
  },
  unexpected_failure: {
    key: 'errors.generic',
    fallback: 'No s’ha pogut completar l’acció. Torna-ho a intentar.',
  },
}

const BY_MESSAGE: Record<string, AuthErrorCopy> = {
  'invalid login credentials': BY_CODE.invalid_credentials,
  'email not confirmed': BY_CODE.email_not_confirmed,
  'user not found': BY_CODE.invalid_credentials,
  'token has expired or is invalid': BY_CODE.otp_expired,
  'email rate limit exceeded': BY_CODE.over_email_send_rate_limit,
  'signups not allowed for this instance': BY_CODE.signup_disabled,
  'new password should be different from the old password': BY_CODE.same_password,
  'email link is invalid or has expired': {
    key: 'errors.email_link_invalid',
    fallback: 'L’enllaç no és vàlid o ha caducat. Torna a demanar-lo.',
  },
  'access_denied': {
    key: 'errors.email_link_invalid',
    fallback: 'L’enllaç no és vàlid o ha caducat. Torna a demanar-lo.',
  },
  unauthorized_client: {
    key: 'errors.email_link_invalid',
    fallback: 'L’enllaç no és vàlid o ha caducat. Torna a demanar-lo.',
  },
}

const BY_MESSAGE_INCLUDES: Array<{ needle: string; copy: AuthErrorCopy }> = [
  {
    needle: 'for security purposes, you can only request this after',
    copy: BY_CODE.over_request_rate_limit,
  },
  {
    needle: 'email link is invalid or has expired',
    copy: BY_MESSAGE['email link is invalid or has expired'],
  },
  {
    needle: 'password should be at least',
    copy: BY_CODE.weak_password,
  },
  {
    needle: 'unable to validate email address',
    copy: BY_CODE.email_address_invalid,
  },
]

function normalizeMessage(value: string): string {
  return value.trim().replace(/\+/g, ' ').replace(/\s+/g, ' ').toLowerCase()
}

function lookupCopy(code: string | undefined, message: string): AuthErrorCopy | undefined {
  if (code) {
    const fromCode = BY_CODE[code.toLowerCase()]
    if (fromCode) return fromCode
  }

  const normalized = normalizeMessage(message)
  if (!normalized) return undefined

  const exact = BY_MESSAGE[normalized]
  if (exact) return exact

  return BY_MESSAGE_INCLUDES.find(({ needle }) => normalized.includes(needle))?.copy
}

/** Maps GoTrue / supabase-js auth errors (and hash error strings) to Catalan copy. */
export function translateAuthError(error: unknown, t: Translate): string {
  if (typeof error === 'string') {
    const copy = lookupCopy(undefined, error)
    return copy
      ? t(copy.key, copy.fallback)
      : t('errors.generic', 'No s’ha pogut completar l’acció. Torna-ho a intentar.')
  }

  const err = error as { code?: string; message?: string } | null
  const copy = lookupCopy(err?.code, err?.message ?? '')
  return copy
    ? t(copy.key, copy.fallback)
    : t('errors.generic', 'No s’ha pogut completar l’acció. Torna-ho a intentar.')
}
