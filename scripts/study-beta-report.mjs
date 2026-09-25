#!/usr/bin/env node
/**
 * The study beta's dashboard, printed as Markdown from the operators' views
 * (`ops.study_*`, 20260925220000; docs/study-beta.md).
 *
 *   DATABASE_URL=postgresql://... node scripts/study-beta-report.mjs [--days 14] [--weeks 8]
 *
 * Every figure is an aggregate, and every rate is printed with its numerator and denominator
 * (docs/eval/study-quality.md). Nothing here calls a model, and nothing it reads names a
 * reader. psql is handed the connection's parsed parts, never the URL, and no PG* variable
 * but the password, so nothing libpq would read on its own can point it elsewhere and no
 * command line or error it prints carries the password.
 */
import { execFileSync } from 'node:child_process';
import { pathToFileURL } from 'node:url';
import { resolve } from 'node:path';

/** Rows of a `psql --csv` answer, as objects keyed by the header. */
export function parseCsv(text) {
  const records = [];
  let field = '';
  let record = [];
  let quoted = false;
  for (let i = 0; i < text.length; i += 1) {
    const ch = text[i];
    if (quoted) {
      if (ch === '"' && text[i + 1] === '"') {
        field += '"';
        i += 1;
      } else if (ch === '"') {
        quoted = false;
      } else {
        field += ch;
      }
    } else if (ch === '"') {
      quoted = true;
    } else if (ch === ',') {
      record.push(field);
      field = '';
    } else if (ch === '\n' || ch === '\r') {
      if (ch === '\r' && text[i + 1] === '\n') i += 1;
      record.push(field);
      records.push(record);
      record = [];
      field = '';
    } else {
      field += ch;
    }
  }
  if (field !== '' || record.length > 0) {
    record.push(field);
    records.push(record);
  }
  const [header, ...rows] = records.filter((r) => !(r.length === 1 && r[0] === ''));
  if (!header) return [];
  return rows.map((r) => Object.fromEntries(header.map((h, i) => [h, r[i] ?? ''])));
}

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

const cell = (key) => (r) => (r[key] === '' || r[key] === undefined ? '–' : r[key]);
const minutes = (key) => (r) => (r[key] === '' ? '–' : Number(r[key]).toFixed(1));

/** The dashboard, from the views' rows. Pure, so it can be tested without a database. */
export function renderReport({ status, daily, validation, learning, trust, mix }) {
  const s = status[0] ?? {};
  const open = s.open_to_all === 't' || s.open_to_all === 'true';
  const uncovered = (s.uncovered ?? '').replace(/^\{|\}$/g, '');
  const lines = [];
  lines.push('# Study beta');
  lines.push('');
  lines.push(
    open
      ? `**Open to every reader with an account**, since ${s.changed_at} (by ${s.changed_by}), on release gate ${s.gate_id} recorded ${s.gate_recorded_at}.`
      : `**Allowlist only** (${s.allowlisted_readers ?? 0} readers admitted).`,
  );
  lines.push('');
  lines.push(`Daily spend ceiling: ${s.daily_cap_cents ?? '–'}¢ (law 2), open or not.`);
  lines.push('');
  lines.push(
    uncovered
      ? `Not yet covered by the beta (each needs 3 courses from 2 readers): ${uncovered.split(',').join(', ')}.`
      : 'Every kind of source and goal is covered.',
  );
  lines.push('');
  lines.push('## Preparation, by day');
  lines.push('');
  lines.push(
    table(daily, [
      { label: 'Day', value: cell('day') },
      { label: 'Courses', value: cell('courses_created') },
      { label: 'Readers', value: cell('readers_creating') },
      { label: 'Jobs', value: cell('jobs') },
      { label: 'Succeeded', value: (r) => rate(r.succeeded, r.jobs) },
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
    'Deterministic answers to model-written questions only. Seven-day recall: right and unhinted at least seven days after a right, unhinted answer to the same question. False mastery: wrong when the course counted every claim the question tests as known.',
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
      { label: 'Reports', value: (r) => rate(r.reports, r.lessons_shown) },
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

function connect(url) {
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
  const env = Object.fromEntries(Object.entries(process.env).filter(([k]) => !k.startsWith('PG')));
  env.PGPASSWORD = decodeURIComponent(target.password);
  const loopback = ['127.0.0.1', 'localhost'].includes(target.hostname);
  if (!loopback) env.PGSSLMODE = 'require';
  const args = ['-h', target.hostname, '-p', target.port || '5432', '-U', user, '-d', database];
  return (sql) =>
    parseCsv(
      execFileSync('psql', [...args, '-v', 'ON_ERROR_STOP=1', '-q', '--csv'], {
        encoding: 'utf8',
        maxBuffer: 16 * 1024 * 1024,
        env,
        input: sql,
      }),
    );
}

function flag(name, fallback) {
  const at = process.argv.indexOf(name);
  const value = at >= 0 ? Number(process.argv[at + 1]) : fallback;
  if (!Number.isInteger(value) || value < 1 || value > 366) {
    throw new Error(`${name} takes a whole number from 1 to 366`);
  }
  return value;
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const days = flag('--days', 14);
  const weeks = flag('--weeks', 8);
  const query = connect(
    process.env.DATABASE_URL ?? 'postgresql://postgres:postgres@127.0.0.1:54322/postgres',
  );
  const recent = (view, column, unit, n) =>
    query(
      `select * from ops.${view} where ${column} >= (now() - interval '${n} ${unit}')::date order by ${column} desc;`,
    );
  process.stdout.write(
    renderReport({
      status: query('select * from ops.study_beta_status;'),
      daily: recent('study_daily', 'day', 'days', days),
      validation: recent('study_validation_weekly', 'week', 'days', weeks * 7),
      learning: recent('study_learning_weekly', 'week', 'days', weeks * 7),
      trust: recent('study_trust_weekly', 'week', 'days', weeks * 7),
      mix: query('select * from ops.study_beta_mix order by dimension, value;'),
    }) + '\n',
  );
}
