import { QueryClient } from '@tanstack/react-query'

export const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      // Los datos se consideran frescos durante 5 minutos.
      // Pasado ese tiempo, React Query los revalidará en segundo plano.
      staleTime: 1000 * 60 * 5,
      // Reintenta 1 vez si la query falla (ej: error de red puntual)
      retry: 1,
    },
    mutations: {
      // No reintentar mutaciones automáticamente para evitar acciones duplicadas
      retry: 0,
    },
  },
})
