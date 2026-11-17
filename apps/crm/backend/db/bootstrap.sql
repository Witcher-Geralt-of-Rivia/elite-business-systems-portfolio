-- CRM database bootstrap. Run as the cluster superuser, once per database:
--   psql -h 127.0.0.1 -p 5433 -U crm_superuser -d postgres \
--        -v app_password="..." -v dbname=crm -f bootstrap.sql
-- (use -v dbname=crm_test for the automated-test database)
-- Creates:
--   crm_owner  (NOLOGIN)  owns the schema and all objects; migrations run as this role
--   crm_app    (LOGIN)    used by the API and simulator: DML only, no DDL
\set ON_ERROR_STOP on

select 'create role crm_owner nologin'
where not exists (select 1 from pg_roles where rolname = 'crm_owner') \gexec

select format('create role crm_app login password %L', :'app_password')
where not exists (select 1 from pg_roles where rolname = 'crm_app') \gexec

select format('create database %I owner crm_owner encoding ''UTF8'' template template0', :'dbname')
where not exists (select 1 from pg_database where datname = :'dbname') \gexec

\connect :dbname

select format('revoke all on database %I from public', :'dbname') \gexec
select format('grant connect on database %I to crm_app', :'dbname') \gexec
revoke all on schema public from public;

create schema if not exists crm authorization crm_owner;
create extension if not exists citext with schema crm;

grant usage on schema crm to crm_app;
alter default privileges for role crm_owner in schema crm
    grant select, insert, update, delete on tables to crm_app;
alter default privileges for role crm_owner in schema crm
    grant usage, select on sequences to crm_app;
alter default privileges for role crm_owner in schema crm
    grant execute on functions to crm_app;

select format('alter role crm_app in database %I set search_path = crm', :'dbname') \gexec
select format('alter role crm_owner in database %I set search_path = crm', :'dbname') \gexec
