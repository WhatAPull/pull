#!/usr/bin/env node
/**
 * Two saves of one reader's flashcard sets, in two sessions at once: the second waits for the
 * first, and is then counted with it.
 *
 * `save_flashcard_set` takes a lock per reader before it counts anything, so no limit can be
 * raced past by two tabs. `supabase/tests/flashcards.sql` proves the lock is held -- but a file
 * is one session, and one session cannot race itself: with the lock moved to just before the
 * function returns, that file still passed, and two saves side by side counted the reader's
 * cards each without the other's and committed 21,000 of a 20,000 limit. So this starts two
 * psql sessions. The first saves 1,500 cards to a reader who has 18,000 and holds its
 * transaction open; the second saves 1,500 more to another of their sets, must be seen
 * waiting on the reader's lock, and when the first commits must be refused at the total
 * (`54000 total`) -- counted after the first's cards, not beside them.
 *
 * And an account deleted while a save arrives. The save reads its reader from `auth.users`
 * with a key-share lock: without it, a save beside `delete_my_account`'s last statement read
 * the row the deletion had not yet committed, went on, and failed on its own foreign key as a
 * raw 23503 -- or deadlocked the deletion. So a third session deletes a second reader and holds
 * its transaction open, a fourth saves as that reader, must be seen waiting, and when the
 * deletion commits must be refused as no reader (`28000`).
 *
 * Writes as the owner to make those readers, and as each reader through the function. The
 * readers are deleted at the end, pass or fail, and their sets and cards with them. Runs as
 * part of `pnpm db:test`.
 */
import { execFileSync, spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';

const DB_URL =
  process.env.DATABASE_URL ?? 'postgresql://postgres:postgres@127.0.0.1:54322/postgres';
// Loopback only, as `test-study-fold-parity.mjs` has it: psql is handed the parsed parts, never
// the URL, and no PG* variable but the password, so nothing libpq would read on its own can
// point it elsewhere; and no command line or error it prints carries the password.
const target = (() => {
  try {
    return new URL(DB_URL);
  } catch {
    return null;
  }
})();
const simple = /^[A-Za-z0-9_]+$/;
const database = target ? decodeURIComponent(target.pathname.slice(1)) : '';
const user = target ? decodeURIComponent(target.username) : '';
if (
  !target ||
  !/^postgres(ql)?:$/.test(target.protocol) ||
  !['127.0.0.1', 'localhost'].includes(target.hostname) ||
  !simple.test(database) ||
  !simple.test(user)
) {
  const shown = target ? `${target.protocol}//${target.host}${target.pathname}` : 'that URL';
  throw new Error(
    `refusing to run against ${shown}: this test writes, and belongs on the local stack`,
  );
}
const connection = ['-h', target.hostname, '-p', target.port || '5432', '-U', user, '-d', database];
const env = Object.fromEntries(Object.entries(process.env).filter(([k]) => !k.startsWith('PG')));
env.PGPASSWORD = decodeURIComponent(target.password);

function psql(sql) {
  return execFileSync('psql', [...connection, '-v', 'ON_ERROR_STOP=1', '-Atq', '-c', sql], {
    encoding: 'utf8',
    env,
  }).trim();
}

/** A psql session of its own, running `sql` from its stdin; resolves with all it printed. */
function session(sql) {
  return new Promise((resolve, reject) => {
    const child = spawn('psql', [...connection, '-v', 'ON_ERROR_STOP=1', '-Atq', '-f', '-'], {
      env,
    });
    let out = '';
    child.stdout.on('data', (d) => (out += d));
    child.stderr.on('data', (d) => (out += d));
    child.on('error', reject);
    child.on('close', (code) => resolve({ code, out }));
    child.stdin.end(sql);
  });
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/** Polls `sql` until it answers `t`, or fails saying what it waited for. */
async function until(sql, what) {
  for (let i = 0; i < 200; i += 1) {
    if (psql(sql) === 't') return;
    await sleep(100);
  }
  throw new Error(`flashcards lock: gave up waiting for ${what}`);
}

const reader = randomUUID();
const first = randomUUID();
const second = randomUUID();
const lockKey = `pg_catalog.hashtextextended('flashcards:${reader}', 0)`;
const lockIs = (granted) => `
  select exists (
    select 1 from pg_locks l
    where l.locktype = 'advisory' and l.objsubid = 1 and l.granted = ${granted}
      and ((l.classid::bigint << 32) | l.objid::bigint) = ${lockKey})`;
const as = (who) => `
  select set_config('role', 'authenticated', true) is not null,
         set_config('request.jwt.claims',
                    '{"sub":"${who}","role":"authenticated"}', true) is not null;`;
const asReader = as(reader);
const makeReader = (who) => `
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                          created_at, updated_at, is_anonymous,
                          raw_app_meta_data, raw_user_meta_data)
  values ('${who}', '00000000-0000-0000-0000-000000000000', 'authenticated',
          'authenticated', 'flashcards-lock-${who.slice(0, 8)}@example.test', '',
          now(), now(), false, '{"provider":"email","providers":["email"]}', '{}');`;
/** Whether another session is running a statement that carries `marker`, and how. */
const seen = (marker, how) => `
  select exists (
    select 1 from pg_stat_activity
    where pid <> pg_backend_pid() and query like '%${marker}%' and ${how})`;
const leaving = randomUUID();
const cards = `(select jsonb_agg(jsonb_build_object('term', 't' || i, 'definition', 'd'))
                from generate_series(1, 1500) i)`;

const failures = [];
try {
  // A reader with 18,000 cards across nine sets: room for 2,000 more, so one save of 1,500
  // fits and a second does not -- but only when it is counted after the first.
  psql(`
    ${makeReader(reader)}
    insert into public.flashcard_sets (id, owner_id, title)
    select extensions.gen_random_uuid(), '${reader}', 'Filler ' || k from generate_series(1, 9) k;
    insert into public.flashcards (set_id, owner_id, position, term, definition)
    select s.id, s.owner_id, i, 't' || i, 'd' from public.flashcard_sets s,
           generate_series(0, 1999) i
    where s.owner_id = '${reader}';`);

  const one = session(`
    begin;
    ${asReader}
    select 'first:' || jsonb_array_length(public.save_flashcard_set(jsonb_build_object(
      'id', '${first}', 'title', 'First', 'cards', ${cards})) -> 'cards');
    select pg_sleep(3);
    commit;`);
  await until(lockIs(true), 'the first save to take the reader’s lock');

  const two = session(`
    begin;
    ${asReader}
    do $race$
    declare
      v_state  text;
      v_detail text;
    begin
      perform public.save_flashcard_set(jsonb_build_object(
        'id', '${second}', 'title', 'Second', 'cards', ${cards}));
      raise notice 'second:ok';
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate, v_detail = pg_exception_detail;
      raise notice 'second:%/%', v_state, v_detail;
    end $race$;
    commit;`);
  // Seen waiting while the first still holds the lock -- not merely finishing after it.
  await until(lockIs(false), 'the second save to wait on the reader’s lock');

  const [a, b] = await Promise.all([one, two]);
  if (a.code !== 0 || !/^first:1500$/m.test(a.out)) {
    failures.push(`the first save did not save its 1,500 cards:\n${a.out}`);
  }
  const said = /second:(\S+)/.exec(b.out)?.[1];
  if (b.code !== 0 || said !== '54000/total') {
    failures.push(
      `the second save, counted after the first, was not refused at the total: ${said ?? b.out}`,
    );
  }
  const held = Number(psql(`select count(*) from public.flashcards where owner_id = '${reader}'`));
  if (held !== 19500) failures.push(`the reader holds ${held} cards, not 19,500`);

  // The account deleted, and not yet committed, as a save arrives.
  psql(makeReader(leaving));
  const tag = leaving.slice(0, 8);
  const deletion = session(`
    begin;
    delete from auth.users where id = '${leaving}';
    select pg_sleep(4) /* deleting-${tag} */;
    commit;`);
  await until(seen(`deleting-${tag}`, `state = 'active'`), 'the deletion to hold its row');
  const late = session(`
    begin;
    ${as(leaving)}
    do $late$
    declare
      v_state  text;
      v_detail text;
    begin
      -- saving-${tag}
      perform public.save_flashcard_set(jsonb_build_object(
        'title', 'Late', 'cards', jsonb_build_array(jsonb_build_object('term', 't', 'definition', 'd'))));
      raise notice 'late:ok';
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate, v_detail = pg_exception_detail;
      raise notice 'late:%/%', v_state, v_detail;
    end $late$;
    commit;`);
  await until(seen(`saving-${tag}`, `wait_event_type = 'Lock'`), 'the save to wait on the account');
  const [d, l] = await Promise.all([deletion, late]);
  if (d.code !== 0) failures.push(`the account deletion failed:\n${d.out}`);
  const answered = /late:(\S+)/.exec(l.out)?.[1];
  if (l.code !== 0 || answered !== '28000/') {
    failures.push(
      `a save that waited on its account's deletion was not refused as no reader: ${answered ?? l.out}`,
    );
  }
} finally {
  psql(`delete from auth.users where id in ('${reader}', '${leaving}')`);
}

if (failures.length > 0) {
  console.error(`flashcards lock: ${failures.length} failures`);
  for (const f of failures) console.error(`  ${f}`);
  process.exit(1);
}
console.log(
  'flashcards lock: ok (the second save waited, and was counted after the first; a save beside its account’s deletion waited, and was no reader)',
);
