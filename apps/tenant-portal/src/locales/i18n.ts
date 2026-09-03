import i18n from 'i18next';
import { initReactI18next } from 'react-i18next';

// Importem els JSON (els crearem ara)
import storageCa from './ca/storage.json';
import commonCa from './ca/common.json';
import authCa from './ca/auth.json';
import emailCa from './ca/email.json';
import calendarCa from './ca/calendar.json';
import contactsCa from './ca/contacts.json';
import contactsEs from './es/contacts.json';
import contactsEn from './en/contacts.json';
import catalogCa from './ca/catalog.json';
import projectsCa from './ca/projects.json';
import onboardingCa from './ca/onboarding.json';
import departmentsCa from './ca/departments.json';
import locationsCa from './ca/locations.json';
import employeesCa from './ca/employees.json';
import employeesEs from './es/employees.json';
import employeesEn from './en/employees.json';
import recruitmentCa from './ca/recruitment.json';
import recruitmentEs from './es/recruitment.json';
import recruitmentEn from './en/recruitment.json';
import fieldServiceCa from './ca/field-service.json';
import fieldServiceEs from './es/field-service.json';
import fieldServiceEn from './en/field-service.json';
import documentsCa from './ca/documents.json';
import settingsCa from './ca/settings.json';
import settingsEs from './es/settings.json';
import settingsEn from './en/settings.json';
import publicPortalCa from './ca/public-portal.json';
import tenantContentCa from './ca/tenant-content.json';
import attendanceCa from './ca/attendance.json';
import signingCa from './ca/signing.json';
import chatCa from './ca/chat.json';
import activityCa from './ca/activity.json';
import mapsCa from './ca/maps.json';
import mapsEs from './es/maps.json';
import mapsEn from './en/maps.json';

i18n
  .use(initReactI18next)
  .init({
    resources: {
      ca: {
        storage: storageCa,
        common: commonCa,
        auth: authCa,
        email: emailCa,
        calendar: calendarCa,
        contacts: contactsCa,
        catalog: catalogCa,
        projects: projectsCa,
        onboarding: onboardingCa,
        departments: departmentsCa,
        locations: locationsCa,
        employees: employeesCa,
        recruitment: recruitmentCa,
        'field-service': fieldServiceCa,
        documents: documentsCa,
        settings: settingsCa,
        'public-portal': publicPortalCa,
        'tenant-content': tenantContentCa,
        // attendance.json arrel: { attendance: { ... } } — el namespace ha de ser l'objecte interior
        attendance: attendanceCa.attendance,
        signing: signingCa,
        chat: chatCa,
        activity: activityCa,
        maps: mapsCa,
      },
      es: {
        contacts: contactsEs,
        employees: employeesEs,
        recruitment: recruitmentEs,
        'field-service': fieldServiceEs,
        maps: mapsEs,
        settings: settingsEs,
      },
      en: {
        contacts: contactsEn,
        employees: employeesEn,
        recruitment: recruitmentEn,
        'field-service': fieldServiceEn,
        maps: mapsEn,
        settings: settingsEn,
      },
    },
    lng: 'ca',
    fallbackLng: {
      es: ['ca'],
      en: ['ca'],
      default: ['ca'],
    },
    ns: ['common', 'storage', 'auth', 'email', 'calendar', 'contacts', 'catalog', 'projects', 'departments', 'locations', 'employees', 'recruitment', 'field-service', 'documents', 'settings', 'public-portal', 'tenant-content', 'attendance', 'signing', 'chat', 'activity', 'maps'],
    defaultNS: 'common',
    interpolation: {
      escapeValue: false, // React ja protegeix contra XSS
    },
    // Aquesta opció permet que t('clau', 'Text') funcioni correctament
    returnEmptyString: false,
    parseMissingKeyHandler: (key, defaultValue) => {
      // Si la clau no existeix, retorna el text per defecte que hem posat al component
      return defaultValue || key;
    },
  });

export default i18n;