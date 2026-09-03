// prisma.config.ts — Configuració per al Prisma CLI (db pull, generate, studio)
//
// IMPORTANT: Prisma v7 requereix que les URLs de connexió siguin aquí, NO a schema.prisma.
//
// L'import de 'dotenv/config' carrega automàticament el fitxer .env de l'arrel del projecte.
// Per a dev, els scripts del package.json usen dotenv-cli per carregar .env.development:
//   npm run prisma:pull  →  dotenv -e .env.development -- prisma db pull
//
// Per a staging/prod, les variables d'entorn les injecta la plataforma (Vercel, Railway, etc.)

import 'dotenv/config'
import { defineConfig } from 'prisma/config'

export default defineConfig({
  schema: 'prisma/schema.prisma',
  datasource: {
    // DATABASE_URL: connexió directa al PostgreSQL local en dev.
    // Ha d'incloure ?schema=data per apuntar a l'schema correcte.
    // dev:     postgresql://prisma_admin:pwd@localhost:54322/postgres?schema=data
    // staging: postgresql://prisma_admin:pwd@<host>:5432/postgres?schema=data
    url: process.env.DATABASE_URL ?? '',
  },
})
