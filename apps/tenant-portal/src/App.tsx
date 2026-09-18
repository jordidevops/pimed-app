import { QueryClientProvider } from '@tanstack/react-query'
import { useEffect } from 'react'
import { Routes, Route, Navigate, useNavigate } from 'react-router-dom'
import { Analytics } from '@vercel/analytics/react'
import { SpeedInsights } from '@vercel/speed-insights/react'
import { queryClient } from './lib/react-query'
import { AuthProvider } from './contexts/AuthContext'
import { TenantProvider } from './contexts/TenantContext'
import { ThemeProvider } from './contexts/ThemeContext'
import { ProtectedRoute } from './components/ProtectedRoute'
import { InternalMemberGate } from './components/InternalMemberGate'
import { AppLayout } from './components/AppLayout'
import { LoginPage } from './pages/LoginPage'
import { PublicSignPage } from './pages/PublicSignPage'
import { DashboardPage } from './pages/DashboardPage'
import { ProfilePage } from './pages/ProfilePage'
import { SettingsPage } from './pages/SettingsPage'
import { ConfigPage } from './pages/settings/ConfigPage'
import { MembersPage } from './pages/settings/MembersPage'
import { SitesPage } from './pages/settings/SitesPage'
import { StoragePage } from './pages/settings/StoragePage'
import { EmailPage } from './pages/settings/EmailPage'
import { PermissionsPage } from './pages/settings/PermissionsPage'
import { SigningPage } from './pages/settings/SigningPage'
import { AiPage } from './pages/settings/AiPage'
import { MapsSettingsPage } from './pages/settings/MapsSettingsPage'
import { AttendanceControlPage } from './pages/settings/AttendanceControlPage'
import { AttendanceStationsPage } from './features/attendance-stations/pages/AttendanceStationsPage'
import { TemplatesPage as SettingsTemplatesPage } from './pages/settings/TemplatesPage'
import { OperationsPage } from './pages/settings/OperationsPage'
import { CustomerPortalSettingsPage } from './pages/settings/CustomerPortalSettingsPage'
import { LegalSettingsPage } from './pages/settings/LegalSettingsPage'
import { NotificationsPage } from './pages/settings/NotificationsPage'
import { WebhooksPage } from './pages/settings/WebhooksPage'
import { SecretsPage } from './pages/settings/SecretsPage'
import { PlaybooksPage } from './pages/settings/PlaybooksPage'
import { RiskDetectorPage } from './pages/settings/RiskDetectorPage'
import { ActivitySettingsLayout } from './pages/settings/ActivitySettingsLayout'
import { CommentTemplatesSettingsPage } from './pages/settings/CommentTemplatesSettingsPage'
import { FilesPage } from './pages/FilesPage'
import { AuthCallbackPage } from './pages/AuthCallbackPage'
import { ResetPasswordPage } from './pages/ResetPasswordPage'
import { OnboardingPage } from './pages/OnboardingPage'
import { ContactsPage } from './features/contacts/components/ContactsPage'
import { ContactDetailPage } from './features/contacts/components/ContactDetailPage'
import { CatalogPage } from './features/catalog/components/CatalogPage'
import { DepartmentsPage } from './features/departments'
import { LocationsPage } from './features/locations'
import { EmployeesPage, EmployeeDetailPage, JobPositionsPage, OrganizationChartPage } from './features/employees'
import { HrDashboardPage } from './features/hr-reporting'
import {
  RecruitmentLayout,
  ApplicationsPage,
  JobPostingsPage,
  JobPostingDetailPage,
  RecruitmentSettingsPage,
  RightsInboxPage,
  RecruitmentAnalyticsPage,
  RecruitmentInboundInboxPage,
} from './features/recruitment'
import { SkillCatalogPage } from './features/employee-skills'
import { DocumentsPage, ArchivedDocumentsPage, DocumentDetailPage, DocumentsStoragePage } from './features/documents'
import { TemplatesPage, TemplateDetailPage, SigningCenterPage, SigningSubmissionDetail } from './features/signing'
import { ProjectsPage, ProjectDetailPage } from './features/projects'
import { QuotesPage } from './features/commercial/components/QuotesPage'
import {
  FieldServiceLayout,
  TodayPage,
  FieldOrdersPage,
  FieldAgendaPage,
  FieldMorePage,
  ChecklistTemplatesPage,
  ChecklistPointsPage,
  ChecklistResponseSetsPage,
  MaintenancePlansPage,
  BulletinStandalonePreviewPage,
} from './features/field-service'
import { PublicPortalPage } from './features/public-portal'
import {
  EmployeeContentListPage,
  EmployeeContentEditorPage,
  PublicContentEditorPage,
} from './features/tenant-content'
import { AttendanceLayout, PunchPage, MyRecordPage, CalendarPage, AbsencesPage, PersonalAbsencesPage, ShiftsPage, ControlHorariLayout, LegacyControlHorariRedirect, TaulerPage, FitxatgesPage, PlanificacioPage, PlanningLayout, SchedulePlannerPage, ShiftOpeningsPage, ShiftSwapsPage } from './features/attendance'
import { ATTENDANCE_MGMT_BASE } from './features/attendance/attendanceMgmtRoutes'
import { ChatPage } from './features/ai-chat/pages/ChatPage'
import { ChatSharedPage } from './features/ai-chat/pages/ChatSharedPage'
import { AutomationPage } from './pages/AutomationPage'
import { AppIndexPage } from './pages/AppIndexPage'
import { SidebarEditorPage } from './pages/SidebarEditorPage'
import { Toaster } from './components/ui/toaster'
import { TooltipProvider } from './components/ui/tooltip'
import { SentryScopeSync } from './lib/observability'
import { FieldSyncCoordinator } from './features/field-service/components/FieldSyncCoordinator'
import { AttendanceSyncCoordinator } from './features/attendance/hooks/useAttendanceSync'

/**
 * Handles the root path. If Supabase redirects an auth error to the site root
 * (e.g. expired password-reset OTP → /#error=access_denied&...), forwards it to
 * /auth/callback which already shows the error card. Otherwise goes to /dashboard.
 */
function RootRedirect() {
  const navigate = useNavigate()
  useEffect(() => {
    const hash = window.location.hash.substring(1)
    const params = new URLSearchParams(hash)
    if (params.get('error')) {
      // Supabase sends expired/invalid OTP errors to site root → forward to error card
      navigate('/auth/callback' + window.location.hash, { replace: true })
    } else if (params.get('type') === 'recovery') {
      // Supabase sends valid password-reset tokens to site root when redirectTo is
      // not in additional_redirect_urls. Forward to the reset-password page so
      // the PASSWORD_RECOVERY event is fired there.
      navigate('/auth/reset-password' + window.location.hash, { replace: true })
    } else {
      navigate('/dashboard', { replace: true })
    }
  }, [navigate])
  return null
}

export default function App() {
  return (
    <div className="h-full min-h-0 overflow-hidden">
    <ThemeProvider>
    <TooltipProvider delayDuration={250} skipDelayDuration={0}>
    <QueryClientProvider client={queryClient}>
    <AuthProvider>
    <TenantProvider>
      <AttendanceSyncCoordinator>
      <SentryScopeSync />
      <FieldSyncCoordinator />
      <Routes>
        {/* Public routes */}
        <Route path="/login" element={<LoginPage />} />
        <Route path="/auth/callback" element={<AuthCallbackPage />} />
        <Route path="/auth/reset-password" element={<ResetPasswordPage />} />
        <Route path="/sign/:token" element={<PublicSignPage />} />

        {/* Onboarding — protected, sense AppLayout (wizard full-screen) */}
        <Route
          path="/onboarding"
          element={
            <ProtectedRoute>
              <InternalMemberGate>
                <OnboardingPage />
              </InternalMemberGate>
            </ProtectedRoute>
          }
        />

        <Route
          path="/field/orders/:id/bulletin-preview"
          element={
            <ProtectedRoute>
              <InternalMemberGate>
                <BulletinStandalonePreviewPage />
              </InternalMemberGate>
            </ProtectedRoute>
          }
        />

        {/* Protected routes — all share the AppLayout shell */}
        <Route
          element={
            <ProtectedRoute>
              <InternalMemberGate>
                <AppLayout />
              </InternalMemberGate>
            </ProtectedRoute>
          }
        >
          <Route path="/app" element={<AppIndexPage />} />
          <Route path="/app/sidebar" element={<SidebarEditorPage />} />
          <Route path="/dashboard" element={<DashboardPage />} />
          <Route path="/files" element={<FilesPage />} />
          <Route path="/contacts" element={<ContactsPage />} />
          <Route path="/contacts/:id" element={<ContactDetailPage />} />
          <Route path="/quotes" element={<QuotesPage />} />
          <Route path="/catalog" element={<CatalogPage />} />
          <Route path="/departments" element={<DepartmentsPage />} />
          <Route path="/locations" element={<LocationsPage />} />
          <Route path="/employees" element={<EmployeesPage />} />
          <Route path="/employees/hr" element={<HrDashboardPage />} />
          <Route path="/employees/positions" element={<JobPositionsPage />} />
          <Route path="/employees/organization" element={<OrganizationChartPage />} />
          <Route path="/employees/skills" element={<SkillCatalogPage />} />
          <Route path="/employees/:id" element={<EmployeeDetailPage />} />
          <Route path="/recruitment" element={<RecruitmentLayout />}>
            <Route index element={<ApplicationsPage />} />
            <Route path="applications" element={<ApplicationsPage />} />
            <Route path="postings" element={<JobPostingsPage />} />
            <Route path="inbox" element={<RecruitmentInboundInboxPage />} />
            <Route path="analytics" element={<RecruitmentAnalyticsPage />} />
            <Route path="rights" element={<RightsInboxPage />} />
            <Route path="settings" element={<RecruitmentSettingsPage />} />
          </Route>
          <Route path="/recruitment/postings/:id" element={<JobPostingDetailPage />} />
          <Route path="/documents" element={<DocumentsPage />} />
          <Route path="/documents/archived" element={<ArchivedDocumentsPage />} />
          <Route path="/documents/storage" element={<DocumentsStoragePage />} />
          <Route path="/documents/templates" element={<TemplatesPage />} />
          <Route path="/documents/templates/:id" element={<TemplateDetailPage />} />
          <Route path="/documents/signing" element={<SigningCenterPage />} />
          <Route path="/documents/signing/:id" element={<SigningSubmissionDetail />} />
          <Route path="/documents/:id" element={<DocumentDetailPage />} />
          <Route path="/projects" element={<ProjectsPage />} />
          <Route path="/projects/:id" element={<ProjectDetailPage />} />
          <Route path="/field" element={<FieldServiceLayout />}>
            <Route path="today" element={<TodayPage />} />
            <Route path="orders" element={<FieldOrdersPage />} />
            <Route path="orders/:id" element={<ProjectDetailPage />} />
            <Route path="agenda" element={<FieldAgendaPage />} />
            <Route path="more" element={<FieldMorePage />} />
            <Route path="checklist-templates" element={<ChecklistTemplatesPage />} />
            <Route path="checklist-points" element={<ChecklistPointsPage />} />
            <Route path="response-sets" element={<ChecklistResponseSetsPage />} />
            <Route path="maintenance-plans" element={<MaintenancePlansPage />} />
          </Route>
          <Route path="/public-portal" element={<PublicPortalPage />} />
          <Route path="/public-portal/pages/new" element={<PublicContentEditorPage />} />
          <Route path="/public-portal/pages/:id/edit" element={<PublicContentEditorPage />} />
          <Route path="/employee-portal/content" element={<EmployeeContentListPage />} />
          <Route path="/employee-portal/content/new" element={<EmployeeContentEditorPage />} />
          <Route path="/employee-portal/content/:id/edit" element={<EmployeeContentEditorPage />} />
          <Route path="/attendance" element={<AttendanceLayout />}>
            <Route index element={<PunchPage />} />
            <Route path="record" element={<MyRecordPage />} />
            <Route path="calendar" element={<CalendarPage />} />
            <Route path="absences" element={<PersonalAbsencesPage />} />
            <Route path="shifts" element={<ShiftsPage />} />
          </Route>
          <Route path="/attendances" element={<Navigate to={`${ATTENDANCE_MGMT_BASE}/records`} replace />} />
          <Route path="/control-horari/*" element={<LegacyControlHorariRedirect />} />
          <Route path={ATTENDANCE_MGMT_BASE} element={<ControlHorariLayout />}>
            <Route path="dashboard" element={<TaulerPage />} />
            <Route path="records" element={<FitxatgesPage />} />
            <Route path="employees" element={<Navigate to="records" replace />} />
            <Route path="calendar" element={<PlanificacioPage />} />
            <Route path="planning" element={<PlanningLayout />}>
              <Route index element={<Navigate to="schedules" replace />} />
              <Route path="shifts" element={<ShiftsPage />} />
              <Route path="schedules" element={<SchedulePlannerPage />} />
              <Route path="openings" element={<ShiftOpeningsPage />} />
              <Route path="swaps" element={<ShiftSwapsPage />} />
            </Route>
            <Route path="absences" element={<AbsencesPage />} />
          </Route>
          <Route path="/ai/chat" element={<ChatPage />} />
          <Route path="/ai/chat/s/:shareToken" element={<ChatSharedPage />} />
          <Route path="/automation" element={<AutomationPage />} />
          <Route path="/automation/:runId" element={<AutomationPage />} />
          <Route path="/settings" element={<SettingsPage />}>
            <Route path="config" element={<ConfigPage />} />
            <Route path="members" element={<MembersPage />} />
            <Route path="sites" element={<SitesPage />} />
            <Route path="storage" element={<StoragePage />} />
            <Route path="email" element={<EmailPage />} />
            <Route path="notifications" element={<NotificationsPage />} />
            <Route path="activity" element={<ActivitySettingsLayout />}>
              <Route path="risk" element={<RiskDetectorPage />} />
              <Route path="protocols" element={<PlaybooksPage />} />
              <Route path="templates" element={<CommentTemplatesSettingsPage />} />
            </Route>
            <Route path="timeline" element={<Navigate to="/settings/activity" replace />} />
            <Route path="webhooks" element={<WebhooksPage />} />
            <Route path="secrets" element={<SecretsPage />} />
            <Route path="risk-detector" element={<Navigate to="/settings/activity/risk" replace />} />
            <Route path="playbooks" element={<Navigate to="/settings/activity/protocols" replace />} />
            <Route path="permissions" element={<PermissionsPage />} />
            <Route path="labor-calendar" element={<Navigate to={`${ATTENDANCE_MGMT_BASE}/planning`} replace />} />
            <Route path="attendance-control" element={<AttendanceControlPage />} />
            <Route path="attendance-stations" element={<AttendanceStationsPage />} />
            <Route path="templates" element={<SettingsTemplatesPage />} />
            <Route path="field" element={<Navigate to="/settings/field/checklist-templates" replace />} />
            <Route path="field/checklist-templates" element={<ChecklistTemplatesPage />} />
            <Route path="field/checklist-points" element={<ChecklistPointsPage />} />
            <Route path="field/response-sets" element={<ChecklistResponseSetsPage />} />
            <Route path="signing" element={<SigningPage />} />
            <Route path="ai" element={<AiPage />} />
            <Route path="maps" element={<MapsSettingsPage />} />
            <Route path="customer-portal" element={<CustomerPortalSettingsPage />} />
            <Route path="legal" element={<LegalSettingsPage />} />
            <Route path="operations" element={<OperationsPage />} />
          </Route>
          <Route path="/profile" element={<ProfilePage />} />
        </Route>

        <Route path="/" element={<RootRedirect />} />
        <Route path="*" element={<Navigate to="/dashboard" replace />} />
      </Routes>
      </AttendanceSyncCoordinator>
    </TenantProvider>
    </AuthProvider>
    </QueryClientProvider>
    </TooltipProvider>
    </ThemeProvider>
    <Toaster />
    <Analytics />
    <SpeedInsights />
    </div>
  )
}
