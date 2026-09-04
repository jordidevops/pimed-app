import type { NextConfig } from 'next'

const nextConfig: NextConfig = {
  reactStrictMode: true,
  // Evita l'avís de múltiples lockfiles (root + apps/*/package-lock.json).
  turbopack: {
    root: process.cwd(),
  },
}

export default nextConfig
