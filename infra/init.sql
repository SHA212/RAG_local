/* 

Rules initialized at container creation. Executed by database admin/superuser. Database URL MUST also connect as admin.
Application MUST connect as app_user. Admin retains all privileges, subset of which is passed on to user at runtime.
All other future users are locked out unless explicitly granted privileges. This script runs only once.

*/

-- In case of init failure secrets are stored as plaintext to logs. Cheaper to just restart container with persistent volume.   
SET log_statement = 'none';
SET log_min_error_statement = 'panic';

-- Initialize/enable pgvector extension with idempotency for postgresql
CREATE EXTENSION IF NOT EXISTS vector;

-- Pass secret and least privilege user variables from .env through docker-compose
\getenv app_user APP_DB_USER
\getenv app_pass APP_DB_PASSWORD
\getenv db_name POSTGRES_DB

/*
-- Guard against empty or short passwords or placeholders
SELECT (length(:'app_pass') >= 32 AND position('change_me' in :'app_pass') = 0) AS pass_ok;
\gset init_
\if :init_pass_ok
    \echo "app password accepted"
\else
    DO $$ BEGIN RAISE EXCEPTION 'APP_DB_PASSWORD is too short or empty or is a placeholder'; END $$;
\endif

--either that or:

SELECT (
    length(:'app_pass') > 0
    AND :'app_pass' !~ '\s'
    AND position('change_me' in lower(:'app_pass')) = 0
) AS pass_ok
\gset init_

\if :init_pass_ok
    \echo 'app password accepted'
\else
    DO $$ BEGIN RAISE EXCEPTION 'APP_DB_PASSWORD cannot be empty, contain whitespace, or use a placeholder'; END $$;
\endif


-- Create runtime user role with idempotency
SELECT EXISTS(SELECT FROM pg_catalog.pg_roles where rolname = :'app_user') AS role_exists
\gset init_
\if :init_role_exists
    \echo "role already exists, skipping..."
\else
    CREATE ROLE :"app_user" WITH LOGIN PASSWORD :'app_pass';
\endif
*/

-- Create runtime user role with idempotency 
-- \gexec instead of DO $$ ... $$ since it can take parameters and is secure for passed string literals through %I and %L
-- WHERE NOT EXISTS almost redundant, only for forced manual reruns 
SELECT format(
    'CREATE ROLE %I WITH LOGIN PASSWORD %L', :'app_user', :'app_pass'
)
WHERE NOT EXISTS(
    SELECT FROM pg_catalog.pg_roles 
    WHERE rolname = :'app_user'
)
\gexec

-- Lock down DB to all new users and manually allow selected only for app_user
-- Pseudo-role PUBLIC (every role) by default gets CONNECT and TEMPORARY. First close all open doors
-- Since init is run only once at creation as admin, temp can be created to test container health and db function
SELECT format(
    'REVOKE CONNECT, TEMPORARY ON DATABASE %I FROM PUBLIC', :'db_name' 
)
\gexec
-- Allow app_user to connect to DB
SELECT format(
    'GRANT CONNECT ON DATABASE %I TO %I', :'db_name', :'app_user'
)
\gexec
-- Allow app_user read access to DB
SELECT format(
    'GRANT USAGE ON SCHEMA public to %I', :'app_user'
)
\gexec
-- Create Analytics schema that app_user owns for later dbt views
SELECT format(
    'CREATE SCHEMA IF NOT EXISTS analytics AUTHORIZATION %I', :'app_user'
)
\gexec

-- Later tables created would belong to admin only. So write rules to grant permissions on later tables
-- Allow app_user to manipulate tables created in public schema by admin
SELECT format(
    'ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO %I', :'app_user'
)
\gexec
-- Allow app_user to use SEQUENCES for SERIAL value columns since INSERT is granted and would fail without it 
SELECT format(
    'ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO %I', :'app_user'
)
\gexec