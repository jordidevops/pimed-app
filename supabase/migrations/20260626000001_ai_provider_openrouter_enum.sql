-- OpenRouter: afegir valor a l'enum (transacció separada — PostgreSQL no permet usar-lo a la mateixa)

ALTER TYPE data.ai_provider ADD VALUE IF NOT EXISTS 'openrouter';
