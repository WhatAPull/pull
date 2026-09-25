import assert from 'node:assert/strict';
import { test } from 'node:test';
import { parseCsv, rate, renderReport } from './study-beta-report.mjs';

test('parses psql --csv, quoted fields and arrays included', () => {
  const rows = parseCsv(
    'open_to_all,uncovered,changed_by\nf,"{format:pdf,goal:own}","An ""operator"""\n',
  );
  assert.deepEqual(rows, [
    { open_to_all: 'f', uncovered: '{format:pdf,goal:own}', changed_by: 'An "operator"' },
  ]);
  assert.deepEqual(parseCsv(''), []);
  assert.deepEqual(parseCsv('a,b\r\n1,\r\n'), [{ a: '1', b: '' }]);
});

test('a rate always says what it is a rate of', () => {
  assert.equal(rate(1, 8), '12.5% (1/8)');
  assert.equal(rate(0, 0), 'no data (0/0)');
  assert.equal(rate('3', '4'), '75.0% (3/4)');
});

test('renders the dashboard, saying what the beta has not covered', () => {
  const md = renderReport({
    status: [
      {
        open_to_all: 'f',
        allowlisted_readers: '12',
        uncovered: '{format:scanned,goal:assess}',
        daily_cap_cents: '200',
      },
    ],
    daily: [
      {
        day: '2026-09-25',
        courses_created: '3',
        readers_creating: '2',
        jobs: '4',
        succeeded: '3',
        failed: '1',
        in_flight: '0',
        median_minutes: '2.25',
        p95_minutes: '',
        spend_cents: '14.5',
      },
    ],
    validation: [],
    learning: [
      {
        week: '2026-09-21',
        answers: '40',
        readers: '5',
        delayed_attempts: '8',
        delayed_recalled: '6',
        answers_when_known: '10',
        wrong_when_known: '1',
      },
    ],
    trust: [],
    mix: [{ dimension: 'format', value: 'typed', courses: '3', readers: '2' }],
  });
  assert.match(md, /\*\*Allowlist only\*\* \(12 readers admitted\)/);
  assert.match(md, /Not yet covered .*: format:scanned, goal:assess\./);
  assert.match(
    md,
    /\| 2026-09-25 \| 3 \| 2 \| 4 \| 75\.0% \(3\/4\) \| 1 \| 0 \| 2\.3 \| – \| 14\.50 \|/,
  );
  assert.match(md, /75\.0% \(6\/8\) \| 10\.0% \(1\/10\)/);
  assert.match(md, /## Validation[\s\S]*_Nothing recorded._/);
});
