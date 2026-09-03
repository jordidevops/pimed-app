-- Pujem el límit a 50.000 perquè el test passi sencer
UPDATE data.email_configs SET rate_limit_per_hour = 50000, rate_limit_per_day = 50000;