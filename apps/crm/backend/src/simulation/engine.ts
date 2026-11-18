/**
 * CRM data engine: an event-driven model of a B2B sales operation.
 *
 * Every record is the consequence of a business event, in chronological order:
 *   lead arrives (seasonal, growing, business days only)
 *     -> company + contacts + intro note + first task, owned by the rep covering the region
 *     -> (maybe) a deal opens -> opportunity -> proposal-sent -> in-negociation -> won | lost
 *        (each transition: probabilities depend on rep skill and quarter-end pressure, durations
 *         on the product's sales cycle; notes and tasks follow the transition; contacts' status
 *         and last_seen move with the activity)
 *     -> closed deals are archived later; customers get check-ins that can open expansion deals.
 *
 * Determinism: all randomness comes from one seeded Rng whose state is persisted with the event
 * queue, so (seed, scenario start, as-of) always produces the same data, and the live worker
 * resumes exactly where the backfill stopped.
 */
import catalogJson from "./catalog.json" with { type: "json" };
import { Rng } from "./rng.ts";

export const catalog = catalogJson;
type Category = (typeof catalog.dealCategories)[number];
type Sector = (typeof catalog.sectors)[number];

export interface Writer {
  create(resource: string, ownerId: number, data: Record<string, unknown>): Promise<number>;
  update(resource: string, ownerId: number, id: number, data: Record<string, unknown>): Promise<void>;
}

export interface TeamMember {
  salesId: number;
  skill: number;
  capacity: number;
  regions: string[];
}

interface DealCtx {
  dealId: number;
  companyId: number;
  contactIds: number[];
  leadContactId: number;
  first: string;
  short: string;
  category: string;
  amount: number;
  stage: string;
  prevStage?: string;
  ownerId: number;
  sector: string;
  pain: string;
  /** Deal size scales with the customer's size. */
  sizeFactor: number;
  /** Tags of the lead contact as set by the engine (so adding one never drops the others). */
  leadTags: number[];
}

type Ev =
  | { at: number; seq: number; kind: "lead" }
  | { at: number; seq: number; kind: "open_deal"; ctx: Omit<DealCtx, "dealId" | "category" | "amount" | "stage">; expansion?: boolean }
  | { at: number; seq: number; kind: "advance_deal"; ctx: DealCtx }
  | { at: number; seq: number; kind: "archive_deal"; dealId: number; ownerId: number }
  | { at: number; seq: number; kind: "complete_task"; taskId: number; ownerId: number }
  | { at: number; seq: number; kind: "checkin"; ctx: Omit<DealCtx, "dealId" | "category" | "amount" | "stage">; customer: boolean };

type NewEvent = Ev extends infer E ? (E extends unknown ? Omit<E, "seq"> : never) : never;

export interface EngineState {
  seed: number;
  scenarioStart: number; // ms
  clock: number; // ms, simulated time processed so far
  rngState: number;
  seq: number;
  queue: Ev[];
  usedNames: string[];
  dealIndex: number;
  tagIds: Record<string, number>;
  stats: Record<string, number>;
}

const DAY = 86_400_000;
const SEASONALITY = [0.85, 0.95, 1.1, 1.05, 1.0, 0.95, 0.8, 0.8, 1.1, 1.15, 1.0, 0.7];
/** Mean leads per business day at the start of the scenario (grows ~25%/year). */
const BASE_LEADS_PER_DAY = 1.5;

export function initialState(seed: number, scenarioStart: Date): EngineState {
  // Start at midnight UTC so day boundaries are stable.
  const start = Date.UTC(scenarioStart.getUTCFullYear(), scenarioStart.getUTCMonth(), scenarioStart.getUTCDate());
  return {
    seed,
    scenarioStart: start,
    clock: start,
    rngState: seed >>> 0,
    seq: 0,
    queue: [],
    usedNames: [],
    dealIndex: 0,
    tagIds: {},
    stats: {},
  };
}

const iso = (ms: number) => new Date(ms).toISOString();
const dateOnly = (ms: number) => new Date(ms).toISOString().slice(0, 10);
const isWeekend = (ms: number) => [0, 6].includes(new Date(ms).getUTCDay());

/** Moves a timestamp into business hours (08:00–18:00 US Central ≈ 14:00–24:00 UTC), Mon–Fri. */
function businessTime(ms: number, rng: Rng): number {
  let t = ms;
  while (isWeekend(t)) t += DAY;
  const d = new Date(t);
  const hour = d.getUTCHours();
  if (hour < 14) d.setUTCHours(14 + rng.int(0, 3), rng.int(0, 59), rng.int(0, 59), 0);
  else if (hour >= 23) {
    const next = businessTime(Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate()) + DAY, rng);
    return next;
  }
  return d.getTime();
}

function fill(template: string, vars: Record<string, string | number>): string {
  return template.replace(/\{(\w+)\}/g, (_, k) => String(vars[k] ?? `{${k}}`));
}

const money = (n: number) => `$${Math.round(n).toLocaleString("en-US")}`;
const ascii = (s: string) => s.normalize("NFD").replace(/[̀-ͯ]/g, "").toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/(^-|-$)/g, "");

export class Engine {
  state: EngineState;
  private rng: Rng;
  private writer: Writer;
  private team: TeamMember[];
  /** Live intensity multiplies lead arrivals after the backfill (1 = realistic). */
  intensity = 1;

  constructor(state: EngineState, writer: Writer, team: TeamMember[]) {
    if (team.length === 0) throw new Error("The simulation needs at least one team member");
    this.state = state;
    this.rng = new Rng(state.rngState);
    this.writer = writer;
    this.team = team;
  }

  private count(key: string, n = 1) {
    this.state.stats[key] = (this.state.stats[key] ?? 0) + n;
  }

  private schedule(ev: NewEvent) {
    const e = { ...ev, seq: ++this.state.seq } as Ev;
    // Keep the queue sorted by (at, seq): deterministic processing order.
    const q = this.state.queue;
    let i = q.length;
    while (i > 0 && (q[i - 1].at > e.at || (q[i - 1].at === e.at && q[i - 1].seq > e.seq))) i--;
    q.splice(i, 0, e);
  }

  /** Processes all business events up to `target` (ms). Returns the number of events handled. */
  async advanceTo(target: number, onEvent?: () => Promise<void>): Promise<number> {
    let handled = 0;
    while (true) {
      const nextDay = Math.floor(this.state.clock / DAY) * DAY + DAY;
      const nextEvent = this.state.queue[0]?.at ?? Infinity;
      if (nextEvent <= target && nextEvent < nextDay) {
        const ev = this.state.queue.shift()!;
        this.state.clock = Math.max(this.state.clock, ev.at);
        await this.handle(ev);
        handled++;
        this.state.rngState = this.rng.state;
        if (onEvent) await onEvent();
        continue;
      }
      if (nextDay > target) break;
      // Day boundary: plan the new day's lead arrivals.
      this.state.clock = nextDay;
      this.planLeads(nextDay);
      this.state.rngState = this.rng.state;
    }
    this.state.clock = Math.max(this.state.clock, target);
    this.state.rngState = this.rng.state;
    return handled;
  }

  private planLeads(dayStart: number) {
    if (isWeekend(dayStart)) return;
    const month = new Date(dayStart).getUTCMonth();
    const years = (dayStart - this.state.scenarioStart) / (365 * DAY);
    const lambda = BASE_LEADS_PER_DAY * SEASONALITY[month] * (1 + 0.25 * years) * this.intensity;
    const n = this.rng.poisson(lambda);
    for (let i = 0; i < n; i++) {
      this.schedule({ kind: "lead", at: dayStart + (14 + this.rng.next() * 9) * 3600_000 });
    }
  }

  private async handle(ev: Ev) {
    switch (ev.kind) {
      case "lead":
        return this.onLead(ev.at);
      case "open_deal":
        return this.onOpenDeal(ev.at, ev.ctx, ev.expansion ?? false);
      case "advance_deal":
        return this.onAdvanceDeal(ev.at, ev.ctx);
      case "archive_deal":
        await this.writer.update("deals", ev.ownerId, ev.dealId, { archived_at: iso(ev.at), updated_at: iso(ev.at) });
        return this.count("deals_archived");
      case "complete_task":
        await this.writer.update("tasks", ev.ownerId, ev.taskId, { done_date: iso(ev.at) });
        return this.count("tasks_done");
      case "checkin":
        return this.onCheckin(ev.at, ev.ctx, ev.customer);
    }
  }

  // ---------------------------------------------------------------- helpers
  /** Kanban position (deals.index is smallint): later activity sorts lower in its column. */
  private nextIndex(): number {
    this.state.dealIndex = (this.state.dealIndex % 30000) + 1;
    return this.state.dealIndex;
  }

  private ownerFor(region: string): TeamMember {
    const covering = this.team.filter((m) => m.regions.includes(region));
    return this.rng.weighted(covering.length ? covering : this.team, (m) => m.capacity);
  }

  private member(salesId: number): TeamMember {
    return this.team.find((m) => m.salesId === salesId) ?? this.team[0];
  }

  private async ensureTag(name: string): Promise<number> {
    if (this.state.tagIds[name]) return this.state.tagIds[name];
    const tag = catalog.tags.find((t) => t.name === name)!;
    const id = await this.writer.create("tags", this.team[0].salesId, { name: tag.name, color: tag.color });
    this.state.tagIds[name] = id;
    return id;
  }

  /**
   * Distinct, plausible names: the base name (without legal suffix) is unique, and each stem or
   * city is used at most three times while alternatives remain (soft cap, so growth never stalls).
   */
  private companyName(sector: Sector, cityName: string): { name: string; short: string } {
    const suffix = new RegExp(` (${catalog.companySuffixes.map((x) => x.replace(".", "\\.")).join("|")})$`);
    const bases = new Set(this.state.usedNames.map((n) => n.replace(suffix, "")));
    const uses = (short: string) => this.state.usedNames.filter((n) => n.startsWith(`${short} `)).length;
    for (let attempt = 0; attempt < 120; attempt++) {
      const short = this.rng.chance(0.3) ? cityName : this.rng.pick(sector.stems);
      const base = `${short} ${this.rng.pick(sector.kinds)}`;
      if (bases.has(base)) continue;
      if (uses(short) >= 3 && attempt < 90) continue;
      const name = this.rng.chance(0.55) ? base : `${base} ${this.rng.pick(catalog.companySuffixes)}`;
      this.state.usedNames.push(name);
      return { name, short };
    }
    const fallback = `${this.rng.pick(sector.stems)} ${this.rng.pick(sector.kinds)} ${this.state.usedNames.length}`;
    this.state.usedNames.push(fallback);
    return { name: fallback, short: fallback.split(" ")[0] };
  }

  private async addTask(at: number, ownerId: number, contactId: number, stage: keyof typeof catalog.tasks, vars: Record<string, string | number>) {
    const [type, text] = this.rng.pick(catalog.tasks[stage]);
    const due = businessTime(at + this.rng.int(1, 6) * DAY, this.rng);
    const id = await this.writer.create("tasks", ownerId, {
      contact_id: contactId, type, text: fill(text, vars), due_date: iso(due), created_at: iso(at), sales_id: ownerId,
    });
    this.count("tasks");
    // Most tasks get done around their due date; some slip and stay open (realistic overdue list).
    if (this.rng.chance(0.88)) {
      this.schedule({ kind: "complete_task", at: businessTime(due + (this.rng.next() * 3 - 1) * DAY, this.rng), taskId: id, ownerId });
    }
  }

  private async contactNote(at: number, ownerId: number, contactId: number, text: string, status: string) {
    await this.writer.create("contact_notes", ownerId, { contact_id: contactId, text, date: iso(at), status, sales_id: ownerId });
    await this.writer.update("contacts", ownerId, contactId, { last_seen: iso(at), status });
    this.count("contact_notes");
  }

  // ---------------------------------------------------------------- events
  private async onLead(at: number) {
    const rng = this.rng;
    const sector = rng.weighted(catalog.sectors, (s) => s.weight);
    const city = rng.pick(catalog.cities);
    const owner = this.ownerFor(city.region);
    const size = rng.weighted(catalog.sizeWeights, (s) => s.weight);
    const { name, short } = this.companyName(sector, city.city);
    const slug = ascii(name.replace(/ (Inc\.|LLC|Co\.|Group|Holdings|Corp\.)$/, ""));
    const source = rng.pick(catalog.leadSources);
    const pain = rng.pick(catalog.painPoints);
    const area = 200 + (Number(city.zip) % 700);

    const companyId = await this.writer.create("companies", owner.salesId, {
      name,
      sector: sector.value,
      size: size.size,
      revenue: size.revenue,
      website: `https://www.${slug}.example`,
      linkedin_url: `https://www.linkedin.com/company/${slug}-example`,
      phone_number: `+1 ${area}-555-01${String(rng.int(0, 99)).padStart(2, "0")}`,
      address: `${rng.int(100, 9800)} ${rng.pick(["Commerce", "Market", "Lake", "Industrial", "Park", "Harbor", "Main"])} ${rng.pick(["St", "Ave", "Blvd", "Way", "Dr"])}`,
      zipcode: `${city.zip}${String(rng.int(0, 99)).padStart(2, "0")}`,
      city: city.city,
      state_abbr: city.state,
      country: "United States",
      description: rng.pick(sector.descriptions),
      sales_id: owner.salesId,
      created_at: iso(at),
    });
    this.count("companies");

    const contactCount = { 10: [1, 2], 50: [1, 3], 250: [2, 4], 500: [2, 5] }[size.size as 10 | 50 | 250 | 500]!;
    const contactIds: number[] = [];
    let leadFirst = "";
    let leadDecision = false;
    let leadTags: number[] = [];
    const taken = new Set<string>();
    for (let i = 0, n = rng.int(contactCount[0], contactCount[1]); i < n; i++) {
      const [first, gender] = rng.pick(catalog.firstNames);
      const last = rng.pick(catalog.lastNames);
      if (taken.has(`${first} ${last}`)) continue;
      taken.add(`${first} ${last}`);
      const title = i === 0 ? rng.pick(catalog.titles.filter((t) => t.level >= 1)) : rng.pick(catalog.titles);
      const tags: number[] = [];
      if (title.decision) tags.push(await this.ensureTag(title.level >= 3 ? "Budget holder" : "Decision maker"));
      if (i === 0 && source === "Partner referral") tags.push(await this.ensureTag("Partner referral"));
      if (i === 0 && (source === "Trade show" || source === "Webinar attendee")) tags.push(await this.ensureTag("Event lead"));
      if (title.title.includes("IT") || title.title.includes("Information") || title.title.includes("Data")) tags.push(await this.ensureTag("Technical buyer"));
      const seen = at;
      const id = await this.writer.create("contacts", owner.salesId, {
        first_name: first,
        last_name: last,
        gender,
        title: title.title,
        company_id: companyId,
        email_jsonb: [{ email: `${ascii(first)}.${ascii(last)}@${slug}.example`, type: "Work" }],
        phone_jsonb: [{ number: `+1 ${area}-555-01${String(rng.int(0, 99)).padStart(2, "0")}`, type: "Work" }],
        background: i === 0 ? `${source}. Main challenge: ${pain}.` : `${title.title} at ${short}.`,
        first_seen: iso(seen),
        last_seen: iso(seen),
        has_newsletter: rng.chance(0.4),
        status: "cold",
        tags,
        linkedin_url: `https://www.linkedin.com/in/${ascii(first)}-${ascii(last)}-example`,
        sales_id: owner.salesId,
      });
      contactIds.push(id);
      this.count("contacts");
      if (i === 0) {
        leadTags = tags;
        leadFirst = first;
        leadDecision = title.decision;
      }
    }

    const vars = { first: leadFirst, source, source_lower: source.toLowerCase(), pain };
    await this.contactNote(at, owner.salesId, contactIds[0], fill(rng.pick(catalog.notes.lead), vars), rng.chance(0.6) ? "warm" : "cold");
    await this.addTask(at, owner.salesId, contactIds[0], "lead", vars);

    const ctx = {
      companyId, contactIds, leadContactId: contactIds[0], first: leadFirst, short, ownerId: owner.salesId,
      sector: sector.value, pain, sizeFactor: size.amountFactor, leadTags,
    };
    const qualify = 0.5 + (leadDecision ? 0.12 : 0) + (source.includes("referral") ? 0.1 : 0);
    if (rng.chance(qualify)) {
      this.schedule({ kind: "open_deal", at: businessTime(at + rng.int(3, 18) * DAY, rng), ctx });
    } else if (rng.chance(0.35)) {
      this.schedule({ kind: "checkin", at: businessTime(at + rng.int(40, 120) * DAY, rng), ctx, customer: false });
    }
  }

  private pickCategory(expansion: boolean): Category {
    const pool = expansion ? catalog.dealCategories.filter((c) => c.base <= 30000) : catalog.dealCategories;
    return this.rng.weighted(pool, (c) => c.weight);
  }

  private async onOpenDeal(at: number, base: Omit<DealCtx, "dealId" | "category" | "amount" | "stage">, expansion: boolean) {
    const rng = this.rng;
    const category = this.pickCategory(expansion);
    const amount = Math.max(2500, Math.round(rng.lognormal(category.base * base.sizeFactor, category.spread) / 500) * 500);
    const name = fill(rng.pick(catalog.dealNames), { category: category.label, phase: rng.int(1, 3) });
    const contactIds = base.contactIds.slice(0, rng.int(1, Math.min(3, base.contactIds.length)));
    const closing = at + Math.round(category.cycleDays * rng.lognormal(1, 0.25)) * DAY;
    const dealId = await this.writer.create("deals", base.ownerId, {
      name,
      company_id: base.companyId,
      contact_ids: contactIds,
      categories: [category.value],
      stage: "opportunity",
      description: `${category.label} to address ${base.pain}.`,
      amount,
      expected_closing_date: dateOnly(closing),
      sales_id: base.ownerId,
      index: this.nextIndex(),
      created_at: iso(at),
      updated_at: iso(at),
    });
    this.count(expansion ? "expansion_deals" : "deals");
    const ctx: DealCtx = { ...base, contactIds, dealId, category: category.value, amount, stage: "opportunity" };
    const vars = { first: base.first, category_lower: category.label.toLowerCase(), pain: base.pain };
    await this.writer.create("deal_notes", base.ownerId, {
      deal_id: dealId, type: "Meeting", text: fill(rng.pick(catalog.notes.discovery), vars), date: iso(at), sales_id: base.ownerId,
    });
    this.count("deal_notes");
    await this.addTask(at, base.ownerId, base.leadContactId, "discovery", vars);
    this.scheduleAdvance(at, ctx, category);
  }

  private scheduleAdvance(at: number, ctx: DealCtx, category = catalog.dealCategories.find((c) => c.value === ctx.category)!) {
    const share = { opportunity: 0.3, "proposal-sent": 0.3, "in-negociation": 0.4, delayed: 1.2 }[ctx.stage] ?? 0.3;
    const days = Math.max(2, Math.round(category.cycleDays * share * this.rng.lognormal(1, 0.35)));
    this.schedule({ kind: "advance_deal", at: businessTime(at + days * DAY, this.rng), ctx });
  }

  private async onAdvanceDeal(at: number, ctx: DealCtx) {
    const rng = this.rng;
    const skill = this.member(ctx.ownerId).skill;
    const month = new Date(at).getUTCMonth();
    const quarterEnd = month % 3 === 2 ? 0.06 : 0; // end-of-quarter push
    let next: string;
    switch (ctx.stage) {
      case "opportunity":
        next = rng.chance(0.6 * skill) ? "proposal-sent" : rng.chance(0.65) ? "lost" : "delayed";
        break;
      case "proposal-sent":
        next = rng.chance(0.58 * skill + quarterEnd) ? "in-negociation" : rng.chance(0.7) ? "lost" : "delayed";
        break;
      case "in-negociation":
        next = rng.chance(Math.min(0.85, 0.6 * skill + quarterEnd)) ? "won" : rng.chance(0.8) ? "lost" : "delayed";
        break;
      case "delayed":
        next = rng.chance(0.45) ? (ctx.prevStage ?? "opportunity") : "lost";
        break;
      default:
        return;
    }

    const vars = {
      first: ctx.first,
      category_lower: (catalog.dealCategories.find((c) => c.value === ctx.category)?.label ?? ctx.category).toLowerCase(),
      category: catalog.dealCategories.find((c) => c.value === ctx.category)?.label ?? ctx.category,
      amount: money(ctx.amount),
      weeks: rng.int(2, 6),
      reason: rng.pick(catalog.lossReasons),
      delay: rng.pick(catalog.delayReasons),
      pain: ctx.pain,
    };
    // Price moves during the cycle: proposals are re-scoped, negotiation trims discounts.
    if (next === "in-negociation") ctx.amount = Math.round((ctx.amount * (0.9 + rng.next() * 0.2)) / 500) * 500;
    if (next === "won") ctx.amount = Math.round((ctx.amount * (0.92 + rng.next() * 0.08)) / 500) * 500;
    vars.amount = money(ctx.amount);

    const update: Record<string, unknown> = { stage: next, amount: ctx.amount, updated_at: iso(at), index: this.nextIndex() };
    if (next === "won" || next === "lost") update.expected_closing_date = dateOnly(at);
    await this.writer.update("deals", ctx.ownerId, ctx.dealId, update);

    const noteKind = next === "proposal-sent" ? "proposal" : next === "in-negociation" ? "negotiation" : (next as "won" | "lost" | "delayed");
    const notes = (catalog.notes as Record<string, string[]>)[noteKind] ?? catalog.notes.discovery;
    await this.writer.create("deal_notes", ctx.ownerId, {
      deal_id: ctx.dealId, type: next === "won" ? "Signed" : "Note", text: fill(rng.pick(notes), vars), date: iso(at), sales_id: ctx.ownerId,
    });
    this.count("deal_notes");
    this.count(`stage_${next}`);

    const prev = ctx.stage;
    ctx.prevStage = prev === "delayed" ? ctx.prevStage : prev;
    ctx.stage = next;

    if (next === "won") {
      this.count("won_amount", ctx.amount);
      await this.contactNote(at, ctx.ownerId, ctx.leadContactId, fill(rng.pick(catalog.notes.won), vars), "in-contract");
      await this.addTask(at, ctx.ownerId, ctx.leadContactId, "won", vars);
      if (rng.chance(0.5)) {
        const champion = await this.ensureTag("Champion");
        if (!ctx.leadTags.includes(champion)) ctx.leadTags = [...ctx.leadTags, champion];
        await this.writer.update("contacts", ctx.ownerId, ctx.leadContactId, { tags: ctx.leadTags });
      }
      this.schedule({ kind: "archive_deal", at: businessTime(at + rng.int(20, 45) * DAY, rng), dealId: ctx.dealId, ownerId: ctx.ownerId });
      this.schedule({ kind: "checkin", at: businessTime(at + rng.int(60, 120) * DAY, rng), ctx: this.baseOf(ctx), customer: true });
    } else if (next === "lost") {
      this.schedule({ kind: "archive_deal", at: businessTime(at + rng.int(10, 30) * DAY, rng), dealId: ctx.dealId, ownerId: ctx.ownerId });
      if (rng.chance(0.3)) this.schedule({ kind: "checkin", at: businessTime(at + rng.int(120, 200) * DAY, rng), ctx: this.baseOf(ctx), customer: false });
    } else {
      if (next === "proposal-sent" || next === "in-negociation") {
        await this.addTask(at, ctx.ownerId, ctx.leadContactId, next === "proposal-sent" ? "proposal" : "negotiation", vars);
        if (rng.chance(0.5)) await this.contactNote(at, ctx.ownerId, ctx.leadContactId, fill(rng.pick(notes), vars), "hot");
      }
      this.scheduleAdvance(at, ctx);
    }
  }

  private baseOf(ctx: DealCtx) {
    const { companyId, contactIds, leadContactId, first, short, ownerId, sector, pain, sizeFactor, leadTags } = ctx;
    return { companyId, contactIds, leadContactId, first, short, ownerId, sector, pain, sizeFactor, leadTags };
  }

  private async onCheckin(at: number, ctx: Omit<DealCtx, "dealId" | "category" | "amount" | "stage">, customer: boolean) {
    const vars = { first: ctx.first, pain: ctx.pain };
    await this.contactNote(at, ctx.ownerId, ctx.leadContactId, fill(this.rng.pick(catalog.notes.checkin), vars), customer ? "in-contract" : "warm");
    await this.addTask(at, ctx.ownerId, ctx.leadContactId, "checkin", vars);
    this.count("checkins");
    if (this.rng.chance(customer ? 0.35 : 0.3)) {
      this.schedule({ kind: "open_deal", at: businessTime(at + this.rng.int(5, 20) * DAY, this.rng), ctx, expansion: customer });
    }
  }
}
