import i18n from 'i18next'
import { initReactI18next } from 'react-i18next'

import commonCa from '@/locales/ca/common.json'
import commonEs from '@/locales/es/common.json'
import commonEn from '@/locales/en/common.json'
import readerCa from '@/locales/ca/reader.json'
import readerEs from '@/locales/es/reader.json'
import readerEn from '@/locales/en/reader.json'
import { PLATFORM_FALLBACK_LOCALE } from '@/lib/locale'

void i18n.use(initReactI18next).init({
  resources: {
    ca: { common: commonCa, reader: readerCa },
    es: { common: commonEs, reader: readerEs },
    en: { common: commonEn, reader: readerEn },
  },
  lng: PLATFORM_FALLBACK_LOCALE,
  fallbackLng: PLATFORM_FALLBACK_LOCALE,
  ns: ['common', 'reader'],
  defaultNS: 'common',
  interpolation: { escapeValue: false },
  returnEmptyString: false,
  parseMissingKeyHandler: (_key, defaultValue) =>
    (typeof defaultValue === 'string' ? defaultValue : null) || _key,
})

export default i18n
