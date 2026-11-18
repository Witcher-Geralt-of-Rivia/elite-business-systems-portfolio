/**
 * Data-integrity and plausibility checks for the CRM dataset. Each check is a SQL query that
 * returns the number of violating rows; a healthy dataset returns 0 for all of them.
 */
import type { Db } from "../db.ts";

export const INTEGRITY_CHECKS: Record<string, string> = {
  company_without_contacts: `select count(*) from companies c where not exists (select 1 from contacts x where x.company_id = c.id)`,
  contact_seen_before_company: `select count(*) from contacts x join companies c on c.id = x.company_id where x.first_seen < c.created_at`,
  contact_last_seen_before_first: `select count(*) from contacts where last_seen < first_seen`,
  deal_before_company: `select count(*) from deals d join companies c on c.id = d.company_id where d.created_at < c.created_at`,
  deal_updated_before_created: `select count(*) from deals where updated_at < created_at`,
  deal_archived_before_created: `select count(*) from deals where archived_at < created_at`,
  archived_deal_still_open: `select count(*) from deals where archived_at is not null and stage not in ('won', 'lost')`,
  closed_deal_closing_before_creation: `select count(*) from deals where stage in ('won', 'lost') and expected_closing_date < created_at::date`,
  deal_contact_from_other_company: `select count(*) from deals d, unnest(d.contact_ids) as cid
                                     join contacts x on x.id = cid where x.company_id is distinct from d.company_id`,
  deal_contact_missing: `select count(*) from deals d, unnest(d.contact_ids) as cid where not exists (select 1 from contacts x where x.id = cid)`,
  deal_note_before_deal: `select count(*) from deal_notes n join deals d on d.id = n.deal_id where n.date < d.created_at`,
  contact_note_before_contact: `select count(*) from contact_notes n join contacts x on x.id = n.contact_id where n.date < x.first_seen`,
  task_before_contact: `select count(*) from tasks t join contacts x on x.id = t.contact_id where t.created_at < x.first_seen`,
  task_due_before_created: `select count(*) from tasks where due_date < created_at`,
  task_done_before_created: `select count(*) from tasks where done_date < created_at`,
  negative_or_zero_amount: `select count(*) from deals where amount is null or amount <= 0`,
  unknown_stage: `select count(*) from deals where stage not in ('opportunity', 'proposal-sent', 'in-negociation', 'won', 'lost', 'delayed')`,
};

/** Checks that need the as-of date: nothing may be dated after it (tasks may be due later). */
const FUTURE_CHECKS: Record<string, string> = {
  company_in_future: `select count(*) from companies where created_at > $1`,
  contact_in_future: `select count(*) from contacts where first_seen > $1 or last_seen > $1`,
  deal_in_future: `select count(*) from deals where created_at > $1 or updated_at > $1 or archived_at > $1`,
  note_in_future: `select (select count(*) from contact_notes where date > $1) + (select count(*) from deal_notes where date > $1)`,
  task_done_in_future: `select count(*) from tasks where done_date > $1 or created_at > $1`,
};

export async function integrityViolations(db: Db, asOf?: Date): Promise<Record<string, number>> {
  const out: Record<string, number> = {};
  for (const [name, sql] of Object.entries(INTEGRITY_CHECKS)) {
    const { rows } = await db.query(sql);
    out[name] = Number(Object.values(rows[0])[0]);
  }
  if (asOf) {
    for (const [name, sql] of Object.entries(FUTURE_CHECKS)) {
      const { rows } = await db.query(sql, [asOf]);
      out[name] = Number(Object.values(rows[0])[0]);
    }
  }
  return out;
}

/** Business-shape indicators used by the plausibility tests and the evidence log. */
export async function businessProfile(db: Db) {
  const q = async (sql: string) => (await db.query(sql)).rows;
  const [counts] = await q(`select (select count(*) from companies)::int as companies, (select count(*) from contacts)::int as contacts,
      (select count(*) from deals)::int as deals, (select count(*) from contact_notes)::int + (select count(*) from deal_notes)::int as notes,
      (select count(*) from tasks)::int as tasks, (select count(*) from tasks where done_date is null)::int as open_tasks`);
  const [closed] = await q(`select count(*) filter (where stage = 'won')::int as won, count(*) filter (where stage = 'lost')::int as lost,
      coalesce(percentile_cont(0.5) within group (order by amount) filter (where stage = 'won'), 0)::int as median_won_amount,
      coalesce(sum(amount) filter (where stage = 'won'), 0)::bigint as won_revenue from deals`);
  const stages = await q(`select stage, count(*)::int as n from deals where archived_at is null group by stage order by stage`);
  const monthly = await q(`select to_char(date_trunc('month', created_at), 'YYYY-MM') as month, count(*)::int as companies
      from companies group by 1 order by 1`);
  // Business activity happens on weekdays (UTC): companies, contacts and notes.
  const [weekend] = await q(`select coalesce(avg(case when extract(isodow from t) in (6, 7) then 1 else 0 end), 0)::float as share from (
      select created_at as t from companies union all select first_seen from contacts
      union all select date from contact_notes union all select date from deal_notes) x`);
  const owners = await q(`select s.first_name || ' ' || s.last_name as owner, count(*)::int as deals,
      count(*) filter (where d.stage = 'won')::int as won from deals d join sales s on s.id = d.sales_id group by 1 order by 1`);
  return {
    ...counts,
    ...closed,
    winRate: closed.won + closed.lost ? closed.won / (closed.won + closed.lost) : 0,
    openPipeline: stages,
    monthlyNewCompanies: monthly,
    weekendShare: weekend.share,
    owners,
  };
}
