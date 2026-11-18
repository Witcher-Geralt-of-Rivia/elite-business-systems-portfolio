-- 0003: state for the CRM data engine (deterministic backfill + live server-side simulation).

-- Backfilled history must keep its historical updated_at. The API only lets the simulator
-- actor set updated_at explicitly; every other update still gets now().
create or replace function touch_updated_at() returns trigger language plpgsql as $$
begin
    if new.updated_at is not distinct from old.updated_at then
        new.updated_at := now();
    end if;
    return new;
end $$;

-- Singleton: the engine's scenario parameters and its pending event queue, so the live worker
-- resumes exactly where the backfill (or the previous process) stopped.
create table sim_state (
    id integer primary key default 1 check (id = 1),
    seed bigint not null,
    scenario_start timestamptz not null,
    clock timestamptz not null,              -- simulated time processed so far
    tick bigint not null default 0,
    rng_state bigint not null,
    queue jsonb not null default '[]'::jsonb, -- pending business events
    stats jsonb not null default '{}'::jsonb,
    updated_at timestamptz not null default now()
);

-- One row per reset/backfill, for traceability of what produced the data.
create table sim_runs (
    id bigint generated always as identity primary key,
    seed bigint not null,
    scenario_start timestamptz not null,
    as_of timestamptz not null,
    started_at timestamptz not null default now(),
    finished_at timestamptz,
    stats jsonb,
    data_hash text
);

-- Deterministic reset: business data only (team, users, configuration and the audit log stay).
-- SECURITY DEFINER so the app role can restart identities without holding TRUNCATE itself; the
-- function can do nothing else. Ids restart at 1, which makes a replay byte-for-byte comparable.
create function sim_reset() returns void
    language plpgsql security definer
    set search_path to crm, pg_temp
    as $$
begin
    truncate table tasks, contact_notes, deal_notes, deals, contacts, companies, tags restart identity;
    delete from sim_state;
end $$;
revoke execute on function sim_reset() from public;
grant execute on function sim_reset() to crm_app;
