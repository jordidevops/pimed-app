import { createContext, useContext, useEffect, useState, type ReactNode } from 'react'
import type { Session, User } from '@supabase/supabase-js'
import { supabase } from '../lib/supabase'

interface AuthContextType {
  session: Session | null
  user: User | null
  loading: boolean
  signOut: () => Promise<void>
}

const AuthContext = createContext<AuthContextType | undefined>(undefined)

export function AuthProvider({ children }: { children: ReactNode }) {
  const [session, setSession] = useState<Session | null>(null)
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    // Get initial session
    supabase.auth.getSession().then(({ data: { session } }) => {
      setSession(session)
      setLoading(false)
    })

    // Listen for auth changes (login, logout, token refresh)
    const {
      data: { subscription },
    } = supabase.auth.onAuthStateChange((event, session) => {
      setSession(session)

      // Record first/last login in our own profiles table.
      // Use sessionStorage so it fires once per browser session, not on every
      // token refresh or page reload.
      if (event === 'SIGNED_IN' && session) {
        const key = `login_recorded_${session.user.id}`
        if (!sessionStorage.getItem(key)) {
          sessionStorage.setItem(key, '1')
          supabase.rpc('record_login').then(() => {
            // silent — non-critical
          })
        }
      } else if (event === 'SIGNED_OUT') {
        Object.keys(sessionStorage)
          .filter((k) => k.startsWith('login_recorded_'))
          .forEach((k) => sessionStorage.removeItem(k))
      }
    })

    return () => subscription.unsubscribe()
  }, [])

  const signOut = async () => {
    await supabase.auth.signOut()
  }

  return (
    <AuthContext.Provider value={{ session, user: session?.user ?? null, loading, signOut }}>
      {children}
    </AuthContext.Provider>
  )
}

export function useAuth() {
  const context = useContext(AuthContext)
  if (context === undefined) {
    throw new Error('useAuth must be used within an AuthProvider')
  }
  return context
}
