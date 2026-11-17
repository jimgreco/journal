-- One-time setup of the journal database on shared_db, run by the owner as
-- the cluster admin. Passwords are passed as psql variables, never stored:
--   docker exec -i shared_db psql -U admin -v ON_ERROR_STOP=1 \
--     -v migrator_pw="$MIGRATOR_PW" -v runtime_pw="$RUNTIME_PW" < provision.sql
--
-- journal_owner     nonlogin, owns every table and sequence
-- journal_migrator  runs migrations: SET ROLE journal_owner (MIGRATION_ROLE)
-- journal_runtime   the app: DML on the app tables only (granted by 001)
--
-- The backup contract (consolidated-deploy CONTRACTS) expects the owner and
-- migrator without login and the runtime with login. The migrator is given
-- LOGIN only for the length of a migration (see deploy/RUNBOOK.md).

CREATE ROLE journal_owner NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
CREATE ROLE journal_migrator NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS
  PASSWORD :'migrator_pw';
CREATE ROLE journal_runtime LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS
  PASSWORD :'runtime_pw';
GRANT journal_owner TO journal_migrator WITH INHERIT FALSE, SET TRUE;

CREATE DATABASE journal OWNER journal_owner;
REVOKE ALL ON DATABASE journal FROM PUBLIC;
GRANT CONNECT ON DATABASE journal TO journal_migrator, journal_runtime;

\connect journal
ALTER SCHEMA public OWNER TO journal_owner;
REVOKE ALL ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO journal_runtime;
ALTER DEFAULT PRIVILEGES FOR ROLE journal_owner REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
