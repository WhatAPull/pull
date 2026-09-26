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


/* An evaluator report that clears the bar, with any field replaced. */
create or replace function pg_temp.report(p_patch jsonb default '{}'::jsonb)
returns jsonb language sql as $fn$
  select jsonb_build_object(
    'counts', jsonb_build_object('sources', 26, 'visibleItems', 320, 'quarantinedItems', 40,
                                 'doubleReviewedVisible', 320, 'usableVisibleItems', 311,
                                 'materialErrors', 0, 'ambiguousVisible', 9,
                                 'adversarialLeaks', 0, 'doubleReviewedAdversarial', 30,
                                 'visibleSources', 25),
    'coverage', jsonb_build_object('present', jsonb_build_array('notes', 'pdf'),
                                   'missing', '[]'::jsonb),
    'gates', jsonb_build_object('minimumFixture', true, 'fixtureCoverage', true,
                                'answersSupported', true, 'ambiguity', true,
                                'adversarial', true, 'ledgerComplete', true, 'ready', true))
  || p_patch
$fn$;
grant execute on function pg_temp.report(jsonb) to service_role;

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
  first_id  uuid;
  r         jsonb;
  state     text;
  rows      text;
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
  perform pg_temp.become_worker();
  insert into public.study_release_gates (recorded_by, fixture_digest, report)
  values ('An operator', repeat('a', 64), pg_temp.report()) returning id into good;
  if (select passed from public.study_release_gates where id = good) is not true then
    raise exception 'a report that clears the bar did not pass';
  end if;

  -- Each shortfall fails, whatever the report's own gates say.
  if public.study_gate_passes(pg_temp.report(jsonb_build_object('counts',
       pg_temp.report() -> 'counts' || '{"visibleItems": 299, "doubleReviewedVisible": 299}')))
     or public.study_gate_passes(pg_temp.report(jsonb_build_object('counts',
       pg_temp.report() -> 'counts' || '{"visibleSources": 23}')))
     or public.study_gate_passes(pg_temp.report(jsonb_build_object('counts',
       pg_temp.report() -> 'counts' || '{"materialErrors": 1}')))
     or public.study_gate_passes(pg_temp.report(jsonb_build_object('counts',
       pg_temp.report() -> 'counts' || '{"ambiguousVisible": 10}')))
     or public.study_gate_passes(pg_temp.report(jsonb_build_object('counts',
       pg_temp.report() -> 'counts' || '{"adversarialLeaks": 1}')))
     or public.study_gate_passes(pg_temp.report(jsonb_build_object('counts',
       pg_temp.report() -> 'counts' || '{"doubleReviewedVisible": 319}')))
     or public.study_gate_passes(pg_temp.report(jsonb_build_object('counts',
       pg_temp.report() -> 'counts' || '{"visibleItems": "320"}')))
     or public.study_gate_passes(pg_temp.report(
       '{"coverage": {"present": [], "missing": ["ocr"]}}'))
     or public.study_gate_passes(pg_temp.report(jsonb_build_object('gates',
       pg_temp.report() -> 'gates' || '{"ledgerComplete": false}')))
     or public.study_gate_passes(pg_temp.report(jsonb_build_object('gates',
       pg_temp.report() -> 'gates' || '{"ready": "true"}')))
     or public.study_gate_passes(pg_temp.report() - 'coverage')
     or public.study_gate_passes('[]'::jsonb) then
    raise exception 'a report short of the bar passed';
  end if;
  -- The boundary: nine ambiguous of three hundred is 3%.
  if not public.study_gate_passes(pg_temp.report(jsonb_build_object('counts',
       pg_temp.report() -> 'counts' || '{"visibleItems": 300, "doubleReviewedVisible": 300}'))) then
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

  -- A passing gate recorded 31 days ago, made as the owner with the trigger held.
  perform pg_temp.as_owner();
  alter table public.study_release_gates disable trigger study_release_gates_recorded;
  insert into public.study_release_gates (recorded_at, recorded_by, fixture_digest, report, passed)
  values (now() - interval '31 days', 'An operator', repeat('c', 64), pg_temp.report(), true)
  returning id into stale;
  alter table public.study_release_gates enable trigger study_release_gates_recorded;

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
  perform pg_temp.become_worker();
  begin
    update public.study_beta_settings set open_to_all = true, gate_id = bad where id;
    raise exception 'the beta opened on a failed gate';
  exception when sqlstate '55000' then null;
  end;
  begin
    update public.study_beta_settings set open_to_all = true, gate_id = stale where id;
    raise exception 'the beta opened on a stale gate';
  exception when sqlstate '55000' then null;
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

  r := public.open_study_beta(good, 'An operator',
                              'Pilot cohort is small; scanned sources ship in the next wave.');
  if (r ->> 'open')::boolean is not true
     or (select open_to_all from public.study_beta_settings) is not true
     or (select override_reason from public.study_beta_log order by id desc limit 1)
        is distinct from 'Pilot cohort is small; scanned sources ship in the next wave.'
     or (select changed_by from public.study_beta_log order by id desc limit 1)
        is distinct from 'An operator' then
    raise exception 'opening on a passing gate with a reason was not done and logged: %', r;
  end if;

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

  perform pg_temp.become_worker();
  perform public.close_study_beta('An operator');
  perform pg_temp.become_reader(outsider);
  if public.study_generation_available() then
    raise exception 'closing the beta did not close it';
  end if;
  perform pg_temp.become_worker();
  if (select count(*) from public.study_beta_log where gate_id = good) is distinct from 2::bigint then
    raise exception 'opening and closing were not both logged';
  end if;

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
  perform public.persist_study_course(job, jsonb_build_object(
    'course', jsonb_build_object('title', 'Immediate versus delayed',
                                 'objectives', jsonb_build_array('Explain the contrast.')),
    'claims', jsonb_build_array(
      pg_temp.claim('s1c1', v, 'At five minutes, restudying beat the recall test.',
                    'the group that restudied remembered more', note)),
    'lessons', jsonb_build_array(pg_temp.lesson('l1', 1, array['s1c1'])),
    'items', jsonb_build_array(
      pg_temp.q('q1', 'l1', 'multiple_choice', 'Which strategy won at five minutes?',
                'Restudying', array['s1c1'], jsonb_build_object('distractors',
                  jsonb_build_array(
                    jsonb_build_object('text', 'The recall test', 'why', 'Only after a week.'),
                    jsonb_build_object('text', 'Neither', 'why', 'The note reports a winner.'))))),
    'provenance', jsonb_build_object('promptHash', repeat('a', 64),
                                     'schemaHash', repeat('b', 64), 'model', 'm')));
  perform public.validate_study_course(job);
  perform pg_temp.as_owner();
  update public.generation_jobs set status = 'succeeded' where id = job;
  select id into q1 from public.study_items where generation_id = gen and item_key = 'q1';

  perform pg_temp.become_reader(admitted);
  r := pg_temp.answer(q1, '"Restudying"');
  first_id := (select id from public.study_answer_events where item_id = q1
               order by answered_at, id limit 1);
  if (select claims_known_before from public.study_answer_events where id = first_id)
     is distinct from false then
    raise exception 'a first answer was stamped as given when the claim was known';
  end if;
  -- Known now: the next answer is stamped so, and a wrong one is false mastery.
  if (select known from public.study_claim_knowledge(course) limit 1) is distinct from true then
    raise exception 'the fixture''s proof did not make its claim known';
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
  -- One definition of known: the course's knowledge agrees with the per-claim function.
  if exists (select 1 from public.study_claim_knowledge(course) k
             join public.study_claims c on c.id = k.claim_id
             where k.known is distinct from public.study_claim_known(c.owner_id, c.id, now())) then
    raise exception 'study_claim_knowledge and study_claim_known disagree';
  end if;

  -- ---------------------------------------------------------------- the learning measures
  -- The first, clean answer moved eight days back: the next deterministic answer is a
  -- seven-day attempt.
  perform pg_temp.as_owner();
  alter table public.study_answer_events disable trigger study_answer_events_are_final;
  update public.study_answer_events set answered_at = now() - interval '8 days'
   where id = first_id;
  alter table public.study_answer_events enable trigger study_answer_events_are_final;

  -- The wrong answer came more than seven days after a clean one: a seven-day attempt, not
  -- recalled; and it was given when the claim was known: false mastery. The last answer
  -- follows a wrong one, so it is no seven-day attempt.
  perform pg_temp.become_worker();
  select string_agg(format('%s/%s/%s/%s', delayed_attempts, delayed_recalled,
                           answers_when_known, wrong_when_known), ',' order by week)
    into rows
  from ops.study_learning_weekly
  where week >= date_trunc('week', now() - interval '8 days')::date;
  if (select sum(delayed_attempts) from ops.study_learning_weekly
      where week >= date_trunc('week', now() - interval '8 days')::date) is distinct from 1::bigint
     or (select sum(delayed_recalled) from ops.study_learning_weekly
         where week >= date_trunc('week', now() - interval '8 days')::date)
        is distinct from 0::bigint
     or (select sum(answers_when_known) from ops.study_learning_weekly
         where week >= date_trunc('week', now() - interval '8 days')::date)
        is distinct from 1::bigint
     or (select sum(wrong_when_known) from ops.study_learning_weekly
         where week >= date_trunc('week', now() - interval '8 days')::date)
        is distinct from 1::bigint then
    raise exception 'the learning view is wrong: % (attempts/recalled/known/wrong by week)', rows;
  end if;

  -- The mix sees the courses with a current generation, by source kind and goal.
  if not exists (select 1 from ops.study_beta_mix
                 where dimension = 'format' and value = 'typed' and courses >= 1)
     or not exists (select 1 from ops.study_beta_mix
                    where dimension = 'goal' and value = 'explain' and courses >= 1) then
    raise exception 'the beta mix missed the fixture course: %',
      (select jsonb_agg(m) from ops.study_beta_mix m);
  end if;
  if public.study_goal_kind('  Prepare for an ASSESSMENT ') is distinct from 'assess'
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
