import assert from 'node:assert/strict';
import { test } from 'node:test';
import { connection, flags, rate, renderReport, reportQuery } from './study-beta-report.mjs';

const closed = {
  open_to_all: false,
  allowlisted_readers: 12,
  uncovered: ['format:scanned', 'goal:assess'],
  study_spend_today_cents: 12.5,
  study_cap_cents: 100,
  other_spend_today_cents: 3,
  daily_cap_cents: 200,
  queued_for_readers_not_admitted: 0,
};
const open = {
  ...closed,
  open_to_all: true,
  changed_at: '2026-09-20T10:00:00+00:00',
  changed_by: 'An operator',
  gate_id: 'g1',
  gate_ran_at: '2026-09-19T08:00:00+00:00',
  gate_age_days: 7,
  gate_pipeline: {
    extract: { model: 'gemini', promptHash: 'c'.repeat(64), schemaHash: 'd'.repeat(64) },
    assemble: { model: 'gemini', promptHash: 'a'.repeat(64), schemaHash: 'b'.repeat(64) },
  },
  admission_lapsed: false,
  preparations_off_gate: 0,
  // Worked out only while the beta is closed.
  uncovered: null,
};
const empty = { daily: [], validation: [], learning: [], trust: [], mix: [] };

test('a rate always says what it is a rate of', () => {
  assert.equal(rate(1, 8), '12.5% (1/8)');
  assert.equal(rate(0, 0), 'no data (0/0)');
  assert.equal(rate('3', '4'), '75.0% (3/4)');
});

test('renders a closed beta, saying what it has not covered, and every section', () => {
  const md = renderReport({
    status: [closed],
    daily: [
      {
        day: '2026-09-25',
        courses_created: 3,
        readers_creating: 2,
        jobs: 5,
        succeeded: 3,
        failed: 1,
        in_flight: 1,
        median_minutes: 2.25,
        p95_minutes: null,
        spend_cents: 14.5,
      },
    ],
    validation: [
      {
        week: '2026-09-21',
        generations: 4,
        held_back: 1,
        awaiting_validation: 0,
        claims_validated: 9,
        claims_quarantined: 1,
        lessons_validated: 3,
        lessons_quarantined: 1,
        questions_validated: 8,
        questions_quarantined: 2,
      },
    ],
    learning: [
      {
        week: '2026-09-21',
        answers: 40,
        readers: 5,
        delayed_attempts: 8,
        delayed_recalled: 6,
        answers_when_known: 10,
        wrong_when_known: 1,
      },
    ],
    trust: [
      {
        week: '2026-09-21',
        lessons_shown: 20,
        lessons_read: 15,
        lessons_skipped: 2,
        questions_shown: 50,
        lesson_reports: 2,
        question_reports: 5,
        claim_reports: 3,
        reports_restored: 1,
        corrected: 1,
        withdrawn: 0,
      },
    ],
    mix: [{ dimension: 'format', value: 'typed', courses: 3, readers: 2 }],
  });
  assert.match(md, /\*\*Allowlist only\*\* \(12 readers admitted\)/);
  assert.match(md, /Not yet covered .*: format:scanned, goal:assess\./);
  assert.match(md, /study 12\.50¢ of its 100¢ ceiling, everything else 3\.00¢/);
  // Succeeded of the jobs finished, not of those still in flight.
  assert.match(
    md,
    /\| 2026-09-25 \| 3 \| 2 \| 5 \| 75\.0% \(3\/4\) \| 1 \| 1 \| 2\.3 \| – \| 14\.50 \|/,
  );
  assert.match(
    md,
    /\| 2026-09-21 \| 4 \| 1 \| 0 \| 90\.0% \(9\/10\) \| 75\.0% \(3\/4\) \| 80\.0% \(8\/10\) \|/,
  );
  assert.match(md, /75\.0% \(6\/8\) \| 10\.0% \(1\/10\)/);
  // Each kind of report over what it could be about; claims as a count.
  assert.match(
    md,
    /\| 2026-09-21 \| 20 \| 75\.0% \(15\/20\) \| 2 \| 10\.0% \(2\/20\) \| 50 \| 10\.0% \(5\/50\) \| 3 \| 1 \| 1 \| 0 \|/,
  );
  assert.match(md, /\| format \| typed \| 3 \| 2 \|/);
  assert.match(
    renderReport({ status: [{ ...closed, allowlisted_readers: 1 }], ...empty }),
    /\(1 reader admitted\)/,
  );
  assert.match(
    renderReport({ status: [{ ...closed, uncovered: [] }], ...empty }),
    /Every kind of source and goal is covered\./,
  );
});

test('says of a closed beta that courses are still queued for readers it no longer admits', () => {
  assert.doesNotMatch(renderReport({ status: [closed], ...empty }), /still queued/);
  assert.match(
    renderReport({ status: [{ ...closed, queued_for_readers_not_admitted: 2 }], ...empty }),
    /2 courses are still queued for readers no longer admitted/,
  );
});

test('renders an open beta: its gate, its run, and what has lapsed or drifted', () => {
  const md = renderReport({ status: [open], ...empty });
  assert.match(
    md,
    /\*\*Open to every reader with an account\*\*, since 2026-09-20T10:00:00\+00:00 \(by An operator\), on release gate g1: a run of 2026-09-19T08:00:00\+00:00 \(7 days ago\), pipeline extraction gemini, prompt cccccccccccc…; assembly gemini, prompt aaaaaaaaaaaa…\./,
  );
  // Open, the coverage that stood between the beta and opening is not said again.
  assert.doesNotMatch(md, /covered/);
  assert.doesNotMatch(md, /lapsed|other than the gate/);
  const drifted = renderReport({
    status: [
      {
        ...open,
        admission_lapsed: true,
        preparations_off_gate: 2,
        queued_for_readers_not_admitted: 1,
      },
    ],
    ...empty,
  });
  assert.match(drifted, /\*\*Admission has lapsed\*\*/);
  assert.match(drifted, /2 preparations since opening used a pipeline other than the gate's/);
  assert.match(drifted, /1 courses are still queued for readers no longer admitted/);
});

test('refuses to guess the switch without its one row', () => {
  assert.throws(() => renderReport({ status: [], ...empty }), /answered 0 rows/);
});

test('connects read-only, in UTC, past the operator’s psqlrc, with TLS off loopback', () => {
  const parent = { PGHOST: 'elsewhere', PSQLRC: '/tmp/rc', PGPASSFILE: '/tmp/p', HOME: '/h' };
  const local = connection('postgresql://postgres:pw@127.0.0.1:54322/postgres', parent);
  assert.deepEqual(local.args, [
    '-X',
    '-w',
    '-h',
    '127.0.0.1',
    '-p',
    '54322',
    '-U',
    'postgres',
    '-d',
    'postgres',
  ]);
  assert.equal(local.env.PGPASSWORD, 'pw');
  // Not a startup option, which a pooler may refuse: the statement says it (below).
  assert.equal(local.env.PGOPTIONS, undefined);
  assert.equal(local.env.PGHOST, undefined);
  assert.equal(local.env.PSQLRC, undefined);
  assert.equal(local.env.PGPASSFILE, undefined);
  assert.equal(local.env.HOME, '/h');
  assert.equal(local.env.PGSSLMODE, undefined);
  assert.ok(!local.args.join(' ').includes('pw'));
  assert.equal(connection('postgresql://u:p@[::1]:5432/db').args[3], '::1');
  assert.equal(connection('postgresql://u:p@[::1]:5432/db').env.PGSSLMODE, undefined);

  const hosted = connection('postgresql://postgres:s%40cret@db.example.supabase.co:5432/postgres');
  assert.equal(hosted.env.PGSSLMODE, 'require');
  assert.equal(hosted.env.PGPASSWORD, 's@cret');
  const verified = connection(
    'postgresql://postgres:p@db.example.supabase.co:5432/postgres?sslmode=verify-full&sslrootcert=/ca.crt',
  );
  assert.equal(verified.env.PGSSLMODE, 'verify-full');
  assert.equal(verified.env.PGSSLROOTCERT, '/ca.crt');
  assert.throws(() => connection('postgresql://u:p@h/db?sslmode=please'), /not one libpq knows/);
  assert.throws(() => connection('postgresql://u:p@h/db;drop'), /refusing/);
  assert.throws(() => connection('postgresql://bad user:p@h/db'), /refusing/);
  assert.throws(() => connection('mysql://u:p@h/db'), /refusing/);
  assert.throws(() => connection('not a url'), /not a URL/);
});

test('knows its flags, and says so of any other', () => {
  assert.deepEqual(flags([]), { days: 14, weeks: 8 });
  assert.deepEqual(flags(['--days', '7', '--weeks=2']), { days: 7, weeks: 2 });
  assert.throws(() => flags(['--dys', '3']), /unknown argument --dys/);
  assert.throws(() => flags(['--days', '0']), /whole number/);
  assert.throws(() => flags(['--days', '1.5']), /whole number/);
});

test('reads every section in one statement, one snapshot, read-only and in UTC', () => {
  const sql = reportQuery({ days: 7, weeks: 2 });
  const statements = sql
    .trim()
    .split(';')
    .map((s) => s.trim())
    .filter(Boolean);
  // Said by the statement, not left to PGOPTIONS, which a pooler need not pass on.
  assert.deepEqual(statements.slice(0, 2), ['begin read only', "set local time zone 'UTC'"]);
  assert.equal(statements.at(-1), 'commit');
  assert.equal(statements.length, 4);
  // The mix is read once; the status view's own reading of it for `uncovered` is not asked
  // for, and what is uncovered is worked out from that one reading while the beta is closed.
  assert.equal(sql.match(/ops\.study_beta_mix/g).length, 1);
  assert.doesNotMatch(sql, /v\.uncovered|json_agg\(s\), '\[\]'\) from ops\.study_beta_status/);
  assert.match(
    sql,
    /case when not v\.open_to_all then public\.study_beta_unrepresented\(\s*\(select coalesce\(jsonb_agg\(m\), '\[\]'\) from mix m\)\)/,
  );
  assert.match(sql, /ops\.study_daily v\s+where v\.day >= \(now\(\) - interval '7 days'\)::date/);
  assert.match(
    sql,
    /ops\.study_learning_weekly v\s+where v\.week >= \(now\(\) - interval '14 days'\)::date/,
  );
});
