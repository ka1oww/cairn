-- Extensions this schema depends on.
-- pgcrypto gives us gen_random_uuid() for primary keys.
create extension if not exists pgcrypto;
