import i18n from 'i18next'
import { initReactI18next } from 'react-i18next'

import commonCa from '@/locales/ca/common.json'
import authCa from '@/locales/ca/auth.json'
import dashboardCa from '@/locales/ca/dashboard.json'
import tenantsCa from '@/locales/ca/tenants.json'
import settingsCa from '@/locales/ca/settings.json'
import storageCa from '@/locales/ca/storage.json'
import monetitzacioCa from '@/locales/ca/monetitzacio.json'
import emailLogsCa from '@/locales/ca/email_logs.json'
import activityCa from '@/locales/ca/activity.json'

i18n.use(initReactI18next).init({
  resources: {
    ca: {
      common: commonCa,
      auth: authCa,
      dashboard: dashboardCa,
      tenants: tenantsCa,
      settings: settingsCa,
      storage: storageCa,
      monetitzacio: monetitzacioCa,
      email_logs: emailLogsCa,
      activity: activityCa,
    },
  },
  lng: 'ca',
  fallbackLng: 'ca',
  ns: ['common', 'auth', 'dashboard', 'tenants', 'settings', 'storage', 'monetitzacio', 'email_logs', 'activity'],
  defaultNS: 'common',
  interpolation: { escapeValue: false },
  returnEmptyString: false,
  parseMissingKeyHandler: (_key, defaultValue) => defaultValue || _key,
})

export default i18n
