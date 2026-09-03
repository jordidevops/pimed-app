# Product Design — Plataforma SaaS Multi-Sector

Aquesta carpeta recull el **disseny de producte i arquitectura funcional** abans
d'implementar res. Cap codi: només decisions, models conceptuals, riscos i
ordre d'execució. Anirem refinant aquests documents fins que el disseny sigui
prou estable per generar prompts d'implementació.

## Índex

1. [Visió i posicionament](01-vision-and-positioning.md)
2. [Model de domini bàsic](02-domain-model.md)
3. [Arquetips i verticals — perfils sectorials i onboarding](03-sector-profiles.md)
4. [Rols, permisos i identitats](04-roles-and-permissions.md)
5. [Mapa de mòduls i ordre d'implementació](05-modules-roadmap.md)
6. [Integracions externes](06-integracions.md)
7. [Mobile-first i palanca IA](07-mobile-and-ai-leverage.md)
8. [Checklist contra ERP/CRM clàssics](08-erp-crm-checklist.md)
9. [Backlog executable del Public Portal](11-public-portal-execution-backlog.md)
10. [Sprint plan del Public Portal](12-public-portal-sprint-plan.md)
11. [Customer Portal — Arquitectura i Model de Compartició](13-customer-portal-architecture.md)
12. [Control horari — Overview funcional i migració des de JCM](14-time-attendance-overview.md)
13. [Control horari — Arquitectura, sincronització i fluxos](15-time-attendance-architecture.md)
14. [Control horari — Model de dades Postgres orientatiu](16-time-attendance-data-model.md)

## Principis de disseny

1. **Pragmàtic abans que perfecte.** Si una funcionalitat no té un usuari real
   demanant-la a curt termini, no es construeix.
2. **Primitives genèriques, no taules sectorials.** Un `Client` és un `Contact`
   amb metadades del sector. Mai una taula `dental_patients`.
3. **Mobile-first real**, no responsive a posteriori. L'autònom treballa al
   carrer amb el mòbil.
4. **IA com a palanca de productivitat**, no com a feature de màrqueting:
   dictat de notes, redacció de correus, OCR de tickets, classificació
   automàtica.
5. **Multi-tenant + RLS sense excepcions.** Cap bypass fora de l'admin-portal.
6. **Async per defecte** per a tot el que no necessita resposta immediata
   (notificacions, sincronitzacions, IA).
7. **Onboarding < 5 minuts.** Triar sector → recepta aplicada → llest per
   treballar.
