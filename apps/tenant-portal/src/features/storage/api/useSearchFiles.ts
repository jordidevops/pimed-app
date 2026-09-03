import { useQuery } from '@tanstack/react-query'
import { storageKeys } from './storageKeys'
import { searchFiles } from './storageService'
import type { SearchResult } from '../types/storage.types'

/**
 * Full-text search across file names within a tenant (pg_trgm similarity).
 * Returns up to 50 results ordered by relevance.
 *
 * The query is only fired when `query` is 2+ characters — debouncing the
 * input upstream is recommended to avoid excessive DB calls.
 *
 * @example
 * const [q, setQ] = useState('')
 * const debouncedQ = useDebounce(q, 300)
 * const { data: results } = useSearchFiles(tenantId, debouncedQ)
 */
export function useSearchFiles(tenantId: string | undefined, query: string) {
  return useQuery<SearchResult[]>({
    queryKey: storageKeys.searchResults(tenantId ?? '', query),
    queryFn: () => searchFiles(tenantId!, query),
    enabled: !!tenantId && query.trim().length >= 2,
    // Search results go stale quickly — shorter cache window than the default 5 min
    staleTime: 1000 * 30, // 30 seconds
  })
}
