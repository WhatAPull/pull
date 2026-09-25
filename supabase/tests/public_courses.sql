-- Rights-cleared public study courses (20260925230000): published by the service role from
-- a cleared work with capped quotations, read through the catalogue functions, and enrolled
-- by copy into a reader's own tables, where everything per reader works as on any course.
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



do $test$
declare
  curator   uuid := extensions.gen_random_uuid();
  reader    uuid := extensions.gen_random_uuid();
  other     uuid := extensions.gen_random_uuid();
  guest     uuid := extensions.gen_random_uuid();
  -- Long enough that its quotations are well under a tenth of it.
  note      text := 'Roediger and Karpicke had students read prose. On a final test five '
                    'minutes later, the group that restudied remembered more. On final tests '
                    'two days and one week later, the group that had taken the recall test '
                    'remembered more. ' || repeat('The passage went on at length about the '
                    'history of the study and its setting in the lab. ', 30);
  pd_work   uuid;
  own_work  uuid;
  rev_work  uuid;
  saved     jsonb;
  v         uuid;
  out       jsonb;
  job       uuid;
  gen       uuid;
  pub       uuid;
  copy      uuid;
  copy_gen  uuid;
  q1        uuid;
  r         jsonb;
  d         text;
  n         int;
begin
  insert into auth.users
    (id, instance_id, aud, role, email, encrypted_password,
     email_confirmed_at, created_at, updated_at, is_anonymous,
     raw_app_meta_data, raw_user_meta_data)
  values
    (curator, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
     'public-course-curator@example.test', '', now(), now(), now(), false, '{}', '{}'),
    (reader, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
     'public-course-reader@example.test', '', now(), now(), now(), false, '{}', '{}'),
    (other, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
     'public-course-other@example.test', '', now(), now(), now(), false, '{}', '{}'),
    (guest, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
     null, '', null, now(), now(), true, '{}', '{}');
  -- The curator prepares courses; the readers are not on the allowlist, and do not need to be.
  insert into public.study_generation_access (user_id) values (curator);
  insert into public.works (kind, title, slug, rights_status)
  values ('paper', 'Test-enhanced learning', 'test-enhanced-learning-public-course', 'public_domain')
  returning id into pd_work;
  insert into public.works (kind, title, slug, rights_status)
  values ('essay', 'A reader''s own essay', 'a-readers-own-essay-public-course', 'user_owned')
  returning id into own_work;
  insert into public.works (kind, title, slug, rights_status)
  values ('essay', 'An unresolved essay', 'an-unresolved-essay-public-course', 'review_required')
  returning id into rev_work;

  -- ---------------------------------------------------------------- the curator's course
  perform pg_temp.become_reader(curator);
  saved := public.save_study_source_version('Roediger and Karpicke', 'paste', note,
                                            extensions.gen_random_uuid());
  v := (saved ->> 'versionId')::uuid;
  out := public.enqueue_study_generation(array[v], 'Explain the argument',
                                         extensions.gen_random_uuid(), true);
  job := (out ->> 'jobId')::uuid;
  gen := (out ->> 'generationId')::uuid;
  perform pg_temp.become_worker();
  perform public.persist_study_course(job, jsonb_build_object(
    'course', jsonb_build_object('title', 'Immediate versus delayed',
                                 'objectives', jsonb_build_array('Explain the contrast.')),
    'claims', jsonb_build_array(
      pg_temp.claim('s1c1', v, 'At five minutes, restudying beat the recall test.',
                    'the group that restudied remembered more', note),
      pg_temp.claim('s1c2', v, 'After a week, the recall test group remembered more.',
                    'the group that had taken the recall test remembered more', note)),
    'lessons', jsonb_build_array(
      pg_temp.lesson('l1', 1, array['s1c1']),
      pg_temp.lesson('l2', 2, array['s1c2'])),
    'items', jsonb_build_array(
      pg_temp.q('q1', 'l2', 'multiple_choice', 'Which group remembered more after a week?',
                'The recall test group', array['s1c2'], jsonb_build_object('distractors',
                  jsonb_build_array(
                    jsonb_build_object('text', 'The restudy group', 'why', 'Only at five minutes.'),
                    jsonb_build_object('text', 'Neither group', 'why', 'The note reports a difference.'))))),
    'provenance', jsonb_build_object('promptHash', repeat('a', 64),
                                     'schemaHash', repeat('b', 64), 'model', 'm')));

  -- ---------------------------------------------------------------- what is not published
  begin
    perform public.publish_study_course(gen, pd_work, 'too-early', 'A reviewer');
    raise exception 'a course was published before validation';
  exception when sqlstate '55000' then
    get stacked diagnostics d = pg_exception_detail;
    if d is distinct from 'unvalidated' then raise exception 'unvalidated said %', d; end if;
  end;
  perform public.validate_study_course(job);
  perform pg_temp.as_owner();
  update public.generation_jobs set status = 'succeeded' where id = job;
  perform pg_temp.become_worker();
  begin
    perform public.publish_study_course(gen, own_work, 'own-work', 'A reviewer');
    raise exception 'a course from a reader''s own work was published';
  exception when sqlstate '42501' then
    get stacked diagnostics d = pg_exception_detail;
    if d is distinct from 'rights' then raise exception 'rights said %', d; end if;
  end;
  begin
    perform public.publish_study_course(gen, rev_work, 'unresolved-work', 'A reviewer');
    raise exception 'a course from a work awaiting a rights review was published';
  exception when sqlstate '42501' then null;
  end;
  begin
    perform public.publish_study_course(gen, pd_work, 'Not A Slug!', 'A reviewer');
    raise exception 'a bad slug was accepted';
  exception when sqlstate '22023' then null;
  end;
  begin
    perform public.publish_study_course(gen, pd_work, 'no-reviewer', '  ');
    raise exception 'a course was published with nobody named as its reviewer';
  exception when sqlstate '22023' then null;
  end;
  -- Quotations over a tenth of the source are refused: the same spans in a short source.
  perform pg_temp.as_owner();
  update public.study_source_versions
     set extracted_text = left(extracted_text, 400)
   where id = v;
  perform pg_temp.become_worker();
  begin
    perform public.publish_study_course(gen, pd_work, 'too-much-quoted', 'A reviewer');
    raise exception 'quotations of more than a tenth of the source were published';
  exception when sqlstate '22023' then
    get stacked diagnostics d = pg_exception_detail;
    if d is distinct from 'quotes' then raise exception 'quotes said %', d; end if;
  end;
  perform pg_temp.as_owner();
  update public.study_source_versions set extracted_text = note where id = v;

  -- ---------------------------------------------------------------- publishing
  perform pg_temp.become_worker();
  r := public.publish_study_course(gen, pd_work, 'immediate-versus-delayed', 'A reviewer',
                                   'Checked against the paper.');
  pub := (r ->> 'id')::uuid;
  if (r ->> 'lessons')::int is distinct from 2 or (r ->> 'questions')::int is distinct from 1 then
    raise exception 'the published course is not the validated one: %', r;
  end if;
  if not exists (select 1 from public.moderation_decisions
                 where action = 'publish_study_course' and rationale like '%' || pub::text || '%') then
    raise exception 'publishing recorded no moderation decision';
  end if;
  -- The excerpts are the quoted spans and nothing else of the source.
  if (select excerpts from public.public_study_courses where id = pub)
     is distinct from 'the group that restudied remembered more' || E'\n\n' ||
                      'the group that had taken the recall test remembered more' then
    raise exception 'the excerpts are %', (select excerpts from public.public_study_courses where id = pub);
  end if;

  -- The catalogue, for anyone; the table itself, for no API role.
  perform set_config('role', 'anon', true);
  perform set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
  if (select count(*) from public.list_public_study_courses() where id = pub) is distinct from 1::bigint
     or (select rights_status from public.get_public_study_course('immediate-versus-delayed'))
        is distinct from 'public_domain'
     or jsonb_array_length((select outline from public.get_public_study_course('immediate-versus-delayed')))
        is distinct from 2 then
    raise exception 'a visitor could not see the published course in the catalogue';
  end if;
  begin
    perform 1 from public.public_study_courses;
    raise exception 'a visitor could read the published table, answer keys and all';
  exception when insufficient_privilege then null;
  end;
  perform pg_temp.become_reader(reader);
  begin
    perform 1 from public.public_study_courses;
    raise exception 'a reader could read the published table';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.publish_study_course(gen, pd_work, 'by-a-reader', 'Me');
    raise exception 'a reader could publish a course';
  exception when insufficient_privilege then null;
  end;

  -- ---------------------------------------------------------------- enrolling
  r := public.enrol_public_course(pub);
  copy := (r ->> 'courseId')::uuid;
  copy_gen := (r ->> 'generationId')::uuid;
  if (r ->> 'replayed')::boolean is not false or copy is null then
    raise exception 'enrolling did not make a copy: %', r;
  end if;
  if not exists (select 1 from public.study_course_overview
                 where course_id = copy and generation_id = copy_gen
                   and public_course_id = pub
                   and public_course_label = 'From Test-enhanced learning (public domain)'
                   and title = 'Immediate versus delayed'
                   and lesson_count = 2 and question_count = 1 and claim_count = 2
                   and not preparing and not held_back and not update_available) then
    raise exception 'the copy does not read as a prepared course: %',
      (select to_jsonb(o) from public.study_course_overview o where o.course_id = copy);
  end if;
  if (select count(*) from public.study_course_outline(copy)) is distinct from 2::bigint
     or (select count(*) from public.study_course_questions(copy)) is distinct from 1::bigint then
    raise exception 'the copy''s outline or questions are wrong';
  end if;
  -- No job, no consent asked, nothing counted against the reader: nothing was sent.
  if exists (select 1 from public.generation_jobs where requester_id = reader)
     or (select job_id from public.study_generations where id = copy_gen) is not null then
    raise exception 'enrolling made a generation job';
  end if;
  -- The evidence points into the reader's copy of the excerpts.
  if exists (select 1 from public.study_claim_evidence e
             join public.study_claims c on c.id = e.claim_id
             join public.study_source_versions sv on sv.id = c.source_version_id
             where c.generation_id = copy_gen
               and substr(sv.extracted_text, e.start_offset + 1, e.end_offset - e.start_offset)
                   is distinct from e.span_text) then
    raise exception 'the copied evidence does not point at its excerpt';
  end if;
  -- The copy's questions prove recall like any course's.
  select id into q1 from public.study_items where generation_id = copy_gen and item_key = 'q1';
  r := pg_temp.answer(q1, '"The recall test group"');
  if (r -> 'results' -> 0 ->> 'provesRecall')::boolean is not true then
    raise exception 'an answer to a public course''s copy did not prove recall: %', r;
  end if;
  -- Enrolling again answers with the copy the reader has.
  r := public.enrol_public_course(pub);
  if (r ->> 'courseId')::uuid is distinct from copy or (r ->> 'replayed')::boolean is not true then
    raise exception 'enrolling twice made a second copy: %', r;
  end if;
  -- A copy is not prepared again from its excerpts.
  begin
    perform public.regenerate_study_course(copy, extensions.gen_random_uuid(), true);
    raise exception 'a public course''s copy was prepared again';
  exception when sqlstate '55000' then
    get stacked diagnostics d = pg_exception_detail;
    if d is distinct from 'public' then raise exception 'a copy''s regeneration said %', d; end if;
  end;
  -- Another reader cannot see this copy.
  perform pg_temp.become_reader(other);
  if exists (select 1 from public.study_course_overview where course_id = copy) then
    raise exception 'another reader could see a reader''s copy';
  end if;
  -- A guest has no account to copy into.
  perform set_config('request.jwt.claims',
    json_build_object('sub', guest, 'role', 'authenticated', 'is_anonymous', true)::text, true);
  begin
    perform public.enrol_public_course(pub);
    raise exception 'a guest enrolled';
  exception when sqlstate '28000' then null;
  end;

  -- ---------------------------------------------------------------- deleting and withdrawing
  -- A reader's copy goes with its course; the excerpts stay, to be used again.
  perform pg_temp.become_reader(reader);
  perform public.delete_study_course(copy);
  r := public.enrol_public_course(pub);
  if (r ->> 'replayed')::boolean is not false
     or (select count(*) from public.study_source_versions
         where owner_id = reader and format = 'public_course') is distinct from 1::bigint then
    raise exception 'enrolling after deleting the copy did not reuse the excerpts: %', r;
  end if;
  copy := (r ->> 'courseId')::uuid;

  -- A work whose rights come into question leaves the catalogue at once.
  perform pg_temp.as_owner();
  update public.works set rights_status = 'review_required' where id = pd_work;
  perform pg_temp.become_reader(other);
  if exists (select 1 from public.list_public_study_courses() where id = pub) then
    raise exception 'a course of a work under rights review stayed in the catalogue';
  end if;
  begin
    perform public.enrol_public_course(pub);
    raise exception 'a course of a work under rights review was enrolled in';
  exception when sqlstate 'P0002' then null;
  end;
  perform pg_temp.as_owner();
  update public.works set rights_status = 'public_domain' where id = pd_work;

  -- Withdrawn with the readers' copies, for a rights complaint.
  perform pg_temp.become_worker();
  r := public.withdraw_public_study_course(pub, 'A reviewer', 'A rights holder asked.', true);
  if (r ->> 'coursesRemoved')::int is distinct from 1 or (r ->> 'sourcesRemoved')::int is distinct from 1 then
    raise exception 'withdrawing with copies removed: %', r;
  end if;
  perform pg_temp.become_reader(reader);
  if exists (select 1 from public.study_courses where id = copy)
     or exists (select 1 from public.study_source_versions where format = 'public_course') then
    raise exception 'a withdrawn course''s copy or excerpts survived';
  end if;
  begin
    perform public.enrol_public_course(pub);
    raise exception 'a withdrawn course was enrolled in';
  exception when sqlstate 'P0002' then null;
  end;

  -- The public course outlives the readers who enrolled: deleting an account takes its copy.
  perform pg_temp.as_owner();
  update public.public_study_courses set withdrawn_at = null, withdrawn_reason = null where id = pub;
  perform pg_temp.become_reader(other);
  r := public.enrol_public_course(pub);
  perform pg_temp.as_owner();
  delete from auth.users where id = other;
  if exists (select 1 from public.study_courses where public_course_id = pub)
     or not exists (select 1 from public.public_study_courses where id = pub) then
    raise exception 'deleting an account did not take its copy, or took the public course';
  end if;

  raise notice 'public study courses: ok';
end
$test$;

rollback;
