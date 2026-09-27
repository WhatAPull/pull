-- Rights-cleared public study courses (20260925230000): published by the service role from a
-- curator's course of a cleared work's registered text, with capped quotations; read through
-- the catalogue functions by signed-in readers; enrolled by copy into a reader's own tables,
-- where everything per reader works as on any course; withdrawn, and the copies removed in
-- batches. Readers run as `authenticated`, so RLS is in force for every reader assertion.
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

create or replace function pg_temp.become_visitor()
returns void language plpgsql as $fn$
begin
  perform set_config('role', 'anon', true);
  perform set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
  if current_user <> 'anon' then
    raise exception 'visitor assertions must run as anon, not %', current_user;
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

grant execute on function pg_temp.become_reader(uuid) to authenticated, service_role, anon;
grant execute on function pg_temp.become_visitor() to authenticated, service_role, anon;
grant execute on function pg_temp.become_worker() to authenticated, service_role, anon;
grant execute on function pg_temp.as_owner() to authenticated, service_role, anon;

/* Run a statement: 'ok', or its SQLSTATE and DETAIL. Its effects stand only if it is 'ok'. */
create or replace function pg_temp.refusal(p_sql text)
returns text language plpgsql as $fn$
declare st text; dt text;
begin
  execute p_sql;
  return 'ok';
exception when others then
  get stacked diagnostics st = returned_sqlstate, dt = pg_exception_detail;
  return st || coalesce(' ' || nullif(dt, ''), '');
end $fn$;

create or replace function pg_temp.expect(p_want text, p_sql text, p_what text)
returns void language plpgsql as $fn$
declare got text := pg_temp.refusal(p_sql);
begin
  if got is distinct from p_want then
    raise exception '%: wanted %, got %', p_what, p_want, got;
  end if;
end $fn$;

grant execute on function pg_temp.refusal(text) to authenticated, service_role, anon;
grant execute on function pg_temp.expect(text, text, text) to authenticated, service_role, anon;

/* A claim quoting `p_len` characters of `p_note` from `p_start`. */
create or replace function pg_temp.claim(
  p_key text, p_version uuid, p_statement text, p_note text, p_start int, p_len int
)
returns jsonb language sql as $fn$
  select jsonb_build_object(
    'key', p_key, 'sourceVersionId', p_version, 'kind', 'finding', 'statement', p_statement,
    'status', 'draft',
    'evidence', jsonb_build_array(jsonb_build_object(
      'modelQuote', substr(p_note, p_start + 1, p_len),
      'spanText', substr(p_note, p_start + 1, p_len),
      'start', p_start, 'end', p_start + p_len, 'match', 'exact')),
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

/* A multiple-choice question on `p_claims`. */
create or replace function pg_temp.q(
  p_key text, p_lesson text, p_prompt text, p_answer text, p_claims text[]
)
returns jsonb language sql as $fn$
  select jsonb_build_object(
    'key', p_key, 'lessonKey', p_lesson, 'purpose', 'practice', 'kind', 'multiple_choice',
    'prompt', p_prompt, 'answer', p_answer, 'acceptedAnswers', '[]'::jsonb,
    'distractors', jsonb_build_array(
      jsonb_build_object('text', 'Neither group', 'why', 'The note reports a difference.'),
      jsonb_build_object('text', 'Both groups equally', 'why', 'The note reports a difference.')),
    'cloze', null, 'sequence', '[]'::jsonb, 'pairs', '[]'::jsonb,
    'explanation', 'Because the note says so.', 'difficulty', 1, 'status', 'draft',
    'claimKeys', to_jsonb(p_claims))
$fn$;

/*
 * Prepare a course as `p_owner` from `p_versions` -- or prepare `p_course` again -- persist
 * `p_payload` as its text, validate it and finish its job: the generation. The payload's
 * `course` fields are added to a title and an objective.
 */
create or replace function pg_temp.prepare(
  p_owner uuid, p_versions uuid[], p_payload jsonb, p_course uuid default null
)
returns uuid language plpgsql as $fn$
declare out jsonb; job uuid;
begin
  perform pg_temp.become_reader(p_owner);
  if p_course is null then
    out := public.enqueue_study_generation(p_versions, 'Explain the argument',
                                           extensions.gen_random_uuid(), true);
  else
    out := public.regenerate_study_course(p_course, extensions.gen_random_uuid(), true);
  end if;
  job := (out ->> 'jobId')::uuid;
  perform pg_temp.become_worker();
  perform public.persist_study_course(job, p_payload || jsonb_build_object(
    'course', jsonb_build_object('title', 'Immediate versus delayed',
                                 'objectives', jsonb_build_array('Explain the contrast.'))
              || coalesce(p_payload -> 'course', '{}'::jsonb),
    'provenance', jsonb_build_object('promptHash', repeat('a', 64),
                                     'schemaHash', repeat('b', 64), 'model', 'm')));
  perform public.validate_study_course(job);
  perform pg_temp.as_owner();
  update public.generation_jobs set status = 'succeeded' where id = job;
  return (out ->> 'generationId')::uuid;
end $fn$;

/* Save `p_text` as `p_owner`'s source (or a new version of `p_source`): the version. */
create or replace function pg_temp.save(p_owner uuid, p_text text, p_source uuid default null)
returns uuid language plpgsql as $fn$
begin
  perform pg_temp.become_reader(p_owner);
  return (public.save_study_source_version('Roediger and Karpicke', 'paste', p_text,
                                           extensions.gen_random_uuid(), p_source)
          ->> 'versionId')::uuid;
end $fn$;

/*
 * What the beta's dashboards (20260925220000) add up to, as the owner reads them: every count
 * each view keeps of courses, generations, answers, reading, reports and changes.
 */
create or replace function pg_temp.beta_totals()
returns jsonb language sql as $fn$
  select jsonb_build_object(
    'mix', (select coalesce(sum(courses), 0) from ops.study_beta_mix),
    'daily', (select coalesce(sum(courses_created + readers_creating + jobs), 0)
              from ops.study_daily),
    'validation', (select coalesce(sum(generations + awaiting_validation + held_back
                                       + claims_validated + claims_quarantined
                                       + lessons_validated + lessons_quarantined
                                       + questions_validated + questions_quarantined), 0)
                   from ops.study_validation_weekly),
    'learning', (select coalesce(sum(answers + right_unhinted), 0) from ops.study_learning_weekly),
    'trust', (select coalesce(sum(lessons_shown + lessons_read + lessons_skipped + questions_shown
                                  + reports + withdrawn + corrected), 0)
              from ops.study_trust_weekly))
$fn$;

/* Record one answer and hand back its result. */
create or replace function pg_temp.answer(p_item uuid, p_response jsonb)
returns jsonb language sql as $fn$
  select public.record_study_answers(jsonb_build_array(jsonb_build_object(
    'clientEventId', extensions.gen_random_uuid(), 'itemId', p_item, 'response', p_response)))
$fn$;

grant execute on function pg_temp.claim(text, uuid, text, text, int, int)
  to authenticated, service_role;
grant execute on function pg_temp.lesson(text, int, text[]) to authenticated, service_role;
grant execute on function pg_temp.q(text, text, text, text, text[]) to authenticated, service_role;
grant execute on function pg_temp.prepare(uuid, uuid[], jsonb, uuid) to authenticated, service_role;
grant execute on function pg_temp.save(uuid, text, uuid) to authenticated, service_role;
grant execute on function pg_temp.answer(uuid, jsonb) to authenticated;

do $test$
declare
  curator   uuid := extensions.gen_random_uuid();
  stranger  uuid := extensions.gen_random_uuid();
  reader    uuid := extensions.gen_random_uuid();
  other     uuid := extensions.gen_random_uuid();
  busy      uuid := extensions.gen_random_uuid();
  guest     uuid := extensions.gen_random_uuid();
  -- Long enough that its quotations are well under a tenth of it. Offsets: "Roediger ... prose"
  -- 0-45, "the group that restudied remembered more" 83-123, "the group that had taken the
  -- recall test remembered more" 169-225; then 30 sentences of 89 characters from 227.
  note      text := 'Roediger and Karpicke had students read prose. On a final test five '
                    'minutes later, the group that restudied remembered more. On final tests '
                    'two days and one week later, the group that had taken the recall test '
                    'remembered more. ' || repeat('The passage went on at length about the '
                    'history of the study and its setting in the lab. ', 30);
  -- The note and as much again: a source whose tenth is more than 300 characters.
  longer    text;
  -- The note, ended otherwise: a short work's text of its own. The note's tenth is shared with
  -- the course published from it, whatever work quotes the note.
  short     text;
  -- 3,000 characters, whose tenth is 300 exactly; and a text of 1,000 and another of 3,000.
  essay     text;
  part      text;
  sequel    text;
  -- Twelve words in a row of the passage the course does not quote, cased and punctuated
  -- otherwise: "on at length about the history of the study and its setting".
  repeated  text := 'Why does it go ON AT LENGTH, about the history of the study -- and its setting?';
  pd_work   uuid;
  lic_work  uuid;
  own_work  uuid;
  rev_work  uuid;
  day_work  uuid;
  short_work uuid;
  tenth_work uuid;
  twin_work uuid;
  pair_work uuid;
  v         uuid;
  v2        uuid;
  v3        uuid;
  v_other   uuid;
  gen       uuid;
  gen2      uuid;
  course    uuid;
  pub       uuid;
  lic_pub   uuid;
  filler    uuid;
  totals    jsonb;
  p_gen     uuid;
  p_lesson  uuid;
  p_item    uuid;
  copy      uuid;
  copy_gen  uuid;
  cur_copy  uuid;
  excerpt   uuid;
  l1        uuid;
  l2        uuid;
  l3        uuid;
  q2        uuid;
  item      uuid;
  pc        public.public_study_courses%rowtype;
  quoting   record;
  day_ids   uuid[] := '{}';
  withdrawn timestamptz;
  r         jsonb;
  n         int;
  d         int;
  s         text;
begin
  insert into auth.users
    (id, instance_id, aud, role, email, encrypted_password,
     email_confirmed_at, created_at, updated_at, is_anonymous,
     raw_app_meta_data, raw_user_meta_data)
  select u, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
         case when u = guest then null else 'public-course-' || u || '@example.test' end, '',
         now(), now(), now(), u = guest, '{}', '{}'
  from unnest(array[curator, stranger, reader, other, busy, guest]) as u;
  -- The curator and the stranger may prepare courses; the readers are not on the allowlist,
  -- and do not need to be.
  insert into public.study_generation_access (user_id) values (curator), (stranger);
  insert into public.study_curators (user_id, added_by) values (curator, 'Public courses test');
  insert into public.works (kind, title, slug, rights_status) values
    ('paper', 'Test-enhanced learning', 'test-public-course-pd', 'public_domain'),
    ('paper', 'A licensed paper', 'test-public-course-licensed', 'licensed'),
    ('essay', 'A reader''s own essay', 'test-public-course-own', 'user_owned'),
    ('essay', 'An unresolved essay', 'test-public-course-review', 'review_required'),
    ('paper', 'A paper for the day''s limit', 'test-public-course-day', 'public_domain'),
    ('essay', 'A short licensed essay', 'test-public-course-short', 'licensed'),
    ('essay', 'An essay quoted to a tenth', 'test-public-course-tenth', 'licensed'),
    ('essay', 'The same essay, as another work', 'test-public-course-twin', 'public_domain'),
    ('essay', 'An essay in two parts', 'test-public-course-pair', 'licensed');
  select id into pd_work from public.works where slug = 'test-public-course-pd';
  select id into lic_work from public.works where slug = 'test-public-course-licensed';
  select id into own_work from public.works where slug = 'test-public-course-own';
  select id into rev_work from public.works where slug = 'test-public-course-review';
  select id into day_work from public.works where slug = 'test-public-course-day';
  select id into short_work from public.works where slug = 'test-public-course-short';
  select id into tenth_work from public.works where slug = 'test-public-course-tenth';
  select id into twin_work from public.works where slug = 'test-public-course-twin';
  select id into pair_work from public.works where slug = 'test-public-course-pair';
  longer := note || repeat('The passage went on at length about the history of the study and '
                           'its setting in the lab. ', 30);
  short := note || ' The note ends.';
  select left(string_agg(format('Sentence %s of the essay makes point %s carefully. ', k, k), ''),
              2999) || '.'
    into essay from generate_series(1, 100) k;
  select left(string_agg(format('Line %s of part one says %s plainly. ', k, k), ''), 1000)
    into part from generate_series(1, 60) k;
  select left(string_agg(format('Sentence %s of part two makes point %s carefully. ', k, k), ''),
              3000)
    into sequel from generate_series(1, 100) k;

  -- ---------------------------------------------------------------- the curator's course
  v := pg_temp.save(curator, note);
  perform pg_temp.become_reader(curator);
  r := public.enqueue_study_generation(array[v], 'Explain the argument',
                                       extensions.gen_random_uuid(), true);
  gen := (r ->> 'generationId')::uuid;
  course := (r ->> 'courseId')::uuid;
  perform pg_temp.become_worker();
  perform public.persist_study_course((r ->> 'jobId')::uuid, jsonb_build_object(
    -- Its overview shares eleven words in a row with the passage it does not quote -- "on at
    -- length about the history of the study and its" -- which is not twelve. Three
    -- disagreements: one between claims that are published, one naming the claim the review
    -- holds back, and one naming no claim at all.
    'course', jsonb_build_object(
      'title', 'Immediate versus delayed',
      'objectives', jsonb_build_array('Explain the contrast.'),
      'overview', 'The note goes on at length about the history of the study and its lab.',
      'disagreements', jsonb_build_array(
        jsonb_build_object('claimKeys', jsonb_build_array('s1c1', 's1c2'),
                           'description', 'Early on restudying wins; later the test does.'),
        jsonb_build_object('claimKeys', jsonb_build_array('s1c2', 's1c3'),
                           'description', 'What the students read is said to decide it.'),
        jsonb_build_object('claimKeys', '[]'::jsonb,
                           'description', 'Something is said to disagree with something.'))),
    'claims', jsonb_build_array(
      pg_temp.claim('s1c1', v, 'At five minutes, restudying beat the recall test.', note, 83, 40),
      pg_temp.claim('s1c2', v, 'After a week, the recall test group remembered more.', note, 169, 56),
      pg_temp.claim('s1c3', v, 'The students read prose.', note, 0, 45)),
    'lessons', jsonb_build_array(
      pg_temp.lesson('l1', 1, array['s1c1']),
      pg_temp.lesson('l2', 2, array['s1c2']),
      pg_temp.lesson('l3', 3, array['s1c3']),
      pg_temp.lesson('l4', 4, array['s1c1'])),
    'items', jsonb_build_array(
      pg_temp.q('q1', 'l2', 'Which group remembered more after a week?', 'The recall test group',
                array['s1c2']),
      pg_temp.q('q2', 'l1', 'Which group remembered more at five minutes?', 'The restudy group',
                array['s1c1']),
      pg_temp.q('q3', 'l3', 'What did the students read?', 'Prose', array['s1c3']),
      pg_temp.q('q4', 'l4', 'Which group did better early on?', 'The restudy group',
                array['s1c1'])),
    'provenance', jsonb_build_object('promptHash', repeat('a', 64),
                                     'schemaHash', repeat('b', 64), 'model', 'm')));

  -- ---------------------------------------------------------------- what is not published
  perform pg_temp.expect('55000 unvalidated',
    format('select public.publish_study_course(%L, %L, %L, %L)', gen, pd_work, 'test-early', 'R'),
    'a course published before validation');
  perform public.validate_study_course((r ->> 'jobId')::uuid);
  perform pg_temp.as_owner();
  update public.generation_jobs set status = 'succeeded' where id = (r ->> 'jobId')::uuid;
  select id into l1 from public.study_lessons where generation_id = gen and lesson_key = 'l1';
  select id into l2 from public.study_lessons where generation_id = gen and lesson_key = 'l2';
  select id into l3 from public.study_lessons where generation_id = gen and lesson_key = 'l3';
  select id into q2 from public.study_items where generation_id = gen and item_key = 'q2';
  if (select count(*) from public.study_claims where generation_id = gen and status = 'validated') <> 3
     or (select count(*) from public.study_lessons where generation_id = gen and status = 'validated') <> 4
     or (select count(*) from public.study_items where generation_id = gen and status = 'validated') <> 4 then
    raise exception 'the curator''s course did not validate whole';
  end if;

  -- In review, the curator holds back one claim -- its lesson and question go with it -- and
  -- one lesson on its own, whose question stays; and corrects a lesson and a question.
  perform pg_temp.become_reader(curator);
  perform public.report_study_content('claim',
    (select id from public.study_claims where generation_id = gen and claim_key = 's1c3'),
    'incorrect', null);
  perform public.report_study_content('lesson',
    (select id from public.study_lessons where generation_id = gen and lesson_key = 'l4'),
    'incorrect', null);
  l1 := public.revise_study_lesson(l1,
    '{"explanation": "Restudying won at five minutes, and only then."}');
  q2 := public.revise_study_item(q2, '{"prompt": "At five minutes, which group remembered more?"}');
  if (select status from public.study_lessons where id = l3) = 'validated'
     or (select status from public.study_lessons where generation_id = gen and lesson_key = 'l4')
        = 'validated'
     or (select status from public.study_items where generation_id = gen and item_key = 'q4')
        <> 'validated'
     or (select authored_by from public.study_lessons where id = l1) <> 'reader'
     or (select authored_by from public.study_items where id = q2) <> 'reader' then
    raise exception 'the review did not hold back and correct as expected';
  end if;

  -- A reader cannot publish, withdraw or remove, nor read what publishing reads.
  perform pg_temp.expect('42501',
    format('select public.publish_study_course(%L, %L, %L, %L)', gen, pd_work, 'test-mine', 'Me'),
    'a reader published');
  perform pg_temp.expect('42501',
    format('select public.withdraw_public_study_course(%L, %L, %L)', gen, 'Me', 'Why'),
    'a reader withdrew');
  perform pg_temp.expect('42501',
    format('select public.remove_public_course_copies(%L, 1)', gen), 'a reader removed copies');
  perform pg_temp.expect('42501', 'select 1 from public.study_curators',
    'a reader read the curators');
  perform pg_temp.expect('42501', 'select 1 from public.study_curated_sources',
    'a reader read the registered sources');
  perform pg_temp.expect('42501', 'select 1 from public.public_study_courses',
    'a reader read the published table');

  perform pg_temp.become_worker();
  -- The text is not registered as the work's yet; then it is registered to another work.
  perform pg_temp.expect('42501 unregistered',
    format('select public.publish_study_course(%L, %L, %L, %L)', gen, pd_work, 'test-unregistered', 'R'),
    'a course of unregistered text was published');
  perform pg_temp.as_owner();
  insert into public.study_curated_sources (source_version_id, work_id, registered_by)
  values (v, lic_work, 'Public courses test');
  perform pg_temp.become_worker();
  perform pg_temp.expect('42501 unregistered',
    format('select public.publish_study_course(%L, %L, %L, %L)', gen, pd_work, 'test-other-work', 'R'),
    'a course of another work''s text was published');
  perform pg_temp.as_owner();
  update public.study_curated_sources set work_id = pd_work where source_version_id = v;
  perform pg_temp.become_worker();

  -- Rights: never a reader's own work, nor one awaiting a rights review.
  perform pg_temp.expect('42501 rights',
    format('select public.publish_study_course(%L, %L, %L, %L)', gen, own_work, 'test-own', 'R'),
    'a course of a reader''s own work was published');
  perform pg_temp.expect('42501 rights',
    format('select public.publish_study_course(%L, %L, %L, %L)', gen, rev_work, 'test-review', 'R'),
    'a course of a work under rights review was published');
  perform pg_temp.expect('P0002',
    format('select public.publish_study_course(%L, %L, %L, %L)', gen,
           extensions.gen_random_uuid(), 'test-no-work', 'R'),
    'a course of no work was published');
  perform pg_temp.expect('P0002',
    format('select public.publish_study_course(%L, %L, %L, %L)', extensions.gen_random_uuid(),
           pd_work, 'test-no-generation', 'R'),
    'no generation was published');
  perform pg_temp.expect('22023',
    format('select public.publish_study_course(%L, %L, %L, %L)', gen, pd_work, 'Not A Slug!', 'R'),
    'a bad slug was accepted');
  perform pg_temp.expect('22023',
    format('select public.publish_study_course(%L, %L, %L, %L)', gen, pd_work, 'test-nobody', '  '),
    'a course was published with nobody named as its reviewer');

  -- Quotations over a tenth of the source: the same spans in a short source.
  perform pg_temp.as_owner();
  update public.study_source_versions set extracted_text = left(note, 400) where id = v;
  perform pg_temp.become_worker();
  perform pg_temp.expect('22023 quotes',
    format('select public.publish_study_course(%L, %L, %L, %L)', gen, pd_work, 'test-tenth', 'R'),
    'quotations of more than a tenth of the source were published');
  perform pg_temp.as_owner();
  update public.study_source_versions set extracted_text = note where id = v;

  -- A work's courses quote it at most 20,000 characters between them -- a withdrawn course's
  -- too, whose readers keep their copies. A course deleted -- withdrawn, and with no copies
  -- left -- no longer counts. The filler quotes under a tenth of another text of the work:
  -- 19,858 characters, with this course's 142 exactly 20,000. Probed, and undone.
  begin
    insert into public.public_study_courses
      (slug, work_id, title, goal, excerpt_title, excerpts, quotations, snapshot, outline,
       lesson_count, question_count, reviewed_by)
    values ('test-filler', pd_work, 'Filler', 'Filler', 'Filler', repeat('x', 19858),
            jsonb_build_array(jsonb_build_object('sha256', repeat('0', 64), 'chars', 200000,
                                                 'from', 0, 'to', 19858, 'at', 0)),
            '{}', '[]', 1, 0, 'Public courses test');
    perform pg_temp.become_worker();
    perform pg_temp.expect('ok',
      format('select public.publish_study_course(%L, %L, %L, %L)', gen, pd_work, 'test-work-cap', 'R'),
      'a work''s courses were refused quoting it 20,000 characters');
    raise exception using errcode = 'P0001', message = 'probe done';
  exception when raise_exception then
    if sqlerrm is distinct from 'probe done' then raise; end if;
  end;
  -- One character more, 20,001, is over.
  perform pg_temp.as_owner();
  insert into public.public_study_courses
    (slug, work_id, title, goal, excerpt_title, excerpts, quotations, snapshot, outline,
     lesson_count, question_count, reviewed_by)
  values ('test-filler', pd_work, 'Filler', 'Filler', 'Filler', repeat('x', 19859),
          jsonb_build_array(jsonb_build_object('sha256', repeat('0', 64), 'chars', 200000,
                                               'from', 0, 'to', 19859, 'at', 0)),
          '{}', '[]', 1, 0, 'Public courses test')
  returning id into filler;
  perform pg_temp.become_worker();
  perform pg_temp.expect('22023 quotes',
    format('select public.publish_study_course(%L, %L, %L, %L)', gen, pd_work, 'test-work-cap', 'R'),
    'a work''s courses were published quoting it 20,001 characters');
  perform public.withdraw_public_study_course(filler, 'Public courses test', 'Only filler.');
  perform pg_temp.expect('22023 quotes',
    format('select public.publish_study_course(%L, %L, %L, %L)', gen, pd_work, 'test-work-cap', 'R'),
    'a withdrawn course''s quotations were not counted');
  perform pg_temp.as_owner();
  delete from public.public_study_courses where id = filler;
  -- A withdrawn course of another work, for the catalogue and enrolling to refuse below.
  insert into public.public_study_courses
    (slug, work_id, title, goal, excerpt_title, excerpts, quotations, snapshot, outline,
     lesson_count, question_count, reviewed_by, withdrawn_at, withdrawn_reason)
  values ('test-filler', day_work, 'Filler', 'Filler', 'Filler', 'x',
          jsonb_build_array(jsonb_build_object('sha256', repeat('0', 64), 'chars', 200000,
                                               'from', 0, 'to', 1, 'at', 0)),
          '{}', '[]', 1, 0, 'Public courses test', now(), 'Only filler.')
  returning id into filler;

  -- The course's own words may not repeat the source outside its quotations -- twelve words in
  -- a row of the passage that is not quoted -- but may repeat what it quotes.
  perform pg_temp.become_reader(curator);
  l2 := public.revise_study_lesson(l2, '{"explanation": "It went on at length about the history '
                                       'of the study and its setting in the lab."}');
  perform pg_temp.become_worker();
  perform pg_temp.expect('22023 copied',
    format('select public.publish_study_course(%L, %L, %L, %L)', gen, pd_work, 'test-copied', 'R'),
    'a course repeating the unquoted source was published');
  perform pg_temp.become_reader(curator);
  l2 := public.revise_study_lesson(l2, '{"explanation": "On final tests two days and one week '
                                       'later, the group that had taken the recall test did better."}');
  -- ...nor in a question, a claim or the overview, whatever its case and punctuation: each in a
  -- course of its own, from the same text.
  v2 := pg_temp.save(curator, note);
  perform pg_temp.as_owner();
  insert into public.study_curated_sources (source_version_id, work_id, registered_by)
  values (v2, pd_work, 'Public courses test');
  foreach s in array array['question', 'claim', 'overview'] loop
    gen2 := pg_temp.prepare(curator, array[v2], jsonb_build_object(
      'course', case when s = 'overview' then jsonb_build_object('overview', repeated)
                     else '{}'::jsonb end,
      'claims', jsonb_build_array(pg_temp.claim('s1c1', v2,
        case when s = 'claim' then repeated else 'Restudying won early.' end, note, 83, 40)),
      'lessons', jsonb_build_array(pg_temp.lesson('l1', 1, array['s1c1'])),
      'items', jsonb_build_array(pg_temp.q('q1', 'l1',
        case when s = 'question' then repeated else 'Which group won early?' end,
        'The restudy group', array['s1c1']))));
    perform pg_temp.become_worker();
    perform pg_temp.expect('22023 copied',
      format('select public.publish_study_course(%L, %L, %L, %L)', gen2, pd_work,
             'test-copied-' || s, 'R'),
      format('a course repeating the unquoted source in its %s was published', s));
  end loop;

  -- ---------------------------------------------------------------- publishing
  perform pg_temp.become_worker();
  r := public.publish_study_course(gen, pd_work, 'test-immediate-versus-delayed', 'A reviewer',
                                   'Checked against the paper.');
  pub := (r ->> 'id')::uuid;
  -- Two lessons and two questions: the third of each is held back with its claim.
  if (r ->> 'lessons')::int is distinct from 2 or (r ->> 'questions')::int is distinct from 2
     or (r ->> 'quoted')::int is distinct from 142 then
    raise exception 'the published course is not the validated one: %', r;
  end if;
  perform pg_temp.as_owner();
  select * into pc from public.public_study_courses where id = pub;
  -- One quotation: the two spans lie 46 characters apart, so they are quoted as one passage,
  -- gap and all; the held-back claim's span, 38 characters before it, is not quoted at all.
  if pc.excerpts is distinct from substr(note, 84, 142) then
    raise exception 'the excerpts are %', pc.excerpts;
  end if;
  -- And what it quotes is recorded against the text, by its hash: where in it, and where in
  -- the excerpts.
  if pc.quotations is distinct from jsonb_build_array(jsonb_build_object(
       'sha256', encode(sha256(convert_to(note, 'UTF8')), 'hex'), 'chars', char_length(note),
       'from', 83, 'to', 225, 'at', 0)) then
    raise exception 'the quotations are recorded as %', pc.quotations;
  end if;
  -- Only the disagreement between two published claims goes with it; the one naming the claim
  -- held back does not, nor the one naming none, which is about nothing the course says.
  if pc.snapshot -> 'disagreements' is distinct from jsonb_build_array(jsonb_build_object(
       'claimKeys', jsonb_build_array('s1c1', 's1c2'),
       'description', 'Early on restudying wins; later the test does.')) then
    raise exception 'the published disagreements are %', pc.snapshot -> 'disagreements';
  end if;
  if pc.from_generation is distinct from gen or pc.work_id is distinct from pd_work
     or pc.lesson_count <> 2 or pc.question_count <> 2
     or jsonb_array_length(pc.snapshot -> 'claims') <> 2
     or jsonb_array_length(pc.outline) <> 2 then
    raise exception 'the published row is not the snapshot: %', to_jsonb(pc) - 'excerpts';
  end if;
  -- Each evidence span points into the excerpts at its place in the quotation.
  if exists (select 1 from jsonb_array_elements(pc.snapshot -> 'claims') c
             cross join jsonb_array_elements(c -> 'evidence') e
             where substr(pc.excerpts, (e ->> 'start')::int + 1, char_length(e ->> 'spanText'))
                   is distinct from e ->> 'spanText') then
    raise exception 'an evidence span does not point at its quotation: %', pc.snapshot -> 'claims';
  end if;
  -- Who wrote what goes with it: the corrections are the curator's, the rest the model's.
  if (select string_agg((l ->> 'key') || ':' || (l ->> 'authoredBy'), ',' order by l ->> 'key')
      from jsonb_array_elements(pc.snapshot -> 'lessons') l) is distinct from 'l1:reader,l2:reader'
     or (select string_agg((i ->> 'key') || ':' || (i ->> 'authoredBy') || ':' || (i ->> 'lessonKey'),
                           ',' order by i ->> 'key')
         from jsonb_array_elements(pc.snapshot -> 'items') i)
        is distinct from 'q1:model:l2,q2:reader:l1' then
    raise exception 'the snapshot lost who wrote it, or a question''s lesson: %', pc.snapshot;
  end if;
  if not exists (select 1 from public.moderation_decisions
                 where action = 'publish_study_course' and rationale like '%' || pub::text || '%') then
    raise exception 'publishing recorded no moderation decision';
  end if;
  perform pg_temp.become_worker();
  perform pg_temp.expect('55000 published',
    format('select public.publish_study_course(%L, %L, %L, %L)', gen, pd_work, 'test-twice', 'R'),
    'one generation was published twice');

  -- Not a curator's course: refused, however well registered and cleared.
  v_other := pg_temp.save(stranger, note);
  perform pg_temp.as_owner();
  insert into public.study_curated_sources (source_version_id, work_id, registered_by)
  values (v_other, pd_work, 'Public courses test');
  gen2 := pg_temp.prepare(stranger, array[v_other], jsonb_build_object(
    'claims', jsonb_build_array(
      pg_temp.claim('s1c1', v_other, 'Restudying won early.', note, 83, 40)),
    'lessons', jsonb_build_array(pg_temp.lesson('l1', 1, array['s1c1'])),
    'items', '[]'::jsonb));
  perform pg_temp.become_worker();
  perform pg_temp.expect('42501 curator',
    format('select public.publish_study_course(%L, %L, %L, %L)', gen2, pd_work, 'test-stranger', 'R'),
    'a course that is not a curator''s was published');

  -- Too large: more than 300 questions.
  v2 := pg_temp.save(curator, note || ' Again.');
  perform pg_temp.as_owner();
  insert into public.study_curated_sources (source_version_id, work_id, registered_by)
  values (v2, pd_work, 'Public courses test');
  gen2 := pg_temp.prepare(curator, array[v2], jsonb_build_object(
    'claims', jsonb_build_array(pg_temp.claim('s1c1', v2, 'Restudying won early.', note, 83, 40)),
    'lessons', jsonb_build_array(pg_temp.lesson('l1', 1, array['s1c1'])),
    'items', (select jsonb_agg(pg_temp.q('q' || k, 'l1', 'Which group won, case ' || k || '?',
                                         'The restudy group', array['s1c1']))
              from generate_series(1, 301) k)));
  perform pg_temp.become_worker();
  perform pg_temp.expect('22023 too_large',
    format('select public.publish_study_course(%L, %L, %L, %L)', gen2, pd_work, 'test-large', 'R'),
    'a course of 301 questions was published');

  -- Quotations: overlapping or near spans are one quotation, and a quotation is at most 300
  -- characters. Two sentences of 88 characters, 179 apart, quote 355 characters as one -- in a
  -- source long enough that 355 is under a tenth of it.
  v2 := pg_temp.save(curator, longer);
  perform pg_temp.as_owner();
  insert into public.study_curated_sources (source_version_id, work_id, registered_by)
  values (v2, lic_work, 'Public courses test');
  gen2 := pg_temp.prepare(curator, array[v2], jsonb_build_object(
    'claims', jsonb_build_array(
      pg_temp.claim('s1c1', v2, 'The passage described the setting.', note, 227, 88),
      pg_temp.claim('s1c2', v2, 'It described it again.', note, 227 + 3 * 89, 88)),
    'lessons', jsonb_build_array(pg_temp.lesson('l1', 1, array['s1c1', 's1c2'])),
    'items', '[]'::jsonb));
  perform pg_temp.become_worker();
  perform pg_temp.expect('22023 quotes',
    format('select public.publish_study_course(%L, %L, %L, %L)', gen2, lic_work, 'test-long', 'R'),
    'a 355-character quotation of two near spans was published');
  -- 268 characters apart they are two quotations, each re-pointed into its own excerpt.
  v2 := pg_temp.save(curator, longer || ' Again.');
  perform pg_temp.as_owner();
  insert into public.study_curated_sources (source_version_id, work_id, registered_by)
  values (v2, lic_work, 'Public courses test');
  gen2 := pg_temp.prepare(curator, array[v2], jsonb_build_object(
    'claims', jsonb_build_array(
      pg_temp.claim('s1c1', v2, 'The passage described the setting.', note, 227, 88),
      pg_temp.claim('s1c2', v2, 'It described it again.', note, 227 + 4 * 89, 88)),
    'lessons', jsonb_build_array(pg_temp.lesson('l1', 1, array['s1c1', 's1c2'])),
    'items', '[]'::jsonb));
  perform pg_temp.become_worker();
  lic_pub := (public.publish_study_course(gen2, lic_work, 'test-licensed', 'R') ->> 'id')::uuid;
  perform pg_temp.as_owner();
  select * into pc from public.public_study_courses where id = lic_pub;
  if pc.excerpts is distinct from substr(note, 228, 88) || E'\n\n' || substr(note, 228 + 4 * 89, 88)
     or (select string_agg(e ->> 'start', ',' order by (e ->> 'start')::int)
         from jsonb_array_elements(pc.snapshot -> 'claims') c
         cross join jsonb_array_elements(c -> 'evidence') e) is distinct from '0,90' then
    raise exception 'two far spans were not two excerpts: % / %', pc.excerpts, pc.snapshot -> 'claims';
  end if;
  if (select string_agg(format('%s-%s@%s', q ->> 'from', q ->> 'to', q ->> 'at'), ',')
      from jsonb_array_elements(pc.quotations) q) is distinct from '227-315@0,583-671@90' then
    raise exception 'the two quotations are recorded as %', pc.quotations;
  end if;

  -- Every course published from a work counts towards what its courses quote between them:
  -- here a tenth of a short work's text, 291 of its 2,912 characters, which three courses of 88
  -- each stay within and a fourth would not -- each prepared from a version of its own of the
  -- same text. Passages already quoted take nothing more.
  for d in 0..3 loop
    v2 := pg_temp.save(curator, short);
    perform pg_temp.as_owner();
    insert into public.study_curated_sources (source_version_id, work_id, registered_by)
    values (v2, short_work, 'Public courses test');
    gen2 := pg_temp.prepare(curator, array[v2], jsonb_build_object(
      'claims', jsonb_build_array(
        pg_temp.claim('s1c1', v2, 'The passage described the setting.', short, 227 + d * 4 * 89, 88)),
      'lessons', jsonb_build_array(pg_temp.lesson('l1', 1, array['s1c1'])),
      'items', '[]'::jsonb));
    perform pg_temp.become_worker();
    s := pg_temp.refusal(format('select public.publish_study_course(%L, %L, %L, %L)', gen2,
                                short_work, 'test-short-' || d, 'R'));
    if s is distinct from (case when d < 3 then 'ok' else '22023 quotes' end) then
      raise exception 'course % of a short text, each quoting 88 characters of it: %', d + 1, s;
    end if;
  end loop;
  v2 := pg_temp.save(curator, short);
  perform pg_temp.as_owner();
  insert into public.study_curated_sources (source_version_id, work_id, registered_by)
  values (v2, short_work, 'Public courses test');
  gen2 := pg_temp.prepare(curator, array[v2], jsonb_build_object(
    'claims', jsonb_build_array(
      pg_temp.claim('s1c1', v2, 'The passage described the setting.', short, 227, 88),
      pg_temp.claim('s1c2', v2, 'It described it again.', short, 227 + 8 * 89, 88)),
    'lessons', jsonb_build_array(pg_temp.lesson('l1', 1, array['s1c1', 's1c2'])),
    'items', '[]'::jsonb));
  perform pg_temp.become_worker();
  perform pg_temp.expect('ok',
    format('select public.publish_study_course(%L, %L, %L, %L)', gen2, short_work, 'test-short-again', 'R'),
    'a course quoting only passages already quoted was refused');

  -- A tenth, to the character, and whatever work the text is registered to: of the essay's
  -- 3,000 characters, two courses may quote 300 between them -- a tenth exactly -- the second
  -- from where the first ends; a 301st is over, from the work or from another the same text is
  -- registered to, since a text is known by its hash and not by its work, and with the first
  -- course withdrawn, since its readers keep their copies; and the other work may quote what
  -- the first work's courses quote already, which takes nothing more.
  for quoting in
    select * from (values
      (1, tenth_work, 0, 150, 'ok'),
      (2, tenth_work, 150, 150, 'ok'),
      (3, tenth_work, 2000, 1, '22023 quotes'),
      (4, twin_work, 2000, 1, '22023 quotes'),
      (5, twin_work, 100, 199, 'ok')) as t(n, work_id, start_at, len, want)
  loop
    v2 := pg_temp.save(curator, essay);
    perform pg_temp.as_owner();
    insert into public.study_curated_sources (source_version_id, work_id, registered_by)
    values (v2, quoting.work_id, 'Public courses test');
    gen2 := pg_temp.prepare(curator, array[v2], jsonb_build_object(
      'claims', jsonb_build_array(
        pg_temp.claim('s1c1', v2, 'The essay makes a point.', essay, quoting.start_at, quoting.len)),
      'lessons', jsonb_build_array(pg_temp.lesson('l1', 1, array['s1c1'])),
      'items', '[]'::jsonb));
    perform pg_temp.become_worker();
    s := pg_temp.refusal(format('select public.publish_study_course(%L, %L, %L, %L)', gen2,
                                quoting.work_id, 'test-tenth-' || quoting.n, 'R'));
    if s is distinct from quoting.want then
      raise exception 'course % of the essay, quoting [%, %): wanted %, got %',
        quoting.n, quoting.start_at, quoting.start_at + quoting.len, quoting.want, s;
    end if;
    if quoting.n = 2 then
      perform public.withdraw_public_study_course(
        (select id from public.public_study_courses where slug = 'test-tenth-1'),
        'Public courses test', 'Withdrawn, and still counted.');
    end if;
  end loop;

  -- A course of two texts counts what the courses before it quote of each of them, not of one:
  -- after a course quoting 250 characters of the 3,000-character text, one quoting 51 more of
  -- it and 1 of the 1,000-character text is over the first text's tenth; after a course quoting
  -- 50 of the 1,000-character text, one quoting 51 more of it and 1 of the other is over that
  -- text's. Each text is in turn the one quoted before, so counting the earlier courses of only
  -- one of a course's texts is caught whichever of their hashes comes first.
  for quoting in
    select * from (values
      ('sequel', 250, 0, 1, 1000, 51),
      ('part', 50, 500, 51, 2000, 1))
      as t(before, before_len, part_at, part_len, sequel_at, sequel_len)
  loop
    v2 := pg_temp.save(curator, case quoting.before when 'part' then part else sequel end);
    perform pg_temp.as_owner();
    insert into public.study_curated_sources (source_version_id, work_id, registered_by)
    values (v2, pair_work, 'Public courses test');
    gen2 := pg_temp.prepare(curator, array[v2], jsonb_build_object(
      'claims', jsonb_build_array(
        pg_temp.claim('s1c1', v2, 'The part makes a point.',
                      case quoting.before when 'part' then part else sequel end,
                      0, quoting.before_len)),
      'lessons', jsonb_build_array(pg_temp.lesson('l1', 1, array['s1c1'])),
      'items', '[]'::jsonb));
    perform pg_temp.become_worker();
    perform pg_temp.expect('ok',
      format('select public.publish_study_course(%L, %L, %L, %L)', gen2, pair_work,
             'test-pair-before-' || quoting.before, 'R'),
      format('a course quoting %s characters of the %s alone', quoting.before_len, quoting.before));
    v2 := pg_temp.save(curator, part);
    v3 := pg_temp.save(curator, sequel);
    perform pg_temp.as_owner();
    insert into public.study_curated_sources (source_version_id, work_id, registered_by)
    values (v2, pair_work, 'Public courses test'), (v3, pair_work, 'Public courses test');
    gen2 := pg_temp.prepare(curator, array[v2, v3], jsonb_build_object(
      'claims', jsonb_build_array(
        pg_temp.claim('s1c1', v2, 'The first part makes a point.', part,
                      quoting.part_at, quoting.part_len),
        pg_temp.claim('s2c1', v3, 'The second part makes another.', sequel,
                      quoting.sequel_at, quoting.sequel_len)),
      'lessons', jsonb_build_array(pg_temp.lesson('l1', 1, array['s1c1', 's2c1'])),
      'items', '[]'::jsonb));
    perform pg_temp.become_worker();
    perform pg_temp.expect('22023 quotes',
      format('select public.publish_study_course(%L, %L, %L, %L)', gen2, pair_work,
             'test-pair-after-' || quoting.before, 'R'),
      format('a course of both texts, over the %s''s tenth only with the course before it',
             quoting.before));
  end loop;

  -- A course of two texts is held to a tenth of each, not of the one it quotes most: 101
  -- characters of a 1,000-character text are over its tenth, however little the course's 300
  -- characters of a 3,000-character one are of that; 100 are within it.
  for quoting in select * from (values (101, '22023 quotes'), (100, 'ok')) as t(len, want) loop
    v2 := pg_temp.save(curator, part);
    v3 := pg_temp.save(curator, sequel);
    perform pg_temp.as_owner();
    insert into public.study_curated_sources (source_version_id, work_id, registered_by)
    values (v2, pair_work, 'Public courses test'), (v3, pair_work, 'Public courses test');
    gen2 := pg_temp.prepare(curator, array[v2, v3], jsonb_build_object(
      'claims', jsonb_build_array(
        pg_temp.claim('s1c1', v2, 'The first part makes a point.', part, 0, quoting.len),
        pg_temp.claim('s2c1', v3, 'The second part makes another.', sequel, 0, 300)),
      'lessons', jsonb_build_array(pg_temp.lesson('l1', 1, array['s1c1', 's2c1'])),
      'items', '[]'::jsonb));
    perform pg_temp.become_worker();
    perform pg_temp.expect(quoting.want,
      format('select public.publish_study_course(%L, %L, %L, %L)', gen2, pair_work,
             'test-pair-' || quoting.len, 'R'),
      format('a course quoting %s of 1,000 characters and 300 of 3,000', quoting.len));
  end loop;

  -- ---------------------------------------------------------------- the catalogue
  -- Signed-in readers only.
  perform pg_temp.become_visitor();
  perform pg_temp.expect('42501', 'select 1 from public.list_public_study_courses()',
    'a visitor listed the public courses');
  perform pg_temp.expect('42501', 'select 1 from public.get_public_study_course(''test-licensed'')',
    'a visitor read a public course');
  perform pg_temp.expect('42501', 'select 1 from public.public_study_courses',
    'a visitor read the published table');
  -- A guest is answered as a visitor is: a public course is copied into an account.
  perform pg_temp.become_reader(guest);
  perform set_config('request.jwt.claims',
    json_build_object('sub', guest, 'role', 'authenticated', 'is_anonymous', true)::text, true);
  perform pg_temp.expect('42501', 'select 1 from public.list_public_study_courses()',
    'a guest listed the public courses');
  perform pg_temp.expect('42501', 'select 1 from public.get_public_study_course(''test-licensed'')',
    'a guest read a public course');
  perform pg_temp.become_reader(other);
  if (select count(*) from public.list_public_study_courses()
      where id = pub and work_id = pd_work and work_title = 'Test-enhanced learning'
        and rights_status = 'public_domain' and lesson_count = 2 and question_count = 2) <> 1
     or (select rights_status from public.list_public_study_courses() where id = lic_pub)
        is distinct from 'licensed'
     or jsonb_array_length((select outline from public.get_public_study_course(
                              'test-immediate-versus-delayed'))) is distinct from 2
     or (select objectives from public.get_public_study_course('test-immediate-versus-delayed'))
        is distinct from array['Explain the contrast.']
     or (select work_id from public.get_public_study_course('test-immediate-versus-delayed'))
        is distinct from pd_work then
    raise exception 'a reader could not see the published courses in the catalogue';
  end if;
  -- A withdrawn course is in neither.
  if exists (select 1 from public.list_public_study_courses() where id = filler)
     or exists (select 1 from public.get_public_study_course('test-filler')) then
    raise exception 'a withdrawn course is in the catalogue';
  end if;
  -- Where a copy came from is its owner's to read, and nobody else's.
  if exists (select 1 from public.public_study_course_origin(pub)) then
    raise exception 'a reader without a copy read where a public course came from';
  end if;

  -- The beta's dashboards count what readers prepared from their own material: a copy, and
  -- what a reader does in one -- reading, answering, reporting, withdrawing, correcting -- is
  -- none of it. Probed, and undone.
  begin
    perform pg_temp.as_owner();
    totals := pg_temp.beta_totals();
    perform pg_temp.become_reader(reader);
    p_gen := (public.enrol_public_course(pub) ->> 'generationId')::uuid;
    select id into p_lesson from public.study_lessons
    where generation_id = p_gen order by lesson_key limit 1;
    select id into p_item from public.study_items
    where generation_id = p_gen order by item_key limit 1;
    perform public.record_study_progress(jsonb_build_array(
      jsonb_build_object('clientEventId', extensions.gen_random_uuid(), 'kind', 'lesson_shown',
                         'lessonId', p_lesson),
      jsonb_build_object('clientEventId', extensions.gen_random_uuid(), 'kind', 'lesson_read',
                         'lessonId', p_lesson)));
    r := pg_temp.answer(p_item, '"Neither group"');
    if (r ->> 'recorded')::int <> 1 then
      raise exception 'the probe''s answer in a copy was not recorded: %', r;
    end if;
    perform public.report_study_content('lesson', p_lesson, 'incorrect', null);
    perform public.revise_study_lesson(p_lesson, '{"title": "Said my way"}');
    perform public.retire_study_content('item', p_item);
    perform pg_temp.as_owner();
    if pg_temp.beta_totals() is distinct from totals then
      raise exception 'a copy counted in the beta''s dashboards: % then %',
        totals, pg_temp.beta_totals();
    end if;
    raise exception using errcode = 'P0001', message = 'probe done';
  exception when raise_exception then
    if sqlerrm is distinct from 'probe done' then raise; end if;
  end;

  -- ---------------------------------------------------------------- enrolling
  perform pg_temp.become_reader(reader);
  r := public.enrol_public_course(pub);
  copy := (r ->> 'courseId')::uuid;
  copy_gen := (r ->> 'generationId')::uuid;
  if (r ->> 'replayed')::boolean is not false or copy is null then
    raise exception 'enrolling did not make a copy: %', r;
  end if;
  -- Nothing later in the reader's transaction is logged as an enrolment.
  if coalesce(current_setting('study.status_reason', true), '') <> '' then
    raise exception 'enrolling left its status reason set: %', current_setting('study.status_reason', true);
  end if;
  -- Each of the copy's six rows is logged as enrolled -- written, then validated -- and as
  -- nothing else.
  if (select string_agg(l.reason || ':' || l.to_status || ':' || l.n, ',' order by l.to_status)
      from (select reason, to_status, count(*) as n from public.study_status_log
            where claim_id in (select id from public.study_claims where generation_id = copy_gen)
               or lesson_id in (select id from public.study_lessons where generation_id = copy_gen)
               or item_id in (select id from public.study_items where generation_id = copy_gen)
            group by reason, to_status) as l)
     is distinct from 'enrolled:draft:6,enrolled:validated:6' then
    raise exception 'the copy''s rows were not each logged as enrolled';
  end if;
  if not exists (select 1 from public.study_course_overview
                 where course_id = copy and generation_id = copy_gen
                   and public_course_id = pub and public_course_label = 'public domain'
                   and public_course_on_offer
                   and public_course_work_title = 'Test-enhanced learning'
                   and title = 'Immediate versus delayed'
                   and lesson_count = 2 and question_count = 2 and claim_count = 2
                   and not preparing and not held_back and not update_available) then
    raise exception 'the copy does not read as a prepared course: %',
      (select to_jsonb(o) from public.study_course_overview o where o.course_id = copy);
  end if;
  -- The work is linked to only while its page can be opened: while a summary of it is readable.
  if (select public_course_work_id from public.study_course_overview where course_id = copy)
     is not null then
    raise exception 'a copy linked to a work nobody can open';
  end if;
  perform pg_temp.as_owner();
  insert into public.summaries (work_id, title, status, visibility, published_at)
  values (pd_work, 'Test-enhanced learning', 'published', 'public', now());
  perform pg_temp.become_reader(reader);
  if (select public_course_work_id from public.study_course_overview where course_id = copy)
     is distinct from pd_work then
    raise exception 'a copy did not link to its work once the work could be opened';
  end if;
  perform pg_temp.as_owner();
  delete from public.summaries where work_id = pd_work;
  perform pg_temp.become_reader(reader);
  -- The disagreement it was published with, and no other.
  if (select jsonb_agg(x.dis ->> 'description') from public.study_course_overview o,
        jsonb_array_elements(o.disagreements) as x(dis) where o.course_id = copy)
     is distinct from '["Early on restudying wins; later the test does."]'::jsonb then
    raise exception 'the copy''s disagreements are not the published one';
  end if;
  if (select count(*) from public.study_course_outline(copy)) <> 2
     or (select count(*) from public.study_course_questions(copy)) <> 2 then
    raise exception 'the copy''s outline or questions are wrong';
  end if;
  -- Every link is copied: evidence, each lesson's claims, each question's claims and lesson.
  if (select count(*) from public.study_claim_evidence e
      join public.study_claims c on c.id = e.claim_id where c.generation_id = copy_gen) <> 2
     or (select string_agg(l.lesson_key || ':' || c.claim_key, ',' order by l.lesson_key)
         from public.study_lesson_claims lc
         join public.study_lessons l on l.id = lc.lesson_id
         join public.study_claims c on c.id = lc.claim_id
         where l.generation_id = copy_gen) is distinct from 'l1:s1c1,l2:s1c2'
     or (select string_agg(i.item_key || ':' || c.claim_key || ':' || l.lesson_key, ','
                           order by i.item_key)
         from public.study_item_claims ic
         join public.study_items i on i.id = ic.item_id
         join public.study_claims c on c.id = ic.claim_id
         join public.study_lessons l on l.id = i.lesson_id
         where i.generation_id = copy_gen) is distinct from 'q1:s1c2:l2,q2:s1c1:l1' then
    raise exception 'the copy lost a link';
  end if;
  -- The model's provenance is kept; the curator's corrections are the project's, with none.
  if exists (select 1 from public.study_claims c
             where c.generation_id = copy_gen
               and (c.prompt_hash, c.schema_hash, c.model)
                   is distinct from (repeat('a', 64), repeat('b', 64), 'm'))
     or (select string_agg(lesson_key || ':' || authored_by || ':' || coalesce(model, '-'), ','
                           order by lesson_key)
         from public.study_lessons where generation_id = copy_gen)
        is distinct from 'l1:project:-,l2:project:-'
     or (select string_agg(item_key || ':' || authored_by || ':' || coalesce(model, '-'), ','
                           order by item_key)
         from public.study_items where generation_id = copy_gen)
        is distinct from 'q1:model:m,q2:project:-' then
    raise exception 'the copy''s authorship or provenance is wrong';
  end if;
  -- No job, no consent asked, nothing counted against the reader: nothing was sent.
  if exists (select 1 from public.generation_jobs where requester_id = reader)
     or (select job_id from public.study_generations where id = copy_gen) is not null then
    raise exception 'enrolling made a generation job';
  end if;
  -- The evidence points into the reader's copy of the excerpts.
  select c.source_version_id into excerpt from public.study_claims c
  where c.generation_id = copy_gen limit 1;
  if exists (select 1 from public.study_claim_evidence e
             join public.study_claims c on c.id = e.claim_id
             join public.study_source_versions sv on sv.id = c.source_version_id
             where c.generation_id = copy_gen
               and substr(sv.extracted_text, e.start_offset + 1, e.end_offset - e.start_offset)
                   is distinct from e.span_text)
     or (select extracted_text from public.study_source_versions where id = excerpt)
        is distinct from substr(note, 84, 142)
     or (select quotations from public.study_source_versions where id = excerpt)
        is distinct from '[[0, 142]]'::jsonb then
    raise exception 'the copied evidence does not point at its excerpt';
  end if;
  -- The copy's questions prove recall like any course's -- the project's correction as the
  -- model's question does, which the curator's own version of it never could.
  select id into item from public.study_items where generation_id = copy_gen and item_key = 'q2';
  r := pg_temp.answer(item, '"The restudy group"');
  if (r -> 'results' -> 0 ->> 'provesRecall')::boolean is not true then
    raise exception 'an answer to the project''s question did not prove recall: %', r;
  end if;
  if (select state from public.study_course_questions(copy) where item_id = item)
       is distinct from 'recall_demonstrated'
     or (select k.known from public.study_claim_knowledge(copy) k
         join public.study_claims c on c.id = k.claim_id where c.claim_key = 's1c1') is not true
     or (select claims_demonstrated_count from public.study_course_overview where course_id = copy)
        is distinct from 1 then
    raise exception 'the project''s question did not demonstrate recall where the course reads it';
  end if;
  select id into item from public.study_items where generation_id = copy_gen and item_key = 'q1';
  r := pg_temp.answer(item, '"The recall test group"');
  if (r -> 'results' -> 0 ->> 'provesRecall')::boolean is not true then
    raise exception 'an answer to the model''s question in a copy did not prove recall: %', r;
  end if;
  -- ...and a wrong answer to the project's question scores as one to the model's: a lapse in
  -- the memory, the claim lapsed, and the question due.
  select id into item from public.study_items where generation_id = copy_gen and item_key = 'q2';
  r := pg_temp.answer(item, '"Neither group"');
  if (r -> 'results' -> 0 ->> 'correct')::boolean is not false
     or (select m.lapses from public.study_claim_memory m
         join public.study_claims c on c.id = m.claim_id
         where c.generation_id = copy_gen and c.claim_key = 's1c1') is distinct from 1
     or (select k.lapsed from public.study_claim_knowledge(copy) k
         join public.study_claims c on c.id = k.claim_id where c.claim_key = 's1c1') is not true
     or (select due_at from public.study_course_questions(copy) where item_id = item) is null then
    raise exception 'a wrong answer to the project''s question did not score as the model''s: %', r;
  end if;
  -- A row of the project's, like the model's, is written a draft and validated after.
  perform pg_temp.as_owner();
  perform pg_temp.expect('22023',
    format('insert into public.study_lessons (owner_id, generation_id, lesson_key, position, '
           'unit_no, unit_title, title, objective, explanation, recap, minutes, status, '
           'authored_by) values (%L, %L, %L, 9, 1, %L, %L, %L, %L, %L, 3, %L, %L)', reader,
           copy_gen, 'l9', 'Unit', 'Title', 'Objective', 'Explanation', 'Recap', 'validated',
           'project'),
    'a lesson of the project''s was written validated');
  perform pg_temp.become_reader(reader);
  -- Enrolling again answers with the copy the reader has, and is not another enrolment.
  r := public.enrol_public_course(pub);
  if (r ->> 'courseId')::uuid is distinct from copy or (r ->> 'replayed')::boolean is not true
     or (select count(*) from public.study_public_enrolments) <> 1 then
    raise exception 'enrolling twice made a second copy, or counted: %', r;
  end if;
  -- A copy is not prepared again, its excerpts are not saved into, and they are no save of the
  -- reader's.
  perform pg_temp.expect('55000 public',
    format('select public.regenerate_study_course(%L, %L, true)', copy, extensions.gen_random_uuid()),
    'a public course''s copy was prepared again');
  perform pg_temp.expect('55000 public',
    format('select public.save_study_source_version(%L, %L, %L, %L, %L)', 'Mine', 'paste', 'My text',
           extensions.gen_random_uuid(),
           (select source_id from public.study_source_versions where id = excerpt)),
    'a version was saved into a public course''s excerpts');
  perform pg_temp.as_owner();
  if exists (select 1 from public.study_source_mutations where version_id = excerpt) then
    raise exception 'a public course''s excerpts counted as a save of the reader''s';
  end if;
  -- The enrolment log: the reader's own, read-only.
  perform pg_temp.become_reader(reader);
  perform pg_temp.expect('42501',
    format('insert into public.study_public_enrolments (owner_id, public_course_id) values (%L, %L)',
           reader, pub),
    'a reader wrote to the enrolment log');
  -- Another reader sees none of it.
  perform pg_temp.become_reader(other);
  if exists (select 1 from public.study_course_overview where course_id = copy)
     or exists (select 1 from public.study_public_enrolments)
     or exists (select 1 from public.public_study_course_origin(pub)) then
    raise exception 'another reader could see a reader''s copy';
  end if;
  -- A guest has no account to copy into; no course is P0002.
  perform set_config('request.jwt.claims',
    json_build_object('sub', guest, 'role', 'authenticated', 'is_anonymous', true)::text, true);
  perform pg_temp.expect('28000', format('select public.enrol_public_course(%L)', pub),
    'a guest enrolled');
  perform pg_temp.become_reader(other);
  perform pg_temp.expect('P0002',
    format('select public.enrol_public_course(%L)', extensions.gen_random_uuid()),
    'no course was enrolled in');
  perform pg_temp.expect('P0002', format('select public.enrol_public_course(%L)', filler),
    'a withdrawn course was enrolled in');

  -- The curator enrols too; the copy is not a course to publish, nor its excerpts a source.
  perform pg_temp.become_reader(curator);
  r := public.enrol_public_course(pub);
  cur_copy := (r ->> 'generationId')::uuid;
  perform pg_temp.become_worker();
  perform pg_temp.expect('55000 public',
    format('select public.publish_study_course(%L, %L, %L, %L)', cur_copy, pd_work, 'test-copy', 'R'),
    'a copy of a public course was published');
  perform pg_temp.become_reader(curator);
  perform pg_temp.expect('55000 public',
    format('select public.enqueue_study_generation(array[%L]::uuid[], %L, %L, true)',
           (select source_version_id from public.study_generation_sources
            where generation_id = cur_copy), 'Explain it', extensions.gen_random_uuid()),
    'a course was prepared from a public course''s excerpts');

  -- Only a course's current version is published: prepared again, the published one is not.
  v2 := pg_temp.save(curator, note || ' A last line.', (select source_id from public.study_source_versions where id = v));
  gen2 := pg_temp.prepare(curator, null, jsonb_build_object(
    'claims', jsonb_build_array(pg_temp.claim('s1c1', v2, 'Restudying won early.', note, 83, 40)),
    'lessons', jsonb_build_array(pg_temp.lesson('l1', 1, array['s1c1'])),
    'items', '[]'::jsonb), course);
  -- Prepared later, as it would be outside one test transaction, where now() stands still.
  update public.study_generations set created_at = created_at - interval '1 hour' where id = gen;
  if public.study_course_generation(course) is distinct from gen2 then
    raise exception 'the course''s new version is not its current one';
  end if;
  perform pg_temp.become_worker();
  perform pg_temp.expect('55000 superseded',
    format('select public.publish_study_course(%L, %L, %L, %L)', gen, pd_work, 'test-old', 'R'),
    'a course''s superseded version was published');

  -- ---------------------------------------------------------------- deleting a copy
  -- A reader's copy goes with its course; the excerpts stay, to be used again.
  perform pg_temp.become_reader(reader);
  perform public.delete_study_course(copy);
  r := public.enrol_public_course(pub);
  copy := (r ->> 'courseId')::uuid;
  if (r ->> 'replayed')::boolean is not false
     or (select count(*) from public.study_source_versions where format = 'public_course') <> 1
     or (select count(*) from public.study_public_enrolments) <> 2 then
    raise exception 'enrolling after deleting the copy did not reuse the excerpts, or count: %', r;
  end if;

  -- ---------------------------------------------------------------- rights in question
  -- Out of the catalogue at once, closed to enrolment, and no rights claimed for a copy.
  perform pg_temp.as_owner();
  update public.works set rights_status = 'review_required' where id = pd_work;
  perform pg_temp.become_reader(reader);
  if exists (select 1 from public.list_public_study_courses() where id = pub)
     or exists (select 1 from public.get_public_study_course('test-immediate-versus-delayed'))
     or (select public_course_label from public.study_course_overview where course_id = copy)
        is not null
     or (select public_course_work_title from public.study_course_overview where course_id = copy)
        is distinct from 'Test-enhanced learning'
     or (select public_course_on_offer from public.study_course_overview where course_id = copy)
        is not false then
    raise exception 'a course of a work under rights review stayed in the catalogue or kept its rights';
  end if;
  perform pg_temp.become_reader(other);
  perform pg_temp.expect('P0002', format('select public.enrol_public_course(%L)', pub),
    'a course of a work under rights review was enrolled in');
  perform pg_temp.as_owner();
  update public.works set rights_status = 'community' where id = pd_work;
  perform pg_temp.become_reader(reader);
  if exists (select 1 from public.list_public_study_courses() where id = pub)
     or (select rights_label from public.public_study_course_origin(pub)) is not null then
    raise exception 'a community work''s course claimed rights';
  end if;
  perform pg_temp.as_owner();
  update public.works set rights_status = 'licensed' where id = pd_work;
  perform pg_temp.become_reader(reader);
  if (select rights_label from public.public_study_course_origin(pub)) is distinct from 'licensed'
     or (select public_course_on_offer from public.study_course_overview where course_id = copy)
        is not true then
    raise exception 'a licensed work''s course did not say so, or is not on offer again';
  end if;
  perform pg_temp.as_owner();
  update public.works set rights_status = 'public_domain' where id = pd_work;

  -- ---------------------------------------------------------------- twenty a day
  -- Counted from the log of enrolments -- not the copies kept, not a replay -- since 00:00 UTC.
  perform pg_temp.as_owner();
  select * into pc from public.public_study_courses where id = pub;
  for d in 1..21 loop
    insert into public.public_study_courses
      (slug, work_id, title, goal, overview, objectives, recap, excerpt_title, excerpts,
       quotations, snapshot, outline, lesson_count, question_count, reviewed_by)
    values (format('test-day-%s', d), day_work, pc.title, pc.goal, pc.overview, pc.objectives,
            pc.recap, pc.excerpt_title, pc.excerpts, pc.quotations, pc.snapshot, pc.outline,
            pc.lesson_count, pc.question_count, 'Public courses test')
    returning id into item;
    day_ids := day_ids || item;
  end loop;
  perform pg_temp.become_reader(busy);
  for d in 1..19 loop
    perform public.enrol_public_course(day_ids[d]);
  end loop;
  for d in 1..3 loop
    perform public.enrol_public_course(day_ids[1]);
  end loop;
  perform pg_temp.expect('ok', format('select public.enrol_public_course(%L)', day_ids[20]),
    'the twentieth enrolment of the day, after three replays, was refused');
  perform pg_temp.expect('54000', format('select public.enrol_public_course(%L)', day_ids[21]),
    'a twenty-first enrolment in a day was made');
  perform public.delete_study_course(
    (select id from public.study_courses where public_course_id = day_ids[1]));
  perform pg_temp.expect('54000', format('select public.enrol_public_course(%L)', day_ids[1]),
    'deleting a copy and adding it again was not counted');
  perform pg_temp.as_owner();
  update public.study_public_enrolments set enrolled_at = date_trunc('day', now(), 'UTC') - interval '1 minute'
  where owner_id = busy and public_course_id = day_ids[2];
  perform pg_temp.become_reader(busy);
  perform pg_temp.expect('ok', format('select public.enrol_public_course(%L)', day_ids[21]),
    'yesterday''s enrolment counted today');
  -- A public course's excerpts are not among the reader's 100 versions: twenty of them and
  -- eighty of the reader's own leave room for another of their own.
  perform pg_temp.as_owner();
  with sources as (
    insert into public.study_sources (owner_id, latest_version_no)
    select busy, 1 from generate_series(1, 80) returning id
  )
  insert into public.study_source_versions
    (source_id, owner_id, version_no, client_mutation_id, title, format, extracted_text)
  select id, busy, 1, extensions.gen_random_uuid(), 'Mine', 'paste', 'My own text.'
  from sources;
  if (select count(*) from public.study_source_versions where owner_id = busy) < 100 then
    raise exception 'the setup for the version limit is short';
  end if;
  perform pg_temp.become_reader(busy);
  perform pg_temp.expect('ok',
    format('select public.save_study_source_version(%L, %L, %L, %L)', 'Mine', 'paste', 'More of mine',
           extensions.gen_random_uuid()),
    'a public course''s excerpts counted against the reader''s versions');

  -- ---------------------------------------------------------------- a published course is final
  perform pg_temp.as_owner();
  perform pg_temp.expect('55000',
    format('update public.public_study_courses set title = %L where id = %L', 'Changed', pub),
    'a published course changed');
  -- Nor what it quotes: counted from its quotations, a range shortened would hand the rest of
  -- the text's tenth to another course.
  perform pg_temp.expect('55000',
    format('update public.public_study_courses set quotations = jsonb_set(quotations, %L, %L) '
           'where id = %L', '{0,to}', '84', pub),
    'a published course''s quotations changed');
  perform pg_temp.expect('55000', format('delete from public.public_study_courses where id = %L', pub),
    'a course on offer was deleted');
  perform set_config('client_min_messages', 'warning', true);
  perform pg_temp.expect('55000', 'truncate public.public_study_courses cascade',
    'the published courses were truncated');
  perform set_config('client_min_messages', 'notice', true);
  if left(pg_temp.refusal(format('delete from public.works where id = %L', pd_work)), 5) <> '23503' then
    raise exception 'a work with a published course was deleted';
  end if;
  perform pg_temp.become_worker();
  perform pg_temp.expect('42501',
    format('update public.public_study_courses set withdrawn_at = now(), withdrawn_reason = %L where id = %L',
           'Why', pub),
    'the service role updated a published course around the withdrawal');
  perform pg_temp.expect('42501', format('delete from public.public_study_courses where id = %L', pub),
    'the service role deleted a published course');
  perform pg_temp.expect('42501', 'truncate public.public_study_courses',
    'the service role truncated the published courses');

  -- ---------------------------------------------------------------- withdrawing
  perform pg_temp.expect('55000', format('select public.remove_public_course_copies(%L, 10)', pub),
    'copies of a course on offer were removed');
  perform pg_temp.expect('22023',
    format('select public.withdraw_public_study_course(%L, %L, %L)', pub, ' ', 'Why'),
    'a withdrawal named nobody');
  r := public.withdraw_public_study_course(pub, 'A reviewer', 'A rights holder asked.');
  if (r ->> 'withdrawn')::boolean is not true or (r ->> 'copies')::int is distinct from 2 then
    raise exception 'withdrawing said %', r;
  end if;
  perform pg_temp.as_owner();
  -- Withdrawing touches nobody's copy.
  if (select count(*) from public.study_courses where public_course_id = pub) <> 2
     or (select count(*) from public.moderation_decisions
         where action = 'withdraw_public_study_course' and rationale like '%' || pub::text || '%') <> 1 then
    raise exception 'withdrawing removed copies, or recorded no decision';
  end if;
  withdrawn := (select withdrawn_at from public.public_study_courses where id = pub);
  perform pg_temp.become_worker();
  perform public.withdraw_public_study_course(pub, 'A reviewer', 'Asked again.');
  perform pg_temp.as_owner();
  if (select withdrawn_at from public.public_study_courses where id = pub) is distinct from withdrawn
     or (select withdrawn_reason from public.public_study_courses where id = pub)
        is distinct from 'A rights holder asked.'
     or (select count(*) from public.moderation_decisions
         where action = 'withdraw_public_study_course' and rationale like '%' || pub::text || '%') <> 2 then
    raise exception 'withdrawing again changed the withdrawal, or recorded no decision';
  end if;
  perform pg_temp.expect('55000',
    format('update public.public_study_courses set withdrawn_at = null, withdrawn_reason = null where id = %L', pub),
    'a withdrawn course was offered again');
  perform pg_temp.become_reader(other);
  if exists (select 1 from public.list_public_study_courses() where id = pub)
     or exists (select 1 from public.get_public_study_course('test-immediate-versus-delayed')) then
    raise exception 'a withdrawn course stayed in the catalogue';
  end if;
  -- A copy says its course is no longer offered: deleted, it could not be added again.
  perform pg_temp.become_reader(reader);
  if (select public_course_on_offer from public.study_course_overview where course_id = copy)
     is not false then
    raise exception 'a copy of a withdrawn course read as still on offer';
  end if;
  perform pg_temp.become_reader(other);
  perform pg_temp.expect('P0002', format('select public.enrol_public_course(%L)', pub),
    'a withdrawn course was enrolled in');
  -- The copies go a reader at a time, with their excerpts; the log of enrolments stays.
  perform pg_temp.become_worker();
  perform pg_temp.expect('22023', format('select public.remove_public_course_copies(%L, 0)', pub),
    'a batch of no readers was removed');
  n := public.remove_public_course_copies(pub, 1);
  if n <> 1
     or (select count(*) from public.study_courses where public_course_id = pub) <> 1
     or (select count(*) from public.study_source_versions
         where format = 'public_course' and origin_label = 'public_course:' || pub) <> 1 then
    raise exception 'a batch of one did not remove one reader''s copy and excerpts';
  end if;
  n := public.remove_public_course_copies(pub, 1);
  d := public.remove_public_course_copies(pub, 1);
  if n <> 1 or d <> 0
     or exists (select 1 from public.study_courses where public_course_id = pub)
     or exists (select 1 from public.study_generations where public_course_id = pub)
     or exists (select 1 from public.study_source_versions
                where format = 'public_course' and origin_label = 'public_course:' || pub)
     or (select count(*) from public.study_public_enrolments where public_course_id = pub) <> 3 then
    raise exception 'removing the copies left some, or took the log';
  end if;
  -- Withdrawn and with no copies, the owner may delete it, and the log goes with it.
  perform pg_temp.as_owner();
  delete from public.public_study_courses where id = pub;
  if exists (select 1 from public.study_public_enrolments where public_course_id = pub) then
    raise exception 'the log outlived its course';
  end if;

  -- ---------------------------------------------------------------- the account goes, the course stays
  perform pg_temp.become_reader(other);
  perform public.enrol_public_course(lic_pub);
  -- Its copy of the excerpts says where each of the two quotations lies in it.
  if (select v.quotations from public.study_source_versions v
      where v.format = 'public_course' and v.origin_label = 'public_course:' || lic_pub)
     is distinct from '[[0, 88], [90, 178]]'::jsonb then
    raise exception 'a copy of two quotations does not say where each lies';
  end if;
  perform pg_temp.as_owner();
  delete from auth.users where id = other;
  if exists (select 1 from public.study_courses where public_course_id = lic_pub)
     or exists (select 1 from public.study_public_enrolments where owner_id = other)
     or not exists (select 1 from public.public_study_courses where id = lic_pub) then
    raise exception 'deleting an account did not take its copy, or took the public course';
  end if;

  -- ---------------------------------------------------------------- deleting, with a copy left
  -- A reader's copy of the excerpts outlives their copy of the course, and names the course
  -- only by its label: the course is not deleted while one is left, which it would stop
  -- counting against its work and leave nothing to find by. Removed, it goes.
  perform pg_temp.become_reader(reader);
  perform public.delete_study_course((public.enrol_public_course(lic_pub) ->> 'courseId')::uuid);
  perform pg_temp.become_worker();
  perform public.withdraw_public_study_course(lic_pub, 'A reviewer', 'Superseded.');
  perform pg_temp.as_owner();
  perform pg_temp.expect('55000',
    format('delete from public.public_study_courses where id = %L', lic_pub),
    'a course was deleted while a reader kept a copy of its excerpts');
  perform pg_temp.become_worker();
  if public.remove_public_course_copies(lic_pub, 10) <> 1 then
    raise exception 'removing the copies did not go through the reader who kept only the excerpts';
  end if;
  perform pg_temp.as_owner();
  perform pg_temp.expect('ok',
    format('delete from public.public_study_courses where id = %L', lic_pub),
    'a withdrawn course with no copy left was not deleted');

  raise notice 'public study courses: ok';
end
$test$;

rollback;

-- Publishing is refused outside READ COMMITTED, before anything is read: under an older
-- snapshot, REPEATABLE READ's or SERIALIZABLE's, what it counts would miss a publication its
-- locks waited for. The same block runs under each.
begin isolation level repeatable read;
set local role service_role;
do $test$
declare
  st text;
  dt text;
begin
  begin
    perform public.publish_study_course(extensions.gen_random_uuid(),
                                        extensions.gen_random_uuid(), 'test-isolation', 'R');
    st := 'ok';
  exception when others then
    get stacked diagnostics st = returned_sqlstate, dt = pg_exception_detail;
  end;
  if st || coalesce(' ' || dt, '') is distinct from '55000 isolation' then
    raise exception 'publishing under %: wanted 55000 isolation, got % %',
      current_setting('transaction_isolation'), st, dt;
  end if;
  raise notice 'public study courses, isolation: ok under %',
    current_setting('transaction_isolation');
end
$test$;
rollback;

begin isolation level serializable;
set local role service_role;
do $test$
declare
  st text;
  dt text;
begin
  begin
    perform public.publish_study_course(extensions.gen_random_uuid(),
                                        extensions.gen_random_uuid(), 'test-isolation', 'R');
    st := 'ok';
  exception when others then
    get stacked diagnostics st = returned_sqlstate, dt = pg_exception_detail;
  end;
  if st || coalesce(' ' || dt, '') is distinct from '55000 isolation' then
    raise exception 'publishing under %: wanted 55000 isolation, got % %',
      current_setting('transaction_isolation'), st, dt;
  end if;
  raise notice 'public study courses, isolation: ok under %',
    current_setting('transaction_isolation');
end
$test$;
rollback;
