import { useMemo } from 'react'
import { usePermission } from '@/hooks/usePermission'
import type { Employee } from '../api/employeesService'

export interface EmployeePermissions {
  canViewDirectory: boolean
  canView: boolean
  canManage: boolean
  canViewPrivate: boolean
  canManagePrivate: boolean
  canRevealPrivate: boolean
  canViewLifecycle: boolean
  canManageLifecycle: boolean
}

export function useEmployeePermissions(
  employee?: Pick<Employee, 'site_id'> | null,
): EmployeePermissions {
  const siteId = employee?.site_id ?? undefined

  const canViewDirectory = usePermission('employees.directory.view', siteId)
  const canView = usePermission('employees.view', siteId)
  const canManage = usePermission('employees.manage', siteId)
  const canViewPrivate = usePermission('employees.private.view', siteId)
  const canManagePrivate = usePermission('employees.private.manage', siteId)
  const canRevealPrivate = usePermission('employees.private.reveal', siteId)
  const canViewLifecycle = usePermission('employees.lifecycle.view', siteId)
  const canManageLifecycle = usePermission('employees.lifecycle.manage', siteId)

  return useMemo(
    () => ({
      canViewDirectory,
      canView,
      canManage,
      canViewPrivate,
      canManagePrivate,
      canRevealPrivate,
      canViewLifecycle,
      canManageLifecycle,
    }),
    [
      canViewDirectory,
      canView,
      canManage,
      canViewPrivate,
      canManagePrivate,
      canRevealPrivate,
      canViewLifecycle,
      canManageLifecycle,
    ],
  )
}
