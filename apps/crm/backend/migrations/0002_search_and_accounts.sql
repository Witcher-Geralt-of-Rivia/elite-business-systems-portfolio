-- 0002: global search (ported from upstream supabase/schemas/08_search.sql) and account tokens
-- for invitations / password resets. Runs as crm_owner with search_path = crm.

-- ---------------------------------------------------------------- search
-- unaccent is a trusted extension (PG13+): the database owner role may create it.
create extension if not exists unaccent schema crm;

-- unaccent() is only STABLE (its dictionary could change), which generated columns reject.
-- The dictionary is pinned here, so the wrapper is immutable (same reasoning as upstream).
create function search_unaccent(value text) returns text
    language sql immutable strict parallel safe
    set search_path to ''
    as $$ select crm.unaccent('crm.unaccent'::regdictionary, value) $$;

-- Documents and queries are normalized the same way: unaccented, lowercased, split on anything
-- that is not a letter or digit. "hélène.dupont@acme.fr" indexes as helene, dupont, acme, fr.
create function search_document(variadic parts text[]) returns tsvector
    language sql immutable parallel safe
    set search_path to ''
    as $$
        select to_tsvector('simple'::regconfig,
            regexp_replace(crm.search_unaccent(array_to_string(parts, ' ')), '[^[:alnum:]]+', ' ', 'g'))
    $$;

-- Every word must match as a prefix: "tho dup" finds "Thomas Dupont". Null for a blank query.
create function search_query(query text) returns tsquery
    language sql immutable strict parallel safe
    set search_path to ''
    as $$
        select to_tsquery('simple'::regconfig, string_agg(word || ':*', ' & '))
        from regexp_split_to_table(lower(crm.search_unaccent(query)), '[^[:alnum:]]+') as word
        where word <> ''
    $$;

create function search_attachment_titles(attachments jsonb[]) returns text
    language sql immutable parallel safe
    set search_path to ''
    as $$ select string_agg(attachment ->> 'title', ' ') from unnest(attachments) as attachment $$;

alter table companies add column fts tsvector generated always as (
    setweight(crm.search_document(name), 'A')
    || crm.search_document(sector, description, website::text, phone_number, zipcode, city, state_abbr)
) stored;

alter table contacts add column fts tsvector generated always as (
    setweight(crm.search_document(first_name, last_name), 'A')
    || crm.search_document(
        title,
        background,
        jsonb_path_query_array(email_jsonb, '$[*]."email"')::text,
        jsonb_path_query_array(phone_jsonb, '$[*]."number"')::text)
) stored;

alter table deals add column fts tsvector generated always as (
    setweight(crm.search_document(name), 'A')
    || crm.search_document(variadic array[description] || categories)
) stored;

alter table tasks add column fts tsvector generated always as (crm.search_document(text, type)) stored;

alter table contact_notes add column fts tsvector generated always as (
    crm.search_document(text, crm.search_attachment_titles(attachments))
) stored;

alter table deal_notes add column fts tsvector generated always as (
    crm.search_document(text, crm.search_attachment_titles(attachments))
) stored;

create index companies_fts_idx on companies using gin (fts);
create index contacts_fts_idx on contacts using gin (fts);
create index deals_fts_idx on deals using gin (fts) where archived_at is null;
create index tasks_fts_idx on tasks using gin (fts) where done_date is null;
create index contact_notes_fts_idx on contact_notes using gin (fts);
create index deal_notes_fts_idx on deal_notes using gin (fts);
create index if not exists contacts_first_seen_idx on contacts (first_seen desc nulls last);
create index if not exists tasks_open_created_at_idx on tasks (created_at desc) where done_date is null;
create index if not exists contact_notes_date_idx on contact_notes (date desc nulls last);
create index if not exists deal_notes_date_idx on deal_notes (date desc nulls last);

-- Same contract as upstream global_search(): per-resource cap (<= 200), relevance-ranked
-- companies/contacts/deals, newest-first tasks and notes, open tasks and live deals only.
create function global_search(query text, resources text[] default null, max_results integer default 50)
    returns table (resource text, record_id bigint, title text, subtitle text, contact_id bigint,
                   deal_id bigint, date timestamptz, content text)
    language plpgsql stable
    set search_path to ''
    set plan_cache_mode to 'force_custom_plan'
    as $$
#variable_conflict use_column
declare
    tsq tsquery := crm.search_query(query);
    row_limit constant integer := least(coalesce(max_results, 50), 200);
begin
    if tsq is null or row_limit < 1 then
        return;
    end if;

    return query
    select resource, record_id, title, subtitle, contact_id, deal_id, date, content
    from (
        (select 'companies' as resource, c.id as record_id, c.name as title, c.sector as subtitle,
            null::bigint as contact_id, null::bigint as deal_id, c.created_at as date,
            concat_ws(' · ', c.sector, c.description, c.website::text, c.phone_number, c.zipcode, c.city, c.state_abbr) as content,
            ts_rank(c.fts, tsq) as rank
        from crm.companies c
        where (resources is null or 'companies' = any(resources)) and c.fts @@ tsq
        order by rank desc, c.created_at desc
        limit row_limit)
        union all
        (select 'contacts', co.id, concat_ws(' ', co.first_name, co.last_name),
            (select cc.name from crm.companies cc where cc.id = co.company_id), co.id, null::bigint, co.first_seen,
            concat_ws(' · ', co.title, co.background,
                (select string_agg(e ->> 'email', ' ') from jsonb_array_elements(co.email_jsonb) e),
                (select string_agg(p ->> 'number', ' ') from jsonb_array_elements(co.phone_jsonb) p)),
            ts_rank(co.fts, tsq) as rank
        from crm.contacts co
        where (resources is null or 'contacts' = any(resources)) and co.fts @@ tsq
        order by rank desc, co.first_seen desc nulls last
        limit row_limit)
        union all
        (select 'deals', d.id, d.name,
            (select dc.name from crm.companies dc where dc.id = d.company_id), null::bigint, d.id, d.created_at,
            concat_ws(' · ', variadic d.categories || d.description),
            ts_rank(d.fts, tsq) as rank
        from crm.deals d
        where (resources is null or 'deals' = any(resources)) and d.archived_at is null and d.fts @@ tsq
        order by rank desc, d.created_at desc
        limit row_limit)
        union all
        (select 'tasks', t.id, left(t.text, 200),
            (select concat_ws(' ', tc.first_name, tc.last_name) from crm.contacts tc where tc.id = t.contact_id),
            t.contact_id, null::bigint, t.created_at, concat_ws(' · ', t.text, t.type), 0
        from crm.tasks t
        where (resources is null or 'tasks' = any(resources)) and t.done_date is null and t.fts @@ tsq
        order by t.created_at desc
        limit row_limit)
        union all
        (select 'contact_notes', cn.id, left(cn.text, 200),
            (select concat_ws(' ', nc.first_name, nc.last_name) from crm.contacts nc where nc.id = cn.contact_id),
            cn.contact_id, null::bigint, cn.date,
            concat_ws(' · ', cn.text, crm.search_attachment_titles(cn.attachments)), 0
        from crm.contact_notes cn
        where (resources is null or 'contact_notes' = any(resources)) and cn.fts @@ tsq
        order by cn.date desc nulls last
        limit row_limit)
        union all
        (select 'deal_notes', dn.id, left(dn.text, 200), nd.name, null::bigint, dn.deal_id, dn.date,
            concat_ws(' · ', dn.text, crm.search_attachment_titles(dn.attachments)), 0
        from crm.deal_notes dn
            join crm.deals nd on nd.id = dn.deal_id
        where (resources is null or 'deal_notes' = any(resources)) and nd.archived_at is null and dn.fts @@ tsq
        order by dn.date desc nulls last
        limit row_limit)
    ) results
    order by rank desc, date desc nulls last;
end
$$;

revoke execute on function global_search(text, text[], integer) from public;
grant execute on function global_search(text, text[], integer) to crm_app;

-- ---------------------------------------------------------------- account tokens
-- One table for both one-time links: 'invite' (new team member sets a first password) and
-- 'reset' (admin- or self-issued password reset). Only sha256(token) is stored.
alter table password_reset_tokens
    add column purpose text not null default 'reset' check (purpose in ('invite', 'reset')),
    add column created_by bigint references sales(id);
create index password_reset_tokens_user_idx on password_reset_tokens (user_id) where used_at is null;
