'use server'

import { unstable_cache } from 'next/cache'
import { prisma } from '@/lib/prisma'

// ---------------------------------------------------------------------------
// Exported types — serializable (no Date objects), safe to pass to client
// components as props.
// ---------------------------------------------------------------------------

/** One bar in the "New Users per Day" chart */
export interface NewUserDay {
  day: string   // "YYYY-MM-DD"
  count: number
}

/** Aggregated activity bucket totals */
export interface ActivityBuckets {
  dau: number   // active today
  wau: number   // active this week
  mau: number   // active this month
  totalActive: number   // ever logged in
  totalUsers: number    // all profiles (incl. pending invites)
}

/** One row in the "At Risk" users table */
export interface AtRiskUser {
  userId: string
  email: string
  fullName: string | null
  lastLoginAt: string | null  // ISO string or null
  tenantId: string | null
  tenantName: string | null
  planName: string | null
  role: string | null
}

export interface AnalyticsData {
  newUsersPerDay: NewUserDay[]
  buckets: ActivityBuckets
  atRiskUsers: AtRiskUser[]
}

// ---------------------------------------------------------------------------
// Raw query result types (from prisma.$queryRaw)
// ---------------------------------------------------------------------------

interface DayCountRow {
  day: Date
  count: number
}

interface BucketRow {
  dau: number
  wau: number
  mau: number
  total_active: number
  total_users: number
}

interface AtRiskRow {
  user_id: string
  email: string
  full_name: string | null
  last_login_at: Date | null
  tenant_id: string | null
  tenant_name: string | null
  plan_name: string | null
  role: string | null
}

// ---------------------------------------------------------------------------
// Data fetching — cached for 5 minutes
// ---------------------------------------------------------------------------

export const getActivityStats = unstable_cache(
  async (): Promise<AnalyticsData> => {
    const [rawDays, rawBuckets, rawAtRisk] = await Promise.all([
      // ── 1. New users per day (last 30 days, grouped by UTC date) ───────────
      prisma.$queryRaw<DayCountRow[]>`
        SELECT
          DATE(first_login_at)::text AS day,
          COUNT(*)::integer          AS count
        FROM data.user_activity_stats
        WHERE first_login_at IS NOT NULL
          AND first_login_at >= NOW() - INTERVAL '30 days'
        GROUP BY DATE(first_login_at)
        ORDER BY DATE(first_login_at)
      `,

      // ── 2. Activity bucket totals ──────────────────────────────────────────
      prisma.$queryRaw<BucketRow[]>`
        SELECT
          SUM(CASE WHEN active_today        THEN 1 ELSE 0 END)::integer AS dau,
          SUM(CASE WHEN active_this_week    THEN 1 ELSE 0 END)::integer AS wau,
          SUM(CASE WHEN active_this_month   THEN 1 ELSE 0 END)::integer AS mau,
          SUM(CASE WHEN has_logged_in       THEN 1 ELSE 0 END)::integer AS total_active,
          COUNT(*)::integer                                              AS total_users
        FROM data.user_activity_stats
      `,

      // ── 3. At-risk users (have logged in, but not in last 14 days) ─────────
      prisma.$queryRaw<AtRiskRow[]>`
        SELECT
          user_id,
          email,
          full_name,
          last_login_at,
          tenant_id,
          tenant_name,
          plan_name,
          role
        FROM data.user_activity_stats
        WHERE is_at_risk = true
        ORDER BY last_login_at ASC NULLS LAST
        LIMIT 50
      `,
    ])

    // Fill the 30-day window with zeroes for days with no new users
    const dayMap = new Map<string, number>()
    for (const row of rawDays) {
      // Prisma returns DATE columns as Date objects; convert to YYYY-MM-DD string
      const key = row.day instanceof Date
        ? row.day.toISOString().substring(0, 10)
        : String(row.day)
      dayMap.set(key, Number(row.count))
    }

    const newUsersPerDay: NewUserDay[] = []
    const today = new Date()
    today.setUTCHours(0, 0, 0, 0)
    for (let i = 29; i >= 0; i--) {
      const d = new Date(today)
      d.setUTCDate(d.getUTCDate() - i)
      const key = d.toISOString().substring(0, 10)
      newUsersPerDay.push({ day: key, count: dayMap.get(key) ?? 0 })
    }

    const b = rawBuckets[0] ?? { dau: 0, wau: 0, mau: 0, total_active: 0, total_users: 0 }
    const buckets: ActivityBuckets = {
      dau:         Number(b.dau),
      wau:         Number(b.wau),
      mau:         Number(b.mau),
      totalActive: Number(b.total_active),
      totalUsers:  Number(b.total_users),
    }

    const atRiskUsers: AtRiskUser[] = rawAtRisk.map((r) => ({
      userId:      r.user_id,
      email:       r.email,
      fullName:    r.full_name ?? null,
      lastLoginAt: r.last_login_at ? r.last_login_at.toISOString() : null,
      tenantId:    r.tenant_id ?? null,
      tenantName:  r.tenant_name ?? null,
      planName:    r.plan_name ?? null,
      role:        r.role ?? null,
    }))

    return { newUsersPerDay, buckets, atRiskUsers }
  },
  ['analytics-activity'],
  { revalidate: 300 }, // 5 minutes
)
