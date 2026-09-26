-- The broad beta (20260925220000): a release gate computed from the evaluator's report, a
-- flag that opens only on a passing gate, admission through one function, the known-before
-- stamp on each answer, and the operators' views. Reader paths run as `authenticated`.
begin;

create or replace function pg_temp.become_reader(p_uid uuid)
returns void language plpgsql as $fn$
begin
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_uid, 'role', 'authenticated', 'is_anonymous', false)::text, true);
  if current_user <> 'authenticated' then
    raise exception 'RLS assertions must run as authenticated, not %', current_user;
  end if;
end $fn$;

create or replace function pg_temp.become_worker()
returns void language plpgsql as $fn$
begin
  perform set_config('role', 'service_role', true);
  perform set_config('request.jwt.claims', json_build_object('role', 'service_role')::text, true);
end $fn$;

create or replace function pg_temp.as_owner()
returns void language plpgsql as $fn$
begin
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);
end $fn$;

grant execute on function pg_temp.become_reader(uuid) to authenticated, service_role;
grant execute on function pg_temp.become_worker() to authenticated, service_role;
grant execute on function pg_temp.as_owner() to authenticated, service_role;

create or replace function pg_temp.claim(
  p_key text, p_version uuid, p_statement text, p_span text, p_note text
)
returns jsonb language sql as $fn$
  select jsonb_build_object(
    'key', p_key, 'sourceVersionId', p_version, 'kind', 'finding', 'statement', p_statement,
    'status', 'draft',
    'evidence', jsonb_build_array(jsonb_build_object(
      'modelQuote', p_span, 'spanText', p_span, 'start', position(p_span in p_note) - 1,
      'end', position(p_span in p_note) - 1 + char_length(p_span), 'match', 'exact')),
    'provenance', jsonb_build_object('promptHash', repeat('a', 64),
                                      'schemaHash', repeat('b', 64), 'model', 'm'))
$fn$;

create or replace function pg_temp.lesson(p_key text, p_position int, p_claims text[])
returns jsonb language sql as $fn$
  select jsonb_build_object(
    'key', p_key, 'position', p_position, 'unitNo', 1, 'unitTitle', 'Timing',
    'title', 'Lesson ' || p_key, 'objective', 'Explain the contrast.',
    'explanation', 'The result depended on the delay.', 'example', null,
    'recap', 'Timing matters.', 'minutes', 3, 'status', 'draft',
    'claimKeys', to_jsonb(p_claims))
$fn$;

/* A question with every field given, so each kind can be built as it is stored. */
create or replace function pg_temp.q(
  p_key text, p_lesson text, p_kind text, p_prompt text, p_answer text, p_claims text[],
  p_extra jsonb default '{}'::jsonb
)
returns jsonb language sql as $fn$
  select jsonb_build_object(
    'key', p_key, 'lessonKey', p_lesson, 'purpose', 'practice', 'kind', p_kind,
    'prompt', p_prompt, 'answer', p_answer, 'acceptedAnswers', '[]'::jsonb,
    'distractors', '[]'::jsonb, 'cloze', null, 'sequence', '[]'::jsonb,
    'pairs', '[]'::jsonb, 'explanation', 'Because the note says so.', 'difficulty', 1,
    'status', 'draft', 'claimKeys', to_jsonb(p_claims)) || p_extra
$fn$;

grant execute on function pg_temp.claim(text, uuid, text, text, text) to service_role;
grant execute on function pg_temp.lesson(text, int, text[]) to service_role;
grant execute on function pg_temp.q(text, text, text, text, text, text[], jsonb) to service_role;

/* One stage of a pipeline: a prompt, a schema and a model. */
create or replace function pg_temp.stage(p_model text default 'm')
returns jsonb language sql as $fn$
  select jsonb_build_object('promptHash', repeat('a', 64), 'schemaHash', repeat('b', 64),
                            'model', p_model)
$fn$;

/* A time as the evaluation export writes it: UTC, to the microsecond, with a Z. */
create or replace function pg_temp.utc(p_at timestamptz)
returns text language sql as $fn$
  select to_char(p_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')
$fn$;

/*
 * The fixture course on the note's two claims -- two multiple-choice questions and a short
 * answer -- its claims extracted and the course assembled with the given stages: by default
 * the fixture's pipeline, whose two stages use different models.
 */
create or replace function pg_temp.course(
  p_version uuid, p_note text, p_extract jsonb default pg_temp.stage('e'),
  p_assemble jsonb default pg_temp.stage('m')
)
returns jsonb language sql as $fn$
  select jsonb_build_object(
    'course', jsonb_build_object('title', 'Immediate versus delayed',
                                 'objectives', jsonb_build_array('Explain the contrast.')),
    'claims', jsonb_build_array(
      pg_temp.claim('s1c1', p_version, 'At five minutes, restudying beat the recall test.',
                    'the group that restudied remembered more', p_note)
        || jsonb_build_object('provenance', p_extract),
      pg_temp.claim('s1c2', p_version, 'The students read prose.', 'had students read prose',
                    p_note)
        || jsonb_build_object('provenance', p_extract)),
    'lessons', jsonb_build_array(pg_temp.lesson('l1', 1, array['s1c1', 's1c2'])),
    'items', jsonb_build_array(
      pg_temp.q('q1', 'l1', 'multiple_choice', 'Which strategy won at five minutes?',
                'Restudying', array['s1c1'], jsonb_build_object('distractors',
                  jsonb_build_array(
                    jsonb_build_object('text', 'The recall test', 'why', 'Only after a week.'),
                    jsonb_build_object('text', 'Neither', 'why', 'The note reports a winner.')))),
      pg_temp.q('q2', 'l1', 'multiple_choice', 'What did the students read, and what won early?',
                'Prose; restudying', array['s1c1', 's1c2'], jsonb_build_object('distractors',
                  jsonb_build_array(
                    jsonb_build_object('text', 'Poetry; testing', 'why', 'Neither.'),
                    jsonb_build_object('text', 'Prose; testing', 'why', 'Testing won later.')))),
      pg_temp.q('q3', 'l1', 'short_recall', 'Which strategy won at five minutes?',
                'restudying', array['s1c1'])),
    'provenance', p_assemble)
$fn$;

grant execute on function pg_temp.stage(text) to service_role;
grant execute on function pg_temp.utc(timestamptz) to service_role;
grant execute on function pg_temp.course(uuid, text, jsonb, jsonb) to service_role;

/* Record one answer and hand back its result, or its refusal. */
create or replace function pg_temp.answer(
  p_item uuid, p_response jsonb, p_self text default null, p_hinted boolean default null,
  p_client uuid default extensions.gen_random_uuid()
)
returns jsonb language sql as $fn$
  select public.record_study_answers(jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
    'clientEventId', p_client, 'itemId', p_item, 'response', p_response,
    'selfGrade', p_self, 'hinted', p_hinted))))
$fn$;
grant execute on function pg_temp.answer(uuid, jsonb, text, boolean, uuid) to authenticated;

/* Whether the study door admits the reader's course, or refuses it for the day's study budget. */
create or replace function pg_temp.admits(p_version uuid)
returns boolean language plpgsql as $fn$
begin
  perform public.enqueue_study_generation(array[p_version], 'Remember the key findings',
                                          extensions.gen_random_uuid(), true);
  return true;
exception when sqlstate '53400' then
  if sqlerrm not like 'today''s study generation budget is spent%' then raise; end if;
  return false;
end $fn$;
grant execute on function pg_temp.admits(uuid) to authenticated;

/* A reader with an account and one note saved, which is what the door needs. As the owner. */
create or replace function pg_temp.new_reader(p_note text)
returns uuid language plpgsql as $fn$
declare
  r uuid := extensions.gen_random_uuid();
begin
  insert into auth.users
    (id, instance_id, aud, role, email, encrypted_password,
     email_confirmed_at, created_at, updated_at, is_anonymous,
     raw_app_meta_data, raw_user_meta_data)
  values
    (r, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
     'study-beta-' || r || '@example.test', '', now(), now(), now(), false, '{}', '{}');
  perform pg_temp.become_reader(r);
  perform public.save_study_source_version('A note', 'paste', p_note,
                                           extensions.gen_random_uuid());
  perform pg_temp.as_owner();
  return r;
end $fn$;

/* Knock at the study door once as a reader, with their note: whether it admitted a course. */
create or replace function pg_temp.knock(p_reader uuid)
returns boolean language plpgsql as $fn$
declare
  took boolean;
begin
  perform pg_temp.become_reader(p_reader);
  took := pg_temp.admits((select v.id from public.study_source_versions v
                          where v.owner_id = p_reader limit 1));
  perform pg_temp.as_owner();
  return took;
end $fn$;

/* Whether the door would admit a reader's course now: knocked, and undone. */
create or replace function pg_temp.would_admit(p_reader uuid)
returns boolean language plpgsql as $fn$
declare
  took boolean;
begin
  begin
    took := pg_temp.knock(p_reader);
    raise exception using errcode = 'P0001', message = 'probe done';
  exception when raise_exception then
    if sqlerrm is distinct from 'probe done' then raise; end if;
  end;
  return took;
end $fn$;

/*
 * Knock at the study door once as each reader in turn until it refuses, and say how many
 * courses it admitted. One course each, from readers with nothing spent or waiting, so every
 * course is inside its reader's share and counts in full; each answer is held to the sum the
 * door makes: admitted exactly while today's study spend, every course waiting unstarted --
 * as many as given, each inside its reader's share, and each this admits -- at the least a
 * course reserves, and this course's own least fit in the ceiling. Called as the owner.
 */
create or replace function pg_temp.fill(p_readers uuid[], p_waiting int)
returns int language plpgsql as $fn$
declare
  spent  numeric := public.study_spend_today();
  least_ numeric := public.study_min_job_cents();
  cap    numeric := public.study_daily_cap_cents();
  n      int := 0;
  took   boolean;
begin
  if least_ > public.study_requester_daily_cap_cents() then
    raise exception 'a course''s least does not fit in a reader''s share';
  end if;
  loop
    if n >= cardinality(p_readers) then
      raise exception 'the door admitted a course from every one of the % readers given', n;
    end if;
    if public.study_requester_spend_today(p_readers[n + 1]) <> 0
       or exists (select 1 from public.generation_jobs j
                  where j.requester_id = p_readers[n + 1]
                    and j.status in ('queued', 'running')) then
      raise exception 'fill was given a reader with something spent or waiting';
    end if;
    took := pg_temp.knock(p_readers[n + 1]);
    if took is distinct from (spent + (p_waiting + n + 1) * least_ <= cap) then
      raise exception 'the door % a course with % cents spent and % waiting unstarted',
        case when took then 'admitted' else 'refused' end, spent, p_waiting + n;
    end if;
    exit when not took;
    n := n + 1;
  end loop;
  return n;
end $fn$;


/* An evaluator report that clears the bar, with any field replaced. */
create or replace function pg_temp.report(p_patch jsonb default '{}'::jsonb)
returns jsonb language sql as $fn$
  select jsonb_build_object(
    'pipeline', jsonb_build_object('extract', pg_temp.stage('e'), 'assemble', pg_temp.stage('m')),
    'ranAt', pg_temp.utc(now() - interval '1 day'),
    'counts', jsonb_build_object('sources', 26, 'visibleItems', 320, 'quarantinedItems', 40,
                                 'doubleReviewedVisible', 320, 'groundedVisible', 320,
                                 'answerableVisible', 320, 'usableVisibleItems', 311,
                                 'materialErrors', 0, 'ambiguousVisible', 9,
                                 'adversarialItems', 30, 'adversarialLeaks', 0,
                                 'doubleReviewedAdversarial', 30, 'visibleSources', 25),
    'coverage', jsonb_build_object('present', jsonb_build_array('notes', 'pdf'),
                                   'missing', '[]'::jsonb),
    'gates', jsonb_build_object('minimumFixture', true, 'fixtureCoverage', true,
                                'answersSupported', true, 'ambiguity', true,
                                'adversarial', true, 'ledgerComplete', true,
                                'singlePipeline', true, 'ready', true))
  || p_patch
$fn$;
grant execute on function pg_temp.report(jsonb) to service_role;

/* A report's counts with some replaced. */
create or replace function pg_temp.counts(p_patch jsonb)
returns jsonb language sql as $fn$
  select pg_temp.report(jsonb_build_object('counts', pg_temp.report() -> 'counts' || p_patch))
$fn$;

do $test$
declare
  admitted  uuid := extensions.gen_random_uuid();
  outsider  uuid := extensions.gen_random_uuid();
  guest     uuid := extensions.gen_random_uuid();
  note      text := 'Roediger and Karpicke had students read prose. On a final test five '
                    'minutes later, the group that restudied remembered more.';
  good      uuid;
  bad       uuid;
  stale     uuid;
  saved     jsonb;
  v         uuid;
  out       jsonb;
  job       uuid;
  gen       uuid;
  course    uuid;
  q1        uuid;
  q2        uuid;
  q1_mine   uuid;
  q3        uuid;
  c1        uuid;
  c2        uuid;
  lapsed    uuid;
  other_job uuid;
  first_id  uuid;
  r         jsonb;
  state     text;
  rows      text;
  since     date;
  moment    timestamptz;
  midnight  timestamptz := date_trunc('day', now() at time zone 'utc') at time zone 'utc';
  jobs      uuid[];
  waited    int;
  attempts  bigint;
  readers   uuid[];
  reader_x  uuid;
  reader_y  uuid;
  x_spent   numeric;
  x_counts  numeric;
  held      numeric;
  gate_b    uuid;
  moved     bigint;
begin
  insert into auth.users
    (id, instance_id, aud, role, email, encrypted_password,
     email_confirmed_at, created_at, updated_at, is_anonymous,
     raw_app_meta_data, raw_user_meta_data)
  values
    (admitted, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
     'study-beta-admitted@example.test', '', now(), now(), now(), false, '{}', '{}'),
    (outsider, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
     'study-beta-outsider@example.test', '', now(), now(), now(), false, '{}', '{}'),
    (guest, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
     null, '', null, now(), now(), true, '{}', '{}');
  insert into public.study_generation_access (user_id) values (admitted);

  -- ---------------------------------------------------------------- release gates
  -- Recorded by the database owner: the service role, whose key every Edge Function holds,
  -- can read the gates, the switch and its log, and write none of them.
  perform pg_temp.become_worker();
  begin
    insert into public.study_release_gates (recorded_by, fixture_digest, report)
    values ('An Edge Function', repeat('9', 64), pg_temp.report());
    raise exception 'the service role recorded a release gate';
  exception when insufficient_privilege then null;
  end;
  begin
    update public.study_beta_settings set changed_by = 'An Edge Function' where id;
    raise exception 'the service role wrote the beta''s settings';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.close_study_beta('An Edge Function');
    raise exception 'the service role could close the beta';
  exception when insufficient_privilege then null;
  end;
  if has_table_privilege('service_role', 'public.study_beta_log', 'insert')
     or has_table_privilege('service_role', 'public.study_release_gates', 'truncate')
     or has_function_privilege('service_role', 'public.open_study_beta(uuid, text, text)',
                               'execute')
     or not has_table_privilege('service_role', 'public.study_release_gates', 'select') then
    raise exception 'the service role''s rights on the switch are not read-only';
  end if;

  perform pg_temp.as_owner();
  insert into public.study_release_gates (recorded_by, fixture_digest, report, recorded_at)
  values ('An operator', repeat('a', 64), pg_temp.report(), now() + interval '1 year')
  returning id into good;
  -- Its time is the run's, from the report, and it was recorded now whatever the writer said.
  if (select row(recorded_at = now(), ran_at = now() - interval '1 day',
                 pipeline -> 'extract' ->> 'model', pipeline -> 'assemble' ->> 'model')::text
      from public.study_release_gates where id = good)
     is distinct from row(true, true, 'e', 'm')::text then
    raise exception 'a gate''s times or pipeline were taken from the writer, not the report';
  end if;
  if (select passed from public.study_release_gates where id = good) is not true then
    raise exception 'a report that clears the bar did not pass';
  end if;

  -- Each shortfall fails, whatever the report's own gates say: a count below the bar, or not
  -- a whole number at or above zero; a visible question not grounded or not answerable; no
  -- adversarial item, or one not reviewed twice; no single pipeline, or one that does not say
  -- what extracted the claims as well as what assembled the course. Each is refused, not merely
  -- not passed: null, the answer for a report the check could not read, would have gone by an
  -- `or` of them all.
  foreach r in array array[
    pg_temp.counts('{"ambiguousVisible": -500}'),
    pg_temp.counts('{"ambiguousVisible": 8.5}'),
    pg_temp.counts('{"groundedVisible": 319}'),
    pg_temp.counts('{"answerableVisible": 0}'),
    pg_temp.counts('{"adversarialItems": 0, "doubleReviewedAdversarial": 0}'),
    pg_temp.counts('{"doubleReviewedAdversarial": 29}'),
    pg_temp.report() - 'pipeline',
    pg_temp.report(jsonb_build_object('pipeline', pg_temp.stage())),
    pg_temp.report(jsonb_build_object('pipeline',
      jsonb_build_object('assemble', pg_temp.stage()))),
    pg_temp.report(jsonb_build_object('pipeline',
      jsonb_build_object('extract', pg_temp.stage(''), 'assemble', pg_temp.stage()))),
    pg_temp.report(jsonb_build_object('pipeline',
      jsonb_build_object('extract', pg_temp.stage() || '{"promptHash": "x"}',
                         'assemble', pg_temp.stage()))),
    pg_temp.report(jsonb_build_object('pipeline',
      jsonb_build_object('extract', pg_temp.stage(),
                         'assemble', pg_temp.stage() || '{"schemaHash": "y"}'))),
    pg_temp.report(jsonb_build_object('gates',
      pg_temp.report() -> 'gates' || '{"singlePipeline": false}')),
    pg_temp.counts('{"visibleItems": 299, "doubleReviewedVisible": 299}'),
    pg_temp.counts('{"visibleSources": 23}'),
    pg_temp.counts('{"materialErrors": 1}'),
    pg_temp.counts('{"ambiguousVisible": 10}'),
    pg_temp.counts('{"adversarialLeaks": 1}'),
    pg_temp.counts('{"doubleReviewedVisible": 319}'),
    pg_temp.counts('{"visibleItems": "320"}'),
    pg_temp.report('{"coverage": {"present": [], "missing": ["ocr"]}}'),
    pg_temp.report(jsonb_build_object('gates',
      pg_temp.report() -> 'gates' || '{"ledgerComplete": false}')),
    pg_temp.report(jsonb_build_object('gates',
      pg_temp.report() -> 'gates' || '{"ready": "true"}')),
    pg_temp.report() - 'coverage',
    '[]'::jsonb
  ] loop
    if public.study_gate_passes(r) is distinct from false then
      raise exception 'a report short of the bar was not refused (%): %',
        coalesce(public.study_gate_passes(r)::text, 'null'), r;
    end if;
  end loop;
  -- The boundary: nine ambiguous of three hundred is 3%.
  if public.study_gate_passes(pg_temp.counts('{"visibleItems": 300, "doubleReviewedVisible": 300,
                                                "groundedVisible": 300, "answerableVisible": 300}'))
     is not true then
    raise exception 'a report exactly at the bar did not pass';
  end if;

  -- `passed` is computed, never taken: a failing report said to pass does not.
  insert into public.study_release_gates (recorded_by, fixture_digest, report, passed)
  values ('An operator', repeat('b', 64),
          pg_temp.report(jsonb_build_object('counts',
            pg_temp.report() -> 'counts' || '{"materialErrors": 2}')), true)
  returning id into bad;
  if (select passed from public.study_release_gates where id = bad) is not false then
    raise exception 'a failing report was stored as passed because the writer said so';
  end if;

  -- Final once written.
  begin
    update public.study_release_gates set passed = true where id = bad;
    raise exception 'a release gate was changed';
  exception when sqlstate '55000' then null;
  end;
  begin
    delete from public.study_release_gates where id = bad;
    raise exception 'a release gate was deleted';
  exception when sqlstate '55000' then null;
  end;
  begin
    insert into public.study_release_gates (recorded_by, fixture_digest, report)
    values ('An operator', 'not a digest', pg_temp.report());
    raise exception 'a gate was recorded without a sha256 digest';
  exception when check_violation then null;
  end;
  -- A run's report is recorded once; the same run evaluated again, a new report, is recorded
  -- beside it.
  begin
    insert into public.study_release_gates (recorded_by, fixture_digest, report)
    values ('Another operator', repeat('a', 64), pg_temp.report());
    raise exception 'a run''s report was recorded twice';
  exception when unique_violation then null;
  end;
  insert into public.study_release_gates (recorded_by, fixture_digest, report)
  values ('An operator', repeat('a', 64), pg_temp.counts('{"usableVisibleItems": 312}'));
  -- A report without its run's time, or one from the future, is not recorded; nor one whose
  -- time is a word Postgres would read as one, an infinity, or a time without its zone.
  begin
    insert into public.study_release_gates (recorded_by, fixture_digest, report)
    values ('An operator', repeat('d', 64), pg_temp.report() - 'ranAt');
    raise exception 'a gate was recorded without its run''s time';
  exception when sqlstate '22023' then null;
  end;
  begin
    insert into public.study_release_gates (recorded_by, fixture_digest, report)
    values ('An operator', repeat('e', 64),
            pg_temp.report(jsonb_build_object('ranAt', pg_temp.utc(now() + interval '1 day'))));
    raise exception 'a gate was recorded for a run in the future';
  exception when sqlstate '22023' then null;
  end;
  foreach state in array array['now', 'today', 'yesterday', 'epoch', '-infinity',
                               '2026-09-20 10:00:00', '2026-09-20T10:00:00',
                               '2026-09-20T10:00:00+00:00', '2026-02-30T10:00:00Z'] loop
    begin
      insert into public.study_release_gates (recorded_by, fixture_digest, report)
      values ('An operator', repeat('e', 64),
              pg_temp.report(jsonb_build_object('ranAt', state)));
      raise exception 'a gate was recorded with its run''s time given as %', state;
    exception when sqlstate '22023' then null;
    end;
  end loop;
  begin
    truncate public.study_release_gates cascade;
    raise exception 'the release gates were truncated';
  exception when sqlstate '55000' then null;
  end;

  -- A passing gate whose run was 31 days ago: as old as its run, however recently recorded.
  insert into public.study_release_gates (recorded_by, fixture_digest, report)
  values ('An operator', repeat('c', 64),
          pg_temp.report(jsonb_build_object('ranAt', pg_temp.utc(now() - interval '31 days'))))
  returning id into stale;
  if (select passed from public.study_release_gates where id = stale) is not true then
    raise exception 'the stale fixture gate did not pass';
  end if;

  -- ---------------------------------------------------------------- closed: allowlist only
  perform pg_temp.become_reader(outsider);
  if public.study_generation_available() then
    raise exception 'a reader off the allowlist could prepare a course while the beta is closed';
  end if;
  saved := public.save_study_source_version('Outsider note', 'paste', note,
                                            extensions.gen_random_uuid());
  begin
    perform public.enqueue_study_generation(array[(saved ->> 'versionId')::uuid],
                                            'Explain the argument',
                                            extensions.gen_random_uuid(), true);
    raise exception 'a reader off the allowlist was admitted while the beta is closed';
  exception when sqlstate '42501' then
    get stacked diagnostics state = pg_exception_detail;
    if state is distinct from 'beta' then
      raise exception 'the closed beta refused with DETAIL %', state;
    end if;
  end;
  perform pg_temp.become_reader(admitted);
  if not public.study_generation_available() then
    raise exception 'an allowlisted reader was refused';
  end if;

  -- ---------------------------------------------------------------- the flag's guards
  perform pg_temp.as_owner();
  -- Refused for the gate, and not only for the mix it would also have opened on.
  begin
    update public.study_beta_settings set open_to_all = true, gate_id = bad where id;
    raise exception 'the beta opened on a failed gate';
  exception when sqlstate '55000' then
    get stacked diagnostics state = pg_exception_detail;
    if state is distinct from 'gate' then
      raise exception 'a failed gate refused with %', state;
    end if;
  end;
  begin
    update public.study_beta_settings set open_to_all = true, gate_id = stale where id;
    raise exception 'the beta opened on a stale gate';
  exception when sqlstate '55000' then
    get stacked diagnostics state = pg_exception_detail;
    if state is distinct from 'gate' then
      raise exception 'a stale gate refused with %', state;
    end if;
  end;
  -- On no gate at all: the guard answers before the table's own constraint, which is there
  -- for a write that reaches the row with the guard out of the way.
  begin
    update public.study_beta_settings set open_to_all = true, gate_id = null where id;
    raise exception 'the beta opened on no gate';
  exception when sqlstate '55000' then
    get stacked diagnostics state = pg_exception_detail;
    if state is distinct from 'gate' then raise exception 'no gate refused with %', state; end if;
  end;
  begin
    insert into public.study_beta_settings (id) values (true);
    raise exception 'a second settings row was written';
  exception when sqlstate '55000' then null;
  end;
  begin
    delete from public.study_beta_settings;
    raise exception 'the settings row was deleted';
  exception when sqlstate '55000' then null;
  end;
  begin
    truncate public.study_beta_settings;
    raise exception 'the settings row was truncated';
  exception when sqlstate '55000' then null;
  end;

  begin
    perform public.open_study_beta(bad, 'An operator');
    raise exception 'open_study_beta opened on a failed gate';
  exception when sqlstate '55000' then
    get stacked diagnostics state = pg_exception_detail;
    if state is distinct from 'gate_failed' then raise exception 'failed gate: %', state; end if;
  end;
  begin
    perform public.open_study_beta(stale, 'An operator');
    raise exception 'open_study_beta opened on a stale gate';
  exception when sqlstate '55000' then
    get stacked diagnostics state = pg_exception_detail;
    if state is distinct from 'gate_stale' then raise exception 'stale gate: %', state; end if;
  end;
  begin
    perform public.open_study_beta(extensions.gen_random_uuid(), 'An operator');
    raise exception 'open_study_beta opened on no gate';
  exception when sqlstate 'P0002' then null;
  end;

  -- The beta so far covers nothing like every kind of source and goal: refused without a
  -- reason, and a reason too short to be one is not one.
  if not (public.study_beta_unrepresented() @> array['format:scanned', 'goal:assess']) then
    raise exception 'an uncovered beta did not say what it is missing: %',
      public.study_beta_unrepresented();
  end if;
  begin
    perform public.open_study_beta(good, 'An operator');
    raise exception 'the beta opened with its mix uncovered and no reason';
  exception when sqlstate '55000' then
    get stacked diagnostics state = pg_exception_detail;
    if state is distinct from 'unrepresentative' then
      raise exception 'uncovered mix: %', state;
    end if;
  end;
  begin
    perform public.open_study_beta(good, 'An operator', 'because');
    raise exception 'the beta opened on a reason of one word';
  exception when sqlstate '55000' then null;
  end;
  -- However the row is changed: an UPDATE that opens it is held to the same rule, with the
  -- reason in `study.beta_override`, where open_study_beta puts it -- refused without one or
  -- with one too short, and opened and logged with one. Probed, and undone.
  begin
    update public.study_beta_settings set open_to_all = true, gate_id = good where id;
    raise exception 'an UPDATE opened the beta with its mix uncovered and no reason';
  exception when sqlstate '55000' then
    get stacked diagnostics state = pg_exception_detail;
    if state is distinct from 'unrepresentative' then
      raise exception 'an UPDATE opening on an uncovered mix was refused with %', state;
    end if;
  end;
  begin
    perform set_config('study.beta_override', 'because', true);
    update public.study_beta_settings set open_to_all = true, gate_id = good where id;
    raise exception 'an UPDATE opened the beta on a reason of one word';
  exception when sqlstate '55000' then null;
  end;
  begin
    perform set_config('study.beta_override', 'Opened by hand; scanned sources ship next.', true);
    update public.study_beta_settings
       set open_to_all = true, gate_id = good, changed_by = 'An operator' where id;
    if (select override_reason from public.study_beta_log order by id desc limit 1)
       is distinct from 'Opened by hand; scanned sources ship next.' then
      raise exception 'an UPDATE opening on an uncovered mix did not log its reason';
    end if;
    raise exception using errcode = 'P0001', message = 'probe done';
  exception when raise_exception then
    if sqlerrm is distinct from 'probe done' then raise; end if;
  end;

  r := public.open_study_beta(good, 'An operator',
                              'Pilot cohort is small; scanned sources ship in the next wave.');
  if (r ->> 'open')::boolean is not true
     or (select open_to_all from public.study_beta_settings) is not true
     or (select override_reason from public.study_beta_log order by id desc limit 1)
        is distinct from 'Pilot cohort is small; scanned sources ship in the next wave.'
     or (select changed_by from public.study_beta_log order by id desc limit 1)
        is distinct from 'An operator'
     or (select db_user from public.study_beta_log order by id desc limit 1)
        is distinct from session_user::text
     or current_setting('study.beta_override', true) is distinct from '' then
    raise exception 'opening on a passing gate with a reason was not done and logged: %', r;
  end if;
  -- The log is appended to, never changed.
  begin
    update public.study_beta_log set changed_by = 'Someone else';
    raise exception 'the beta''s log was changed';
  exception when sqlstate '55000' then null;
  end;
  begin
    delete from public.study_beta_log;
    raise exception 'the beta''s log was deleted';
  exception when sqlstate '55000' then null;
  end;
  begin
    truncate public.study_beta_log;
    raise exception 'the beta''s log was truncated';
  exception when sqlstate '55000' then null;
  end;

  -- ---------------------------------------------------------------- open: every account
  perform pg_temp.become_reader(outsider);
  if not public.study_generation_available() then
    raise exception 'the open beta still refused a reader with an account';
  end if;
  out := public.enqueue_study_generation(array[(saved ->> 'versionId')::uuid],
                                         'Explain the argument',
                                         extensions.gen_random_uuid(), true);
  if out ->> 'jobId' is null then
    raise exception 'the open beta did not queue a course: %', out;
  end if;
  -- The study ceiling counts study spend and nothing else: the catalogue's generation having
  -- spent 150 of the day's 200 cents, a course is still admitted. Probed, and undone.
  begin
    perform pg_temp.as_owner();
    insert into public.generation_jobs (kind, status)
    values ('canonical_summary', 'running') returning id into other_job;
    insert into public.cost_ledger (job_id, provider, operation, unit, quantity, cost_cents)
    values (other_job, 'test', 'summarise', 'call', 1, 150);
    if public.study_spend_today() is distinct from 0::numeric then
      raise exception 'the study spend counted the catalogue''s: %', public.study_spend_today();
    end if;
    perform pg_temp.become_reader(outsider);
    perform public.enqueue_study_generation(array[(saved ->> 'versionId')::uuid],
                                            'Remember the key findings',
                                            extensions.gen_random_uuid(), true);
    raise exception using errcode = 'P0001', message = 'probe done';
  exception when raise_exception then
    if sqlerrm is distinct from 'probe done' then raise; end if;
  end;
  -- Study spend, every reader's together, is held to its ceiling: with two other readers'
  -- jobs having spent or held 80 of the study day's 100 cents -- 40 charged to one and 40
  -- held open for the other, inside their shares -- a new course cannot be funded, though the
  -- global cap and this reader's share both could. Probed, and undone.
  begin
    perform pg_temp.as_owner();
    insert into public.generation_jobs (kind, requester_id, status)
    values ('study_course', admitted, 'running') returning id into other_job;
    insert into public.cost_ledger (job_id, provider, operation, unit, quantity, cost_cents)
    values (other_job, 'test', 'study_extract', 'call', 1, 40);
    insert into public.generation_jobs (kind, requester_id, status)
    values ('study_course', guest, 'running') returning id into other_job;
    insert into public.budget_reservations (job_id, step, reserved_cents)
    values (other_job, 'study_extract', 40);
    if public.study_spend_today() is distinct from 80::numeric then
      raise exception 'the study spend is %, not the 40 charged and 40 held',
        public.study_spend_today();
    end if;
    -- And nothing that is not today's, or not held: a charge from yesterday, a hold taken
    -- before midnight, a hold past its hour, and a hold settled.
    insert into public.cost_ledger
      (job_id, provider, operation, unit, quantity, cost_cents, created_at)
    values (other_job, 'test', 'study_extract', 'call', 1, 7, midnight - interval '1 second');
    insert into public.budget_reservations (job_id, step, reserved_cents, created_at, settled_at)
    values (other_job, 'study_assemble', 11, midnight - interval '1 minute', null),
           (other_job, 'study_extract_2', 13, now() - interval '61 minutes', null),
           (other_job, 'study_extract_3', 17, now(), now());
    if public.study_spend_today() is distinct from 80::numeric then
      raise exception 'the study spend is %, not the 80 charged today and held open',
        public.study_spend_today();
    end if;
    -- A hold from before midnight is also past the TTL's hour, except in the day's first hour;
    -- with the TTL a day long, the day alone must keep it out. Probed, and undone.
    begin
      update public.budget_reservations set settled_at = now()
       where job_id = other_job and step = 'study_extract_2';
      create or replace function public.budget_reservation_ttl()
      returns interval language sql immutable set search_path = ''
      as $ttl$ select interval '1 day' $ttl$;
      if public.study_spend_today() is distinct from 80::numeric then
        raise exception 'a hold taken before midnight was counted in today''s study spend: %',
          public.study_spend_today();
      end if;
      raise exception using errcode = 'P0001', message = 'probe done';
    exception when raise_exception then
      if sqlerrm is distinct from 'probe done' then raise; end if;
    end;
    perform pg_temp.become_reader(outsider);
    begin
      perform public.enqueue_study_generation(array[(saved ->> 'versionId')::uuid],
                                              'Remember the key findings',
                                              extensions.gen_random_uuid(), true);
      raise exception 'a course was queued past the study ceiling';
    exception when sqlstate '53400' then
      if sqlerrm not like 'today''s study generation budget is spent%' then
        raise exception 'the study ceiling refused as %', sqlerrm;
      end if;
    end;
    -- And at each reservation, under the budget lock: this reader's own queued course, well
    -- inside their share, is refused a step that would take the study day past its ceiling.
    perform pg_temp.become_worker();
    begin
      perform public.reserve_budget((out ->> 'jobId')::uuid, 'study_extract', 25);
      raise exception 'a study reservation went past the study ceiling';
    exception when sqlstate '53400' then
      if sqlerrm not like 'the day''s study budget is spent%' then
        raise exception 'the reservation was refused as %', sqlerrm;
      end if;
    end;
    raise exception using errcode = 'P0001', message = 'probe done';
  exception when raise_exception then
    if sqlerrm is distinct from 'probe done' then raise; end if;
  end;
  -- The ceiling's edge. With every other study course set aside and the ceiling less one
  -- course's least held, a course is admitted, and its first reservation may take the day to
  -- the ceiling exactly; with a cent more held, none is. Probed, and undone.
  begin
    perform pg_temp.as_owner();
    update public.generation_jobs set status = 'cancelled'
     where kind = 'study_course' and status in ('queued', 'running');
    insert into public.generation_jobs (kind, requester_id, status)
    values ('study_course', admitted, 'running') returning id into other_job;
    insert into public.budget_reservations (job_id, step, reserved_cents)
    values (other_job, 'study_extract',
            public.study_daily_cap_cents() - public.study_min_job_cents());
    perform pg_temp.become_reader(outsider);
    job := (public.enqueue_study_generation(array[(saved ->> 'versionId')::uuid],
                                            'Remember the key findings',
                                            extensions.gen_random_uuid(), true) ->> 'jobId')::uuid;
    perform pg_temp.become_worker();
    perform public.reserve_budget(job, 'study_extract', public.study_min_job_cents());
    if public.study_spend_today() is distinct from public.study_daily_cap_cents() then
      raise exception 'the study day was taken to %, not to its ceiling',
        public.study_spend_today();
    end if;
    perform pg_temp.as_owner();
    update public.generation_jobs set status = 'cancelled' where id = job;
    update public.budget_reservations set settled_at = now() where job_id = job;
    update public.budget_reservations set reserved_cents = reserved_cents + 1
     where job_id = other_job;
    perform pg_temp.become_reader(outsider);
    if pg_temp.admits((saved ->> 'versionId')::uuid) then
      raise exception 'a course was admitted with a cent less than its least left of the ceiling';
    end if;
    raise exception using errcode = 'P0001', message = 'probe done';
  exception when raise_exception then
    if sqlerrm is distinct from 'probe done' then raise; end if;
  end;
  -- And the door counts the courses it has admitted, not only what they have spent: one that
  -- today's study spend does not see yet -- queued or running, nothing it cost charged today
  -- and nothing held -- is counted at its least, and the next course is refused exactly when
  -- that sum passes the ceiling. With nothing spent, as many are admitted as the ceiling holds
  -- at their least, a course each from readers inside their shares. An attempt ledgered at
  -- nothing -- a provider's 429, its hold settled with no charge -- is no start: that course
  -- is still counted, and the next is still refused. Then, running, one charged 5 cents and
  -- one holding 5 are counted at what they have, and the one charged only yesterday, besides
  -- today's free attempt, still at its least. Probed, and undone.
  begin
    perform pg_temp.as_owner();
    update public.generation_jobs set status = 'cancelled'
     where kind = 'study_course' and status in ('queued', 'running');
    select array_agg(pg_temp.new_reader(note)) into readers
    from generate_series(1, 2 * (floor(public.study_daily_cap_cents()
                                       / public.study_min_job_cents())::int + 1));
    waited := pg_temp.fill(readers, 0);
    if waited is distinct from floor(public.study_daily_cap_cents()
                                     / public.study_min_job_cents())::int
       or waited < 3 then
      raise exception 'with nothing spent the door admitted % courses', waited;
    end if;
    select array_agg(j.id order by array_position(readers, j.requester_id)) into jobs
    from public.generation_jobs j
    where j.requester_id = any (readers) and j.kind = 'study_course' and j.status = 'queued';
    update public.generation_jobs set status = 'running' where id = any (jobs);
    insert into public.cost_ledger (job_id, provider, operation, unit, quantity, cost_cents)
    values (jobs[3], 'test', 'study_extract', 'call', 1, 0);
    insert into public.budget_reservations (job_id, step, reserved_cents, settled_at)
    values (jobs[3], 'study_extract', public.study_min_job_cents(), now());
    if pg_temp.would_admit(readers[waited + 1]) then
      raise exception 'a course whose one attempt today cost nothing left the door''s count';
    end if;
    insert into public.cost_ledger (job_id, provider, operation, unit, quantity, cost_cents)
    values (jobs[1], 'test', 'study_extract', 'call', 1, 5);
    insert into public.budget_reservations (job_id, step, reserved_cents)
    values (jobs[2], 'study_extract', 5);
    insert into public.cost_ledger
      (job_id, provider, operation, unit, quantity, cost_cents, created_at)
    values (jobs[3], 'test', 'study_extract', 'call', 1, 5, midnight - interval '1 second');
    waited := pg_temp.fill(readers[waited + 1:], cardinality(jobs) - 2);
    if waited is distinct from floor((public.study_daily_cap_cents() - public.study_spend_today())
                                     / public.study_min_job_cents())::int
                               - (cardinality(jobs) - 2)
       or waited < 1 then
      raise exception 'with the courses started the door admitted % more', waited;
    end if;
    raise exception using errcode = 'P0001', message = 'probe done';
  exception when raise_exception then
    if sqlerrm is distinct from 'probe done' then raise; end if;
  end;
  -- One reader's queue counts at the door for no more than what is left of their share, which
  -- is all it can spend today: counted in full, it closed the door to every other reader. One
  -- reader queues three courses; then, with nothing spent, a third of their share spent on the
  -- first, and all of it, the door counts theirs for exactly the least of those waiting at
  -- their least and what is left of the share: a reader with nothing spent is admitted when
  -- another's hold leaves exactly that count and one course's least of the ceiling, and
  -- refused when it leaves a ten-thousandth of a cent less. Probed, and undone.
  begin
    perform pg_temp.as_owner();
    update public.generation_jobs set status = 'cancelled'
     where kind = 'study_course' and status in ('queued', 'running');
    reader_x := pg_temp.new_reader(note);
    reader_y := pg_temp.new_reader(note);
    for i in 1..3 loop
      if not pg_temp.knock(reader_x) then
        raise exception 'one reader''s course % of three was refused at an empty door', i;
      end if;
    end loop;
    select array_agg(j.id order by j.id) into jobs
    from public.generation_jobs j
    where j.requester_id = reader_x and j.kind = 'study_course' and j.status = 'queued';
    -- Another reader's call in flight, whose hold fills the ceiling to the edge.
    insert into public.generation_jobs (kind, requester_id, status)
    values ('study_course', guest, 'running') returning id into other_job;
    insert into public.budget_reservations (job_id, step, reserved_cents)
    values (other_job, 'study_extract', 0);
    foreach x_spent in array array[0, floor(public.study_requester_daily_cap_cents() / 3),
                                   public.study_requester_daily_cap_cents()] loop
      if x_spent > 0 then
        update public.generation_jobs set status = 'running' where id = jobs[1];
        insert into public.cost_ledger (job_id, provider, operation, unit, quantity, cost_cents)
        values (jobs[1], 'test', 'study_assemble', 'call', 1,
                x_spent - public.study_requester_spend_today(reader_x));
      end if;
      x_counts := least((case when x_spent > 0 then 2 else 3 end) * public.study_min_job_cents(),
                        public.study_requester_daily_cap_cents() - x_spent);
      if x_counts >= (case when x_spent > 0 then 2 else 3 end) * public.study_min_job_cents() then
        raise exception 'the reader''s queue fits in their share, which this does not test';
      end if;
      update public.budget_reservations set reserved_cents = 0 where job_id = other_job;
      held := public.study_daily_cap_cents() - public.study_min_job_cents()
              - public.study_spend_today() - x_counts;
      if held < 0 then
        raise exception 'the ceiling has no room to probe the count with % spent', x_spent;
      end if;
      update public.budget_reservations set reserved_cents = held where job_id = other_job;
      if not pg_temp.would_admit(reader_y) then
        raise exception 'with % of a share spent, three courses queued counted for more than %',
          x_spent, x_counts;
      end if;
      update public.budget_reservations set reserved_cents = held + 0.0001
       where job_id = other_job;
      if pg_temp.would_admit(reader_y) then
        raise exception 'with % of a share spent, three courses queued counted for less than %',
          x_spent, x_counts;
      end if;
    end loop;
    raise exception using errcode = 'P0001', message = 'probe done';
  exception when raise_exception then
    if sqlerrm is distinct from 'probe done' then raise; end if;
  end;
  -- A preparation since opening is off the gate's pipeline when either stage is: assembled
  -- with another model, or its claims extracted with another. One on the gate's is not.
  -- Probed, and undone.
  begin
    perform pg_temp.become_worker();
    perform public.persist_study_course((out ->> 'jobId')::uuid,
      pg_temp.course((saved ->> 'versionId')::uuid, note));
    if (select preparations_off_gate from ops.study_beta_status) is distinct from 0 then
      raise exception 'a preparation on the gate''s pipeline was counted off it';
    end if;
    perform pg_temp.become_reader(outsider);
    other_job := (public.enqueue_study_generation(array[(saved ->> 'versionId')::uuid],
                                                  'Prepare for a discussion',
                                                  extensions.gen_random_uuid(), true)
                  ->> 'jobId')::uuid;
    perform pg_temp.become_worker();
    perform public.persist_study_course(other_job,
      pg_temp.course((saved ->> 'versionId')::uuid, note, p_assemble => pg_temp.stage('n')));
    if (select preparations_off_gate from ops.study_beta_status) is distinct from 1 then
      raise exception 'a preparation assembled off the gate''s pipeline was not counted once';
    end if;
    perform pg_temp.become_reader(outsider);
    other_job := (public.enqueue_study_generation(array[(saved ->> 'versionId')::uuid],
                                                  'Prepare for an assessment',
                                                  extensions.gen_random_uuid(), true)
                  ->> 'jobId')::uuid;
    perform pg_temp.become_worker();
    perform public.persist_study_course(other_job,
      pg_temp.course((saved ->> 'versionId')::uuid, note, p_extract => pg_temp.stage('n')));
    if (select preparations_off_gate from ops.study_beta_status) is distinct from 2 then
      raise exception 'a preparation extracted off the gate''s pipeline was not counted';
    end if;
    -- Counted from the first time the beta opened on its gate, which opening on it again does
    -- not move: opened two hours ago and the two prepared an hour ago, both are still counted
    -- once the operator opens it again. Not while it is closed; not what is not assembled yet,
    -- whatever its claims were extracted with; and not what was prepared before it opened.
    perform pg_temp.as_owner();
    alter table public.study_beta_log disable trigger study_beta_log_appended;
    update public.study_beta_log set at = now() - interval '2 hours' where gate_id = good;
    alter table public.study_beta_log enable trigger study_beta_log_appended;
    update public.study_generations set created_at = now() - interval '1 hour'
     where owner_id = outsider;
    perform public.open_study_beta(good, 'An operator',
                                   'Pilot cohort is small; scanned sources ship in the next wave.');
    if (select preparations_off_gate from ops.study_beta_status) is distinct from 2 then
      raise exception 'opening again on the same gate set the preparations off it to %',
        (select preparations_off_gate from ops.study_beta_status);
    end if;
    perform public.close_study_beta('An operator');
    if (select preparations_off_gate from ops.study_beta_status) is distinct from 0 then
      raise exception 'preparations off the gate were counted while the beta is closed';
    end if;
    perform public.open_study_beta(good, 'An operator',
                                   'Pilot cohort is small; scanned sources ship in the next wave.');
    update public.study_generations set assembly_provenance = null where job_id = other_job;
    if (select preparations_off_gate from ops.study_beta_status) is distinct from 1 then
      raise exception 'a preparation not yet assembled was counted off the gate';
    end if;
    update public.study_generations set created_at = now() - interval '3 hours'
     where assembly_provenance ->> 'model' = 'n';
    if (select preparations_off_gate from ops.study_beta_status) is distinct from 0 then
      raise exception 'a preparation from before the beta opened was counted off its gate';
    end if;
    raise exception using errcode = 'P0001', message = 'probe done';
  exception when raise_exception then
    if sqlerrm is distinct from 'probe done' then raise; end if;
  end;
  -- Moved to another gate and back, the count starts again at the return: a preparation
  -- assembled on the other gate's pipeline while the beta stood open on it is that gate's, not
  -- off this one's, and one assembled on neither since the return is off it. Opened on this
  -- gate three hours ago, on the other two, and on this one again an hour ago; the first
  -- prepared ninety minutes ago, the second half an hour. And which came last is the log's
  -- order, not its clock: moved away and back in one transaction, both logged at one moment,
  -- the count starts at the return and not at nothing. Probed, and undone.
  begin
    perform pg_temp.as_owner();
    update public.generation_jobs set status = 'cancelled'
     where kind = 'study_course' and status in ('queued', 'running');
    insert into public.study_release_gates (recorded_by, fixture_digest, report)
    values ('An operator', repeat('f', 64),
            pg_temp.report(jsonb_build_object('pipeline',
              jsonb_build_object('extract', pg_temp.stage('e'), 'assemble', pg_temp.stage('n')))))
    returning id into gate_b;
    perform public.open_study_beta(gate_b, 'An operator',
                                   'Pilot cohort is small; scanned sources ship in the next wave.');
    moved := (select max(id) from public.study_beta_log);
    perform pg_temp.become_reader(outsider);
    job := (public.enqueue_study_generation(array[(saved ->> 'versionId')::uuid],
                                            'Prepare for a discussion',
                                            extensions.gen_random_uuid(), true) ->> 'jobId')::uuid;
    perform pg_temp.become_worker();
    perform public.persist_study_course(job,
      pg_temp.course((saved ->> 'versionId')::uuid, note, p_assemble => pg_temp.stage('n')));
    if (select preparations_off_gate from ops.study_beta_status) is distinct from 0 then
      raise exception 'a preparation on the other gate''s pipeline was counted off it';
    end if;
    perform pg_temp.as_owner();
    update public.generation_jobs set status = 'succeeded' where id = job;
    perform public.open_study_beta(good, 'An operator',
                                   'Pilot cohort is small; scanned sources ship in the next wave.');
    perform pg_temp.become_reader(outsider);
    other_job := (public.enqueue_study_generation(array[(saved ->> 'versionId')::uuid],
                                                  'Prepare for an assessment',
                                                  extensions.gen_random_uuid(), true)
                  ->> 'jobId')::uuid;
    perform pg_temp.become_worker();
    perform public.persist_study_course(other_job,
      pg_temp.course((saved ->> 'versionId')::uuid, note, p_assemble => pg_temp.stage('o')));
    perform pg_temp.as_owner();
    update public.generation_jobs set status = 'succeeded' where id = other_job;
    alter table public.study_beta_log disable trigger study_beta_log_appended;
    update public.study_beta_log
       set at = now() - case when id < moved then interval '3 hours'
                             when id = moved then interval '2 hours'
                             else interval '1 hour' end;
    alter table public.study_beta_log enable trigger study_beta_log_appended;
    update public.study_generations set created_at = now() - interval '90 minutes'
     where job_id = job;
    update public.study_generations set created_at = now() - interval '30 minutes'
     where job_id = other_job;
    if (select preparations_off_gate from ops.study_beta_status) is distinct from 1 then
      raise exception 'moved to another gate and back, % preparations were counted off the '
                      'gate, not the one on neither pipeline since the return',
        (select preparations_off_gate from ops.study_beta_status);
    end if;
    perform public.open_study_beta(gate_b, 'An operator',
                                   'Pilot cohort is small; scanned sources ship in the next wave.');
    perform public.open_study_beta(good, 'An operator',
                                   'Pilot cohort is small; scanned sources ship in the next wave.');
    perform pg_temp.become_reader(outsider);
    other_job := (public.enqueue_study_generation(array[(saved ->> 'versionId')::uuid],
                                                  'Explain the argument',
                                                  extensions.gen_random_uuid(), true)
                  ->> 'jobId')::uuid;
    perform pg_temp.become_worker();
    perform public.persist_study_course(other_job,
      pg_temp.course((saved ->> 'versionId')::uuid, note, p_assemble => pg_temp.stage('o')));
    if (select preparations_off_gate from ops.study_beta_status) is distinct from 1 then
      raise exception 'moved away and back in one transaction, % preparations were counted off '
                      'the gate, not the one since the return',
        (select preparations_off_gate from ops.study_beta_status);
    end if;
    raise exception using errcode = 'P0001', message = 'probe done';
  exception when raise_exception then
    if sqlerrm is distinct from 'probe done' then raise; end if;
  end;
  perform pg_temp.become_reader(outsider);
  -- The rest of the door stands: consent is still asked for.
  begin
    perform public.enqueue_study_generation(array[(saved ->> 'versionId')::uuid],
                                            'Prepare for a discussion',
                                            extensions.gen_random_uuid(), false);
    raise exception 'the open beta queued a course without consent';
  exception when sqlstate '22023' then null;
  end;
  -- A guest is not an account.
  perform set_config('request.jwt.claims',
    json_build_object('sub', guest, 'role', 'authenticated', 'is_anonymous', true)::text, true);
  if public.study_generation_available() then
    raise exception 'the open beta admitted a guest';
  end if;

  -- Readers cannot see or move the flag, the gates or the log, or reach the operators' views.
  -- Not even rows withheld by a policy: no reader holds a grant on them at all.
  perform pg_temp.become_reader(outsider);
  if has_table_privilege('authenticated', 'public.study_beta_settings', 'select')
     or has_table_privilege('authenticated', 'public.study_release_gates', 'select')
     or has_table_privilege('authenticated', 'public.study_beta_log', 'select') then
    raise exception 'a reader could read the beta''s settings, gates or log';
  end if;
  begin
    perform 1 from public.study_beta_settings;
    raise exception 'a reader read the beta''s settings';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.open_study_beta(good, 'Me', 'I would like to open it for everyone please');
    raise exception 'a reader could open the beta';
  exception when insufficient_privilege then null;
  end;
  begin
    perform 1 from ops.study_daily;
    raise exception 'a reader could read the operators'' views';
  exception when insufficient_privilege then null;
  end;

  -- An open beta lapses once its gate's run is sixty days old. Probed, and undone.
  begin
    perform pg_temp.as_owner();
    alter table public.study_release_gates disable trigger study_release_gates_recorded;
    update public.study_release_gates set ran_at = now() - interval '61 days' where id = good;
    alter table public.study_release_gates enable trigger study_release_gates_recorded;
    if public.study_generation_admitted(outsider) then
      raise exception 'an open beta admitted a reader on a gate sixty days old';
    end if;
    if (select admission_lapsed from ops.study_beta_status) is not true then
      raise exception 'the status view did not say admission has lapsed';
    end if;
    raise exception using errcode = 'P0001', message = 'probe done';
  exception when raise_exception then
    if sqlerrm is distinct from 'probe done' then raise; end if;
  end;

  perform pg_temp.as_owner();
  perform public.close_study_beta('An operator');
  perform pg_temp.become_reader(outsider);
  if public.study_generation_available() then
    raise exception 'closing the beta did not close it';
  end if;
  perform pg_temp.become_worker();
  if (select count(*) from public.study_beta_log where gate_id = good) is distinct from 2::bigint then
    raise exception 'opening and closing were not both logged';
  end if;
  -- Closing leaves the course already queued for a reader it no longer admits, and says so:
  -- the outsider's, and not the allowlisted reader's queued beside it. Probed, and undone.
  begin
    perform pg_temp.become_reader(admitted);
    perform public.enqueue_study_generation(
      array[(public.save_study_source_version('Queued note', 'paste', note,
                                              extensions.gen_random_uuid()) ->> 'versionId')::uuid],
      'Explain the argument', extensions.gen_random_uuid(), true);
    perform pg_temp.become_worker();
    if (select queued_for_readers_not_admitted from ops.study_beta_status)
       is distinct from 1 then
      raise exception 'the status view counted % courses queued for readers not admitted, not 1',
        (select queued_for_readers_not_admitted from ops.study_beta_status);
    end if;
    raise exception using errcode = 'P0001', message = 'probe done';
  exception when raise_exception then
    if sqlerrm is distinct from 'probe done' then raise; end if;
  end;

  -- ---------------------------------------------------------------- the known-before stamp
  perform pg_temp.become_reader(admitted);
  saved := public.save_study_source_version('Prose memory', 'paste', note,
                                            extensions.gen_random_uuid());
  v := (saved ->> 'versionId')::uuid;
  out := public.enqueue_study_generation(array[v], 'Explain the argument',
                                         extensions.gen_random_uuid(), true);
  job := (out ->> 'jobId')::uuid;
  gen := (out ->> 'generationId')::uuid;
  course := (out ->> 'courseId')::uuid;
  perform pg_temp.become_worker();
  perform public.persist_study_course(job, pg_temp.course(v, note));
  perform public.validate_study_course(job);
  perform pg_temp.as_owner();
  update public.generation_jobs set status = 'succeeded' where id = job;
  select id into q1 from public.study_items where generation_id = gen and item_key = 'q1';
  select id into q2 from public.study_items where generation_id = gen and item_key = 'q2';
  select id into q3 from public.study_items where generation_id = gen and item_key = 'q3';
  select id into c1 from public.study_claims where generation_id = gen and claim_key = 's1c1';
  select id into c2 from public.study_claims where generation_id = gen and claim_key = 's1c2';
  if (select count(*) from public.study_items where generation_id = gen and status = 'validated')
     is distinct from 3::bigint then
    raise exception 'the fixture''s questions did not all validate';
  end if;

  perform pg_temp.become_reader(admitted);
  r := pg_temp.answer(q1, '"Restudying"');
  first_id := (select id from public.study_answer_events where item_id = q1
               order by answered_at, id limit 1);
  if (select claims_known_before from public.study_answer_events where id = first_id)
     is distinct from false then
    raise exception 'a first answer was stamped as given when the claim was known';
  end if;
  -- Known now: the next answer is stamped so, and a wrong one is false mastery.
  if (select known from public.study_claim_knowledge(course) where claim_id = c1)
     is distinct from true then
    raise exception 'the fixture''s proof did not make its claim known';
  end if;
  -- A question on a known claim and one not yet known: not every claim known before it.
  r := pg_temp.answer(q2, '"Prose; restudying"');
  if (select claims_known_before from public.study_answer_events
      where client_event_id = (r -> 'results' -> 0 ->> 'clientEventId')::uuid)
     is distinct from false then
    raise exception 'an answer was stamped known before with one of its claims unknown';
  end if;
  -- Wrong while known: false mastery. Then right again, which the wrong answer's feedback
  -- made hinted, and which is not known before: the lapse took the knowledge away.
  r := pg_temp.answer(q1, '"The recall test"');
  r := pg_temp.answer(q1, '"Restudying"');
  if (select string_agg(coalesce(claims_known_before::text, 'null'), ','
                        order by answered_at, id)
      from public.study_answer_events where item_id = q1) is distinct from 'false,true,false' then
    raise exception 'the known-before stamps are %',
      (select string_agg(coalesce(claims_known_before::text, 'null'), ','
                         order by answered_at, id)
       from public.study_answer_events where item_id = q1);
  end if;
  -- One definition of known: the course's knowledge agrees with the per-claim function now;
  -- asked about an hour ago, before anything here was proven; and a thousand years on, when
  -- nothing is recalled and only the clamp on the days keeps the power in range.
  if (select known from public.study_claim_knowledge(course) where claim_id = c2)
     is distinct from true then
    raise exception 'the fixture''s second claim is not known';
  end if;
  foreach moment in array array[null, now() - interval '1 hour',
                                now() + interval '1000 years']::timestamptz[] loop
    if exists (select 1 from public.study_claim_knowledge(course, moment) k
               join public.study_claims c on c.id = k.claim_id
               where k.known is distinct from public.study_claim_known(c.owner_id, c.id, moment))
    then
      raise exception 'study_claim_knowledge and study_claim_known disagree at %',
        coalesce(moment::text, 'now');
    end if;
  end loop;
  -- And once the question that proved a claim is retired, here by the reader's correction of
  -- it, the proof is gone from both. Probed, and undone.
  begin
    perform public.revise_study_item(q2, '{"prompt": "What was read, and what won early?"}');
    if exists (select 1 from public.study_claim_knowledge(course) k
               join public.study_claims c on c.id = k.claim_id
               where k.known is distinct from public.study_claim_known(c.owner_id, c.id))
       or public.study_claim_known(admitted, c2) then
      raise exception 'a claim proven by a retired question is still known to one of the two';
    end if;
    raise exception using errcode = 'P0001', message = 'probe done';
  exception when raise_exception then
    if sqlerrm is distinct from 'probe done' then raise; end if;
  end;
  -- A claim that is not validated is not known, whatever its memory says: the course does not
  -- list it, and the per-claim rule says so. Probed, and undone.
  begin
    perform pg_temp.as_owner();
    update public.study_claims set status = 'quarantined', validation_failures = '{probe}'
     where id = c2;
    if not exists (select 1 from public.study_claim_memory m
                   where m.claim_id = c2 and m.last_outcome = 'success')
       or exists (select 1 from public.study_claim_knowledge(course) k where k.claim_id = c2)
       or public.study_claim_known(admitted, c2) then
      raise exception 'a quarantined claim with memory of a success was known';
    end if;
    raise exception using errcode = 'P0001', message = 'probe done';
  exception when raise_exception then
    if sqlerrm is distinct from 'probe done' then raise; end if;
  end;
  perform pg_temp.become_reader(admitted);

  -- Stamped only where the measure reads it: not the reader's own version, and not a
  -- self-graded answer to one the model wrote.
  q1_mine := public.revise_study_item(q1, '{"prompt": "Which won early, in my words?"}');
  r := pg_temp.answer(q1_mine, '"Restudying"');
  if (r ->> 'recorded')::int is distinct from 1
     or (select claims_known_before from public.study_answer_events
         where client_event_id = (r -> 'results' -> 0 ->> 'clientEventId')::uuid) is not null then
    raise exception 'an answer to the reader''s own version was stamped, or not recorded: %', r;
  end if;
  r := pg_temp.answer(q3, '"reading it again"', 'correct');
  if (r -> 'results' -> 0 ->> 'grading') is distinct from 'self'
     or (select claims_known_before from public.study_answer_events
         where client_event_id = (r -> 'results' -> 0 ->> 'clientEventId')::uuid) is not null then
    raise exception 'a self-graded answer was stamped, or not recorded as self-graded: %', r;
  end if;

  -- ---------------------------------------------------------------- the learning measures
  -- The first, clean answer moved eight days back: the next deterministic answer is a
  -- seven-day attempt.
  -- And a hinted answer is no test of what the reader knew: the last answer to q1, hinted by
  -- the wrong one before it, made wrong and stamped known before, must not count.
  perform pg_temp.as_owner();
  alter table public.study_answer_events disable trigger study_answer_events_are_final;
  update public.study_answer_events set answered_at = now() - interval '8 days'
   where id = first_id;
  update public.study_answer_events set correct = false, claims_known_before = true
   where id = (select id from public.study_answer_events where item_id = q1
               order by answered_at desc, id desc limit 1)
     and hinted;
  if not found then
    raise exception 'the fixture''s last answer to q1 was not hinted';
  end if;
  alter table public.study_answer_events enable trigger study_answer_events_are_final;

  -- The wrong answer came more than seven days after a clean one: a seven-day attempt, not
  -- recalled; and it was given when the claim was known: false mastery. The last answer
  -- follows a wrong one, so it is no seven-day attempt. Counted from the UTC week of the
  -- moved answer on.
  since := date_trunc('week', (now() - interval '8 days') at time zone 'UTC')::date;
  perform pg_temp.become_worker();
  select string_agg(format('%s/%s/%s/%s', delayed_attempts, delayed_recalled,
                           answers_when_known, wrong_when_known), ',' order by week)
    into rows
  from ops.study_learning_weekly
  where week >= since;
  if (select sum(delayed_attempts) from ops.study_learning_weekly where week >= since)
     is distinct from 1::bigint
     or (select sum(delayed_recalled) from ops.study_learning_weekly
         where week >= since)
        is distinct from 0::bigint
     or (select sum(answers_when_known) from ops.study_learning_weekly
         where week >= since)
        is distinct from 1::bigint
     or (select sum(wrong_when_known) from ops.study_learning_weekly
         where week >= since)
        is distinct from 1::bigint then
    raise exception 'the learning view is wrong: % (attempts/recalled/known/wrong by week)', rows;
  end if;
  -- The last answer before one is the last in the question's line, however graded: moved to
  -- four days back, the reader's own version answered between the clean one and the wrong
  -- one leaves the wrong one no seven-day attempt.
  perform pg_temp.as_owner();
  alter table public.study_answer_events disable trigger study_answer_events_are_final;
  update public.study_answer_events set answered_at = now() - interval '4 days'
   where item_id = q1_mine;
  alter table public.study_answer_events enable trigger study_answer_events_are_final;
  perform pg_temp.become_worker();
  if (select sum(delayed_attempts) from ops.study_learning_weekly
      where week >= since)
     is distinct from 0::bigint then
    raise exception 'an answer between two was skipped in finding the one before';
  end if;
  -- And the answer before is clean only when it was right, unhinted and graded by the rule.
  -- Moved eight days back, the reader's self-graded "correct" to q3, unhinted, leaves a
  -- deterministic answer to it now no seven-day attempt; nor does a right answer to it moved
  -- between the two, graded by the rule but hinted. Probed, and undone.
  begin
    perform pg_temp.as_owner();
    alter table public.study_answer_events disable trigger study_answer_events_are_final;
    update public.study_answer_events set answered_at = now() - interval '8 days', hinted = false
     where item_id = q3;
    alter table public.study_answer_events enable trigger study_answer_events_are_final;
    perform pg_temp.become_worker();
    attempts := (select sum(delayed_attempts) from ops.study_learning_weekly where week >= since);
    perform pg_temp.become_reader(admitted);
    r := pg_temp.answer(q3, '"restudying"');
    if (r -> 'results' -> 0 ->> 'grading') is distinct from 'deterministic'
       or (r -> 'results' -> 0 ->> 'correct')::boolean is not true then
      raise exception 'the probe''s answer to q3 was not right by the rule: %', r;
    end if;
    perform pg_temp.become_worker();
    if (select sum(delayed_attempts) from ops.study_learning_weekly where week >= since)
       is distinct from attempts then
      raise exception 'a self-graded answer was taken for a clean one before a seven-day attempt';
    end if;
    perform pg_temp.become_reader(admitted);
    r := pg_temp.answer(q3, '"restudying"', null, true);
    if (r -> 'results' -> 0 ->> 'grading') is distinct from 'deterministic'
       or (r -> 'results' -> 0 ->> 'correct')::boolean is not true
       or (r -> 'results' -> 0 ->> 'hinted')::boolean is not true then
      raise exception 'the probe''s hinted answer to q3 was not right by the rule: %', r;
    end if;
    perform pg_temp.as_owner();
    alter table public.study_answer_events disable trigger study_answer_events_are_final;
    update public.study_answer_events set answered_at = now() - interval '9 days'
     where item_id = q3 and grading = 'self';
    update public.study_answer_events set answered_at = now() - interval '8 days'
     where client_event_id = (r -> 'results' -> 0 ->> 'clientEventId')::uuid;
    alter table public.study_answer_events enable trigger study_answer_events_are_final;
    perform pg_temp.become_worker();
    if (select sum(delayed_attempts) from ops.study_learning_weekly where week >= since)
       is distinct from attempts then
      raise exception 'a hinted answer was taken for a clean one before a seven-day attempt';
    end if;
    raise exception using errcode = 'P0001', message = 'probe done';
  exception when raise_exception then
    if sqlerrm is distinct from 'probe done' then raise; end if;
  end;
  -- A day and a week are UTC's whatever the session's zone: under Los Angeles's, every week
  -- is still labelled by its Monday, and everything prepared and spent here by UTC's date
  -- today. Probed, and undone.
  begin
    perform pg_temp.as_owner();
    insert into public.cost_ledger (job_id, provider, operation, unit, quantity, cost_cents)
    values (job, 'test', 'study_extract', 'call', 1, 1);
    perform pg_temp.become_worker();
    set local time zone 'America/Los_Angeles';
    if not exists (select 1 from ops.study_learning_weekly)
       or exists (select 1 from ops.study_learning_weekly where extract(isodow from week) <> 1)
       or exists (select 1 from ops.study_validation_weekly where extract(isodow from week) <> 1)
       or exists (select 1 from ops.study_trust_weekly where extract(isodow from week) <> 1)
       or not exists (select 1 from ops.study_daily)
       or exists (select 1 from ops.study_daily where day <> (now() at time zone 'UTC')::date) then
      raise exception 'a view''s days or weeks moved with the session''s time zone: %',
        (select jsonb_agg(w.week) from ops.study_learning_weekly w);
    end if;
    raise exception using errcode = 'P0001', message = 'probe done';
  exception when raise_exception then
    if sqlerrm is distinct from 'probe done' then raise; end if;
  end;
  -- The mix counts only courses with a current generation.
  if (select courses from ops.study_beta_mix where dimension = 'goal' and value = 'explain')
     is distinct from (select count(*)::int from public.study_courses c
                       where public.study_course_generation(c.id) is not null
                         and public.study_goal_kind(c.goal) = 'explain') then
    raise exception 'the mix counted a course with no current generation';
  end if;

  -- The mix sees the courses with a current generation, by source kind and goal.
  if not exists (select 1 from ops.study_beta_mix
                 where dimension = 'format' and value = 'typed' and courses >= 1)
     or not exists (select 1 from ops.study_beta_mix
                    where dimension = 'goal' and value = 'explain' and courses >= 1) then
    raise exception 'the beta mix missed the fixture course: %',
      (select jsonb_agg(m) from ops.study_beta_mix m);
  end if;
  -- A kind is covered by three courses from two readers, not by two courses or one reader; and
  -- a mix given is the mix read, not added to the one kept: every kind given as covered leaves
  -- none uncovered, whatever the fixture's courses make of the mix.
  select jsonb_agg(jsonb_build_object('dimension', split_part(k, ':', 1),
                                      'value', split_part(k, ':', 2), 'courses', 3, 'readers', 2))
    into r
  from unnest(public.study_beta_unrepresented('[]')) as k;
  if public.study_beta_unrepresented(r) <> '{}'
     or 'format:pdf' = any (public.study_beta_unrepresented(
          '[{"dimension": "format", "value": "pdf", "courses": 3, "readers": 2}]'))
     or not 'format:pdf' = any (public.study_beta_unrepresented(
          '[{"dimension": "format", "value": "pdf", "courses": 2, "readers": 2}]'))
     or not 'format:pdf' = any (public.study_beta_unrepresented(
          '[{"dimension": "format", "value": "pdf", "courses": 3, "readers": 1}]')) then
    raise exception 'the mix''s thresholds are not three courses from two readers: %',
      public.study_beta_unrepresented(r);
  end if;
  if public.study_goal_kind('Explain the argument') is distinct from 'explain'
     or public.study_goal_kind('Prepare for a discussion') is distinct from 'discuss'
     or public.study_goal_kind('Remember the key findings') is distinct from 'remember'
     or public.study_goal_kind('  Prepare for an ASSESSMENT ') is distinct from 'assess'
     or public.study_goal_kind('Learn it for my job') is distinct from 'own'
     or public.study_format_family('pdf_ocr') is distinct from 'scanned' then
    raise exception 'the goal or format kinds are wrong';
  end if;
  -- The other views answer for the service role.
  perform 1 from ops.study_daily;
  perform 1 from ops.study_validation_weekly;
  perform 1 from ops.study_trust_weekly;
  if (select open_to_all from ops.study_beta_status) is not false then
    raise exception 'the status view does not say the beta is closed';
  end if;

  raise notice 'study beta: ok';
end
$test$;

rollback;
