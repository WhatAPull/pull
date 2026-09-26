#!/usr/bin/env node
/**
 * The study beta's dashboard, printed as Markdown from the operators' views
 * (`ops.study_*`, 20260925220000; docs/study-beta.md).
 *
 *   DATABASE_URL=postgresql://... node scripts/study-beta-report.mjs [--days 14] [--weeks 8]
 *
 * Every figure is an aggregate, and every rate is printed with its numerator and denominator
 * (docs/eval/study-quality.md). Nothing here calls a model, and nothing it reads names a
 * reader.
 *
 * On the hosted database this holds the owner's password, so it reads and nothing else: one
 * read-only transaction, one snapshot for every section, in UTC -- said by the statement
 * itself, not by PGOPTIONS: a connection pooler need not pass that on, and a pgbouncer that
 * does not know the startup parameter refuses the connection over it. psql is handed
 * the URL's parsed parts, never the URL; no PG* or PSQL* variable of the operator's reaches
 * it, and neither does their ~/.psqlrc, so nothing it would read on its own can point it
 * elsewhere or change what it prints. No command line or error it prints carries the
 * password. TLS is asked for off loopback, and verified when the URL says
 * `sslmode=verify-full` with an `sslrootcert`.
 */
import { execFileSync } from 'node:child_process';
import { pathToFileURL } from 'node:url';
import { resolve } from 'node:path';

/** A rate with what it is a rate of: "12.5% (1/8)", or "no data (0/0)". */
export function rate(numerator, denominator) {
  const n = Number(numerator) || 0;
  const d = Number(denominator) || 0;
  if (d === 0) return `no data (${n}/${d})`;
  return `${((100 * n) / d).toFixed(1)}% (${n}/${d})`;
}

function table(rows, columns) {
  if (rows.length === 0) return '_Nothing recorded._\n';
  const head = `| ${columns.map((c) => c.label).join(' | ')} |`;
  const rule = `| ${columns.map(() => '---').join(' | ')} |`;
  const body = rows.map((r) => `| ${columns.map((c) => c.value(r)).join(' | ')} |`);
  return [head, rule, ...body].join('\n') + '\n';
}

const blank = (v) => v === '' || v === undefined || v === null;
const cell = (key) => (r) => (blank(r[key]) ? '–' : String(r[key]));
const minutes = (key) => (r) => (blank(r[key]) ? '–' : Number(r[key]).toFixed(1));
const yes = (v) => v === true || v === 't' || v === 'true';
const readers = (n) => `${n} ${Number(n) === 1 ? 'reader' : 'readers'}`;
/** A Postgres array as JSON gives it, or as text: the values, comma-separated. */
const list = (v) =>
  Array.isArray(v)
    ? v.join(', ')
    : String(v ?? '')
        .replace(/^\{|\}$/g, '')
        .split(',')
        .filter(Boolean)
        .join(', ');

/** The dashboard, from the views' rows. Pure, so it can be tested without a database. */
export function renderReport({ status, daily, validation, learning, trust, mix }) {
  if (status.length !== 1) {
    // The switch is one row; without it, "closed" would be a guess.
    throw new Error(`ops.study_beta_status answered ${status.length} rows, not one`);
  }
  const s = status[0];
  const open = yes(s.open_to_all);
  const uncovered = list(s.uncovered);
  // Both stages of the gate's pipeline: what extracts the claims, and what assembles them.
  const stage = (p) => (p ? `${p.model}, prompt ${String(p.promptHash).slice(0, 12)}…` : '–');
  const pipeline = s.gate_pipeline
    ? `extraction ${stage(s.gate_pipeline.extract)}; assembly ${stage(s.gate_pipeline.assemble)}`
    : '–';
  const lines = [];
  lines.push('# Study beta');
  lines.push('');
  if (open) {
    lines.push(
      `**Open to every reader with an account**, since ${s.changed_at} (by ${s.changed_by}), on release gate ${s.gate_id}: a run of ${s.gate_ran_at} (${s.gate_age_days} days ago), pipeline ${pipeline}.`,
    );
    if (yes(s.admission_lapsed)) {
      lines.push('');
      lines.push(
        "**Admission has lapsed**: the gate's run is sixty days old, so only the allowlist is admitted. Record a new gate and open on it, or close.",
      );
    }
    if (Number(s.preparations_off_gate) > 0) {
      lines.push('');
      lines.push(
        `${s.preparations_off_gate} preparations since opening used a pipeline other than the gate's: record a gate for it.`,
      );
    }
  } else {
    lines.push(`**Allowlist only** (${readers(s.allowlisted_readers ?? 0)} admitted).`);
  }
  if (Number(s.queued_for_readers_not_admitted) > 0) {
    lines.push('');
    lines.push(
      `${s.queued_for_readers_not_admitted} courses are still queued for readers no longer admitted; they finish within their shares and the study ceiling.`,
    );
  }
  lines.push('');
  lines.push(
    `Spend today: study ${Number(s.study_spend_today_cents ?? 0).toFixed(2)}¢ of its ${s.study_cap_cents ?? '–'}¢ ceiling, everything else ${Number(s.other_spend_today_cents ?? 0).toFixed(2)}¢; the day's ceiling is ${s.daily_cap_cents ?? '–'}¢ (law 2), open or not.`,
  );
  // What stands between a closed beta and opening; once open, the mix below says the rest.
  if (!open) {
    lines.push('');
    lines.push(
      uncovered
        ? `Not yet covered by the beta (each needs 3 courses from 2 readers): ${uncovered}.`
        : 'Every kind of source and goal is covered.',
    );
  }
  lines.push('');
  lines.push('## Preparation, by day');
  lines.push('');
  lines.push(
    table(daily, [
      { label: 'Day', value: cell('day') },
      { label: 'Courses', value: cell('courses_created') },
      { label: 'Readers', value: cell('readers_creating') },
      { label: 'Jobs', value: cell('jobs') },
      // Of the jobs that have finished: one still in flight has not failed.
      {
        label: 'Succeeded',
        value: (r) => rate(r.succeeded, Number(r.jobs || 0) - Number(r.in_flight || 0)),
      },
      { label: 'Failed', value: cell('failed') },
      { label: 'In flight', value: cell('in_flight') },
      { label: 'Median min', value: minutes('median_minutes') },
      { label: 'p95 min', value: minutes('p95_minutes') },
      { label: 'Spend ¢', value: (r) => Number(r.spend_cents || 0).toFixed(2) },
    ]),
  );
  lines.push('## Validation, by week the course was prepared');
  lines.push('');
  const passed = (ok, held) => rate(ok, Number(ok || 0) + Number(held || 0));
  lines.push(
    table(validation, [
      { label: 'Week', value: cell('week') },
      { label: 'Preparations', value: cell('generations') },
      { label: 'Held back', value: cell('held_back') },
      { label: 'Awaiting', value: cell('awaiting_validation') },
      { label: 'Claims passed', value: (r) => passed(r.claims_validated, r.claims_quarantined) },
      { label: 'Lessons passed', value: (r) => passed(r.lessons_validated, r.lessons_quarantined) },
      {
        label: 'Questions passed',
        value: (r) => passed(r.questions_validated, r.questions_quarantined),
      },
    ]),
  );
  lines.push('## Learning, by week answered');
  lines.push('');
  lines.push(
    'Deterministic answers to model-written questions only. Seven-day recall: right and unhinted at least seven days after a right, unhinted answer to the same question, with no answer between. False mastery: an unhinted answer, wrong when the course counted every claim the question tests as known.',
  );
  lines.push('');
  lines.push(
    table(learning, [
      { label: 'Week', value: cell('week') },
      { label: 'Answers', value: cell('answers') },
      { label: 'Readers', value: cell('readers') },
      { label: 'Seven-day recall', value: (r) => rate(r.delayed_recalled, r.delayed_attempts) },
      { label: 'False mastery', value: (r) => rate(r.wrong_when_known, r.answers_when_known) },
    ]),
  );
  lines.push('## Reading and trust, by week');
  lines.push('');
  lines.push(
    table(trust, [
      { label: 'Week', value: cell('week') },
      { label: 'Lessons shown', value: cell('lessons_shown') },
      { label: 'Read', value: (r) => rate(r.lessons_read, r.lessons_shown) },
      { label: 'Skipped', value: cell('lessons_skipped') },
      // Each kind of report over what it could be about: a lesson's over lessons shown, a
      // question's over questions shown. A claim is shown inside a lesson, so its reports are
      // a count.
      { label: 'Lesson reports', value: (r) => rate(r.lesson_reports, r.lessons_shown) },
      { label: 'Questions shown', value: cell('questions_shown') },
      { label: 'Question reports', value: (r) => rate(r.question_reports, r.questions_shown) },
      { label: 'Claim reports', value: cell('claim_reports') },
      { label: 'Restored', value: cell('reports_restored') },
      { label: 'Corrected', value: cell('corrected') },
      { label: 'Withdrawn', value: cell('withdrawn') },
    ]),
  );
  lines.push('## Mix: courses by kind of source and goal');
  lines.push('');
  lines.push(
    table(mix, [
      { label: 'Kind', value: cell('dimension') },
      { label: 'Value', value: cell('value') },
      { label: 'Courses', value: cell('courses') },
      { label: 'Readers', value: cell('readers') },
    ]),
  );
  return lines.join('\n');
}

const SSL_MODES = ['disable', 'allow', 'prefer', 'require', 'verify-ca', 'verify-full'];

/**
 * How psql is to be run for a URL: its arguments and its environment. Pure, so what it
 * refuses and what it passes on can be tested. The password goes in the environment, never
 * the arguments.
 */
export function connection(url, parent = {}) {
  let target;
  try {
    target = new URL(url);
  } catch {
    throw new Error('DATABASE_URL is not a URL');
  }
  const simple = /^[A-Za-z0-9_.-]+$/;
  const database = decodeURIComponent(target.pathname.slice(1));
  const user = decodeURIComponent(target.username);
  if (!/^postgres(ql)?:$/.test(target.protocol) || !simple.test(database) || !simple.test(user)) {
    throw new Error(`refusing ${target.protocol}//${target.host}${target.pathname}`);
  }
  const host = target.hostname.replace(/^\[(.*)\]$/, '$1');
  const env = Object.fromEntries(
    Object.entries(parent).filter(([k]) => !k.startsWith('PG') && !k.startsWith('PSQL')),
  );
  env.PGPASSWORD = decodeURIComponent(target.password);
  const loopback = ['127.0.0.1', 'localhost', '::1'].includes(host);
  const sslmode = target.searchParams.get('sslmode');
  if (sslmode !== null && !SSL_MODES.includes(sslmode)) {
    throw new Error(`sslmode ${sslmode} is not one libpq knows`);
  }
  if (sslmode !== null) env.PGSSLMODE = sslmode;
  else if (!loopback) env.PGSSLMODE = 'require';
  const rootcert = target.searchParams.get('sslrootcert');
  if (rootcert !== null) env.PGSSLROOTCERT = rootcert;
  const args = ['-X', '-w', '-h', host, '-p', target.port || '5432', '-U', user, '-d', database];
  return { args, env };
}

/** The flags, all of them known, each a whole number from 1 to 366. */
export function flags(argv) {
  const out = { days: 14, weeks: 8 };
  for (let i = 0; i < argv.length; i += 1) {
    const [name, inline] = argv[i].split('=', 2);
    if (name !== '--days' && name !== '--weeks') throw new Error(`unknown argument ${argv[i]}`);
    const raw = inline ?? argv[(i += 1)];
    const value = Number(raw);
    if (!Number.isInteger(value) || value < 1 || value > 366) {
      throw new Error(`${name} takes a whole number from 1 to 366`);
    }
    out[name.slice(2)] = value;
  }
  return out;
}

/*
 * Every column of ops.study_beta_status but `uncovered`: the view would work that out from a
 * reading of the mix of its own, and the mix costs a lookup of every course's current
 * generation.
 */
const STATUS_COLUMNS = [
  'open_to_all',
  'changed_at',
  'changed_by',
  'gate_id',
  'gate_ran_at',
  'gate_age_days',
  'gate_passed',
  'gate_pipeline',
  'admission_lapsed',
  'preparations_off_gate',
  'queued_for_readers_not_admitted',
  'allowlisted_readers',
  'study_spend_today_cents',
  'study_cap_cents',
  'other_spend_today_cents',
  'daily_cap_cents',
];

/**
 * Every section in one query, so one snapshot, in a read-only transaction in UTC: rows as
 * JSON. The mix is read once, and what it leaves uncovered is worked out from that reading,
 * only while the beta is closed.
 */
export function reportQuery({ days, weeks }) {
  const recent = (view, column, n) =>
    `(select coalesce(json_agg(v order by v.${column} desc), '[]') from ops.${view} v
      where v.${column} >= (now() - interval '${n} days')::date)`;
  return `begin read only;
set local time zone 'UTC';
with mix as materialized (select m.* from ops.study_beta_mix m)
select json_build_object(
    'status', (select coalesce(json_agg(s), '[]') from (
      select ${STATUS_COLUMNS.map((c) => `v.${c}`).join(', ')},
             case when not v.open_to_all then public.study_beta_unrepresented(
               (select coalesce(jsonb_agg(m), '[]') from mix m)) end as uncovered
      from ops.study_beta_status v) s),
    'daily', ${recent('study_daily', 'day', days)},
    'validation', ${recent('study_validation_weekly', 'week', weeks * 7)},
    'learning', ${recent('study_learning_weekly', 'week', weeks * 7)},
    'trust', ${recent('study_trust_weekly', 'week', weeks * 7)},
    'mix', (select coalesce(json_agg(m order by m.dimension, m.value), '[]') from mix m));
commit;`;
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  let options;
  let psql;
  try {
    options = flags(process.argv.slice(2));
    psql = connection(
      process.env.DATABASE_URL ?? 'postgresql://postgres:postgres@127.0.0.1:54322/postgres',
      process.env,
    );
  } catch (e) {
    process.stderr.write(`study-beta-report: ${e.message}\n`);
    process.exit(2);
  }
  let out;
  try {
    out = execFileSync('psql', [...psql.args, '-v', 'ON_ERROR_STOP=1', '-q', '-A', '-t'], {
      encoding: 'utf8',
      maxBuffer: 64 * 1024 * 1024,
      env: psql.env,
      input: reportQuery(options),
      stdio: ['pipe', 'pipe', 'pipe'],
    });
  } catch (e) {
    const said = String(e.stderr ?? e.message)
      .trim()
      .split('\n')[0];
    process.stderr.write(
      `study-beta-report: the database refused or could not be reached: ${said}\n`,
    );
    process.exit(3);
  }
  try {
    process.stdout.write(renderReport(JSON.parse(out)) + '\n');
  } catch (e) {
    process.stderr.write(`study-beta-report: ${e.message}\n`);
    process.exit(4);
  }
}
