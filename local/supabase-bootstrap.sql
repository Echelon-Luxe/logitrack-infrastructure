-- Run once in the Supabase SQL editor.
--
-- Supabase gives one database per project, so per-service data ownership is
-- enforced with one SCHEMA and one ROLE per service rather than one database
-- each. The boundary is the same: a service can only reach its own tables.
--
-- Passwords here are placeholders. Replace them before running, and store the
-- real values in each service's .env (never in git).

-- ---------------------------------------------------------------- roles ---
CREATE ROLE users_svc         WITH LOGIN PASSWORD 'CHANGE_ME_users';
CREATE ROLE shipments_svc     WITH LOGIN PASSWORD 'CHANGE_ME_shipments';
CREATE ROLE drivers_svc       WITH LOGIN PASSWORD 'CHANGE_ME_drivers';
CREATE ROLE tracking_svc      WITH LOGIN PASSWORD 'CHANGE_ME_tracking';
CREATE ROLE notifications_svc WITH LOGIN PASSWORD 'CHANGE_ME_notifications';

-- -------------------------------------------------------------- schemas ---
CREATE SCHEMA IF NOT EXISTS users         AUTHORIZATION users_svc;
CREATE SCHEMA IF NOT EXISTS shipments     AUTHORIZATION shipments_svc;
CREATE SCHEMA IF NOT EXISTS drivers       AUTHORIZATION drivers_svc;
CREATE SCHEMA IF NOT EXISTS tracking      AUTHORIZATION tracking_svc;
CREATE SCHEMA IF NOT EXISTS notifications AUTHORIZATION notifications_svc;

-- ----------------------------------------------------------- isolation ---
-- Postgres grants every role USAGE on `public` by default, and PUBLIC can
-- create objects there. Without revoking this, any service role could create
-- and read tables in a shared namespace - the exact coupling we are avoiding.
REVOKE ALL ON SCHEMA public FROM PUBLIC;

-- Each role sees only its own schema.
REVOKE ALL ON SCHEMA users         FROM PUBLIC;
REVOKE ALL ON SCHEMA shipments     FROM PUBLIC;
REVOKE ALL ON SCHEMA drivers       FROM PUBLIC;
REVOKE ALL ON SCHEMA tracking      FROM PUBLIC;
REVOKE ALL ON SCHEMA notifications FROM PUBLIC;

-- Pin each role's search_path so a missing schema qualifier fails loudly
-- instead of silently resolving to public.
ALTER ROLE users_svc         SET search_path = users;
ALTER ROLE shipments_svc     SET search_path = shipments;
ALTER ROLE drivers_svc       SET search_path = drivers;
ALTER ROLE tracking_svc      SET search_path = tracking;
ALTER ROLE notifications_svc SET search_path = notifications;

-- ------------------------------------------------------------- verify ---
-- Expect exactly one row per service role, each owning only its own schema.
SELECT n.nspname AS schema, pg_get_userbyid(n.nspowner) AS owner
FROM pg_namespace n
WHERE n.nspname IN ('users','shipments','drivers','tracking','notifications')
ORDER BY 1;
