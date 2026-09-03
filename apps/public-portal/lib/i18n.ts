import i18n from 'i18next'
import { initReactI18next } from 'react-i18next'

import portalCa from '@/locales/ca/portal.json'
import portalEs from '@/locales/es/portal.json'
import portalEn from '@/locales/en/portal.json'
import { PLATFORM_FALLBACK_LOCALE } from '@/lib/locales'

i18n.use(initReactI18next).init({
  resources: {
    ca: { portal: portalCa.portal },
    es: { portal: portalEs.portal },
    en: { portal: portalEn.portal },
  },
  lng: PLATFORM_FALLBACK_LOCALE,
  fallbackLng: PLATFORM_FALLBACK_LOCALE,
  ns: ['portal'],
  defaultNS: 'portal',
  interpolation: { escapeValue: false },
  returnEmptyString: false,
  parseMissingKeyHandler: (_key, defaultValue) => defaultValue || _key,
})

export default i18n
