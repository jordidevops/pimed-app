import { useMemo } from 'react'
import { useTranslation } from 'react-i18next'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'
import { useAuth } from '@/contexts/AuthContext'
import { useTenant } from '@/contexts/TenantContext'
import { useEffectiveSettings, useMemberSettingsMutation, useTenantSettingsMutation } from '@/hooks/useSettings'
import { usePermission } from '@/hooks/usePermission'
import { useMyEmployee } from '@/features/attendance/api/useMyEmployee'
import { useTenantFeatures } from '@/features/entity-timeline/api/useTenantFeatures'
import { useIsFieldService, useSectorContactListLabel, useSectorLabel } from '@/hooks/useSectorLabel'
import { useFieldServiceHome } from '@/features/field-service/hooks/useFieldServiceHome'
import {
  SIDEBAR_NAV_TENANT_KEY,
  SIDEBAR_NAV_USER_KEY,
  parseSidebarNav,
  sidebarNavSchema,
  type SidebarNavV1,
} from './sidebarNavSchema'
import {
  pickSidebarLayout,
  resolveLauncherNav,
  resolveSidebarNav,
  sanitizeLayoutAgainstCatalog,
  type NavGateContext,
  type ResolvedNavGroup,
} from './resolveNav'
import { buildDefaultNavLayout } from './defaultNavLayout'

export type SidebarNavScope = 'user' | 'tenant'

export function useNavGateContext(): { ctx: NavGateContext; gatesLoading: boolean } {
  const { activeRole } = useTenant()
  const isManager = activeRole === 'owner' || activeRole === 'manager'
  const { data: myEmployee, isLoading: myEmployeeLoading } = useMyEmployee()
  const hasMyEmployee = !myEmployeeLoading && !!myEmployee
  const canPunchOwn = usePermission('attendance.punch_own', myEmployee?.site_id ?? null)
  const canUseAttendance = hasMyEmployee && canPunchOwn
  const { data: features, isLoading: featuresLoading } = useTenantFeatures()
  const canViewRecruitment = usePermission('recruitment.view')
  const showRecruitment = Boolean(features?.recruitment_enabled) && canViewRecruitment
  const isFieldService = useIsFieldService()
  const { path: homePath, ready: homeReady } = useFieldServiceHome()

  const ctx = useMemo(
    () => ({
      isManager,
      hasMyEmployee,
      canUseAttendance,
      showRecruitment,
      isFieldService,
      homePath,
    }),
    [isManager, hasMyEmployee, canUseAttendance, showRecruitment, isFieldService, homePath],
  )

  return {
    ctx,
    gatesLoading: myEmployeeLoading || featuresLoading || !homeReady,
  }
}

export function useSidebarNav() {
  const { t } = useTranslation('common')
  const { user } = useAuth()
  const { activeTenant } = useTenant()
  const tenantId = activeTenant?.id ?? null
  const { ctx, gatesLoading } = useNavGateContext()
  const canEditTenant = usePermission('settings.manage', null)

  const contactLabel = useSectorContactListLabel()
  const projectLabel = useSectorLabel('project', t('nav.projects', 'Projectes'))
  const labels = useMemo(
    () => ({
      t: (key: string, fallback: string) => t(key, fallback),
      contactLabel,
      projectLabel,
    }),
    [t, contactLabel, projectLabel],
  )

  const settingsQuery = useEffectiveSettings(
    { tenantId, userId: user?.id ?? null },
    { enabled: !!tenantId },
  )

  const userRaw = settingsQuery.data?.[SIDEBAR_NAV_USER_KEY]
  const tenantRaw = settingsQuery.data?.[SIDEBAR_NAV_TENANT_KEY]

  const userLayout = useMemo(() => parseSidebarNav(userRaw), [userRaw])
  const tenantLayout = useMemo(() => parseSidebarNav(tenantRaw), [tenantRaw])

  const picked = useMemo(
    () => pickSidebarLayout(userRaw, tenantRaw),
    [userRaw, tenantRaw],
  )

  const settingsLoading = !!tenantId && settingsQuery.isLoading
  const navLoading = settingsLoading || gatesLoading

  const resolvedNav = useMemo(() => {
    if (navLoading) return { pinned: null, groups: [] as ResolvedNavGroup[] }
    return resolveSidebarNav(picked.layout, ctx, labels)
  }, [navLoading, picked.layout, ctx, labels])

  const launcherGroups: ResolvedNavGroup[] = useMemo(() => {
    if (gatesLoading) return []
    return resolveLauncherNav(ctx, labels)
  }, [gatesLoading, ctx, labels])

  const memberMut = useMemberSettingsMutation()
  const tenantMut = useTenantSettingsMutation()
  const queryClient = useQueryClient()

  const saveUser = useMutation({
    mutationFn: async (layout: SidebarNavV1) => {
      const parsed = sidebarNavSchema.parse(sanitizeLayoutAgainstCatalog(layout))
      await memberMut.mutateAsync({ [SIDEBAR_NAV_USER_KEY]: parsed })
    },
  })

  const saveTenant = useMutation({
    mutationFn: async (layout: SidebarNavV1) => {
      if (!canEditTenant) throw new Error('Missing settings.manage')
      const parsed = sidebarNavSchema.parse(sanitizeLayoutAgainstCatalog(layout))
      await tenantMut.mutateAsync({ [SIDEBAR_NAV_TENANT_KEY]: parsed })
    },
  })

  const resetUser = useMutation({
    mutationFn: async () => {
      if (!tenantId) throw new Error('No active tenant')
      // Prefer clear RPC (removes key). Fallback: JSON null = inherit (works pre-migration).
      const { error } = await supabase.rpc('clear_my_member_setting', {
        p_setting_key: SIDEBAR_NAV_USER_KEY,
        p_tenant_id: tenantId,
      })
      if (error) {
        await memberMut.mutateAsync({ [SIDEBAR_NAV_USER_KEY]: null })
      }
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['effective_settings'] })
    },
  })

  const resetTenant = useMutation({
    mutationFn: async () => {
      if (!tenantId) throw new Error('No active tenant')
      if (!canEditTenant) throw new Error('Missing settings.manage')
      const { error } = await supabase.rpc('clear_tenant_setting', {
        p_setting_key: SIDEBAR_NAV_TENANT_KEY,
        p_tenant_id: tenantId,
      })
      if (error) {
        await tenantMut.mutateAsync({ [SIDEBAR_NAV_TENANT_KEY]: null })
      }
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['effective_settings'] })
    },
  })

  return {
    tenantId,
    ctx,
    canEditTenant,
    navLoading,
    gatesLoading,
    settingsLoading,
    source: picked.source,
    resolvedNav,
    resolvedGroups: resolvedNav.groups,
    launcherGroups,
    userLayout,
    tenantLayout,
    platformLayout: buildDefaultNavLayout(),
    hasUserOverride: userLayout != null,
    hasTenantOverride: tenantLayout != null,
    saveUser,
    saveTenant,
    resetUser,
    resetTenant,
    labels,
  }
}
