'use client'

import Link from 'next/link'
import { useTranslation } from 'react-i18next'

/**
 * LC-3: superfície d’entrada a l’autoservei PII (EHR-3.4).
 * El flux complet de propostes + PIN queda al pla empleats; aquí només
 * informació Art. 13 + enllaç a la política i contacte RRHH.
 */
export function PortalPersonalDataPage() {
  const { t } = useTranslation('portal')

  return (
    <div className="space-y-5">
      <div>
        <h1 className="text-xl font-semibold tracking-tight">
          {t('employee_portal.personal_data.title', 'Les meves dades personals')}
        </h1>
        <p className="mt-2 text-sm text-muted-foreground">
          {t(
            'employee_portal.personal_data.subtitle',
            'Podeu consultar la política de privacitat dels empleats. La correcció de dades de contacte (email, telèfon, adreça, emergència) es farà mitjançant una proposta revisada per RRHH.',
          )}
        </p>
      </div>

      <div className="rounded-lg border bg-muted/30 p-4 text-sm space-y-2">
        <p className="font-medium">
          {t('employee_portal.personal_data.status_title', 'Estat del servei')}
        </p>
        <p className="text-muted-foreground">
          {t(
            'employee_portal.personal_data.status_body',
            'L’autoservei de propostes de canvi encara no està actiu en aquest entorn. Mentrestant, contacteu amb RRHH o amb l’email de privacitat de la vostra organització.',
          )}
        </p>
      </div>

      <ul className="space-y-2 text-sm">
        <li>
          <Link
            href="/portal/legal/privacy_employees"
            className="text-primary underline-offset-2 hover:underline"
          >
            {t('employee_portal.personal_data.link_privacy', 'Política de privacitat (empleats)')}
          </Link>
        </li>
        <li>
          <Link
            href="/portal/legal/employee_portal_terms"
            className="text-primary underline-offset-2 hover:underline"
          >
            {t('employee_portal.personal_data.link_terms', 'Condicions del portal empleat')}
          </Link>
        </li>
        <li>
          <Link
            href="/portal/security"
            className="text-primary underline-offset-2 hover:underline"
          >
            {t('employee_portal.personal_data.link_security', 'Seguretat (PIN)')}
          </Link>
        </li>
      </ul>
    </div>
  )
}
