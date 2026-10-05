import type { ReactNode } from 'react'
import { Outlet, useLocation } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import {
  Archive,
  FileSignature,
  FileStack,
  FileText,
  HardDrive,
} from 'lucide-react'
import { PageShell } from '@/components/layout/PageShell'
import { useSectorLabel } from '@/hooks/useSectorLabel'
import { DocumentsSubNav } from './DocumentsSubNav'

type DocumentsSection = {
  title: string
  subtitle: string
  icon: ReactNode
}

function useDocumentsSection(): DocumentsSection {
  const { t } = useTranslation(['documents', 'signing'])
  const { pathname } = useLocation()
  const projectLabel = useSectorLabel('project', t('documents:storage.project_fallback', 'Projecte'))

  if (pathname.startsWith('/documents/signing')) {
    return {
      title: t('signing:center.title', 'Centre de signatures'),
      subtitle: t(
        'signing:center.subtitle',
        'Seguiment de totes les sol·licituds de signatura',
      ),
      icon: <FileSignature className="h-5 w-5" aria-hidden />,
    }
  }
  if (pathname.startsWith('/documents/templates')) {
    return {
      title: t('signing:page.title', 'Plantilles de documents'),
      subtitle: t(
        'documents:page.templates_subtitle',
        'Plantilles per generar i firmar documents',
      ),
      icon: <FileStack className="h-5 w-5" aria-hidden />,
    }
  }
  if (pathname.startsWith('/documents/archived')) {
    return {
      title: t('documents:archived.title', 'Arxivats'),
      subtitle: t(
        'documents:archived.subtitle',
        'Documents arxivats que ja no surten a l’explorador',
      ),
      icon: <Archive className="h-5 w-5" aria-hidden />,
    }
  }
  if (pathname.startsWith('/documents/storage')) {
    return {
      title: t('documents:storage.title', 'Emmagatzematge'),
      subtitle: t(
        'documents:storage.hint',
        "Ús de Documents (DMS) vs Fitxers (Drive). Els arxius de {{project}} van a Fitxers.",
        { project: projectLabel },
      ),
      icon: <HardDrive className="h-5 w-5" aria-hidden />,
    }
  }
  return {
    title: t('documents:page.title', 'Documents'),
    subtitle: t('documents:page.subtitle', 'Explorador de documents'),
    icon: <FileText className="h-5 w-5" aria-hidden />,
  }
}

function isDocumentsDetail(pathname: string): boolean {
  if (/^\/documents\/templates\/[^/]+/.test(pathname)) return true
  if (/^\/documents\/signing\/[^/]+/.test(pathname)) return true
  if (!/^\/documents\/[^/]+$/.test(pathname)) return false
  const segment = pathname.split('/')[2]
  return !['archived', 'storage', 'templates', 'signing'].includes(segment ?? '')
}

export function DocumentsLayout() {
  const location = useLocation()
  const section = useDocumentsSection()

  if (isDocumentsDetail(location.pathname)) {
    return <Outlet />
  }

  return (
    <PageShell
      title={section.title}
      subtitle={section.subtitle}
      icon={section.icon}
      tabs={<DocumentsSubNav />}
    >
      <Outlet />
    </PageShell>
  )
}
