
## Documentacio PiMed

- [Guia de cues (PGMQ)](docs/queues.md)
- [Infraestructura async](docs/async-infraestructure.md)
- [Product design - index](docs/product-design/00-README.md)


Subir esquema bd

    supabase db push --project-ref <staging-ref>
    supabase db push --project-ref <prod-ref

Staging

    supabase db push --project-ref cevzgddbhiellnmajkjb

    .\scripts\db-push.ps1 staging

Prod

    supabase db push --project-ref pglgtzbdqngoitqamzzu

    .\scripts\db-push.ps1 prod


```
Desarrollador
    │
    ├─ npm run dev           → Supabase local (:54321)
    │                           .env.development
    │
    ├─ npm run build:staging → Build con .env.staging
    │   + .\scripts\db-push.ps1 staging   → Supabase cloud staging
    │     
    │
    └─ npm run build         → Build con .env.production
        + .\scripts\db-push.ps1 prod  → Supabase cloud prod
```


Fer només seed de dades

```
docker exec -i supabase_db_cavalle-app psql -U postgres -d postgres < supabase/seed.sql
```

```PS
Get-Content .\supabase\seed.sql -Raw | docker exec -i supabase_db_cavalle-app psql -U postgres -d postgres
```

Engegar les functions

supabase functions serve --env-file ./supabase/functions/.env.local

```
supabase status
```

Mostra les URLs locals (Studio, Mailpit, APIs, DB) i les claus d'autenticació generades per aquest entorn. Les claus canvien cada `supabase start` — no les copiïs mai al README, consulta-les directament amb la comanda anterior.