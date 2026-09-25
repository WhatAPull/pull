-- Rights-cleared public study courses.
--
-- A reader's study course is private, and CLAUDE.md law 2 keeps it so: a public result of the
-- Studio would be a way to publish around law 4. A PUBLIC course is a different thing, and
-- this migration is the machinery that keeps it different (CLAUDE.md, law 2, "Public study
-- courses"):
--
-- 1. PREPARED BY THE PROJECT, FROM A CLEARED WORK. `publish_study_course` is the service
--    role's alone. It takes a course the project prepared (a curator's own generation, through
--    the ordinary door, ledgered) and a `works` row whose `rights_status` is `public_domain`
--    or `licensed` -- never `user_owned`, `review_required` or anything else -- and a
--    reviewer's name, and records a `moderation_decisions` row.
-- 2. ANALYSIS, NOT REPRODUCTION (law 4). Only validated claims, lessons and questions are
--    published, and the source itself is not: what goes out are the evidence spans the claims
--    quote, each at most 300 characters, together at most a tenth of the source and 20,000
--    characters. They become the course's excerpts, and the evidence points into them.
-- 3. ONE PREPARATION, MANY READERS -- the cost law pointing the right way again. Enrolling
--    (`enrol_public_course`) copies the published snapshot into the reader's own study tables:
--    no model call, no job, nothing against their allowance. Everything per reader then works
--    unchanged -- progress, answers, proof, memory, reports and corrections, on their copy.
-- 4. A PUBLISHED COURSE DOES NOT CHANGE. A new version is a new row. Withdrawing one stops
--    new enrolments; for a rights complaint, the readers' copies can go with it.
--
-- The catalogue is read through two definer functions that return only published courses of
-- cleared works; the table itself is service-role only, since its snapshot carries answer
-- keys.

-- ------------------------------------------------------------------ 1. the published course

create table public.public_study_courses (
  id               uuid primary key default extensions.gen_random_uuid(),
  slug             text not null unique
                   check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$' and char_length(slug) between 3 and 80),
  work_id          uuid not null references public.works (id) on delete restrict,
  title            text not null check (char_length(title) between 1 and 200),
  goal             text not null check (char_length(goal) between 1 and 300),
  overview         text check (overview is null or char_length(overview) <= 2000),
  objectives       text[] not null default '{}' check (cardinality(objectives) <= 6),
  recap            text check (recap is null or char_length(recap) <= 2000),
  -- What the reader's copy of the excerpts is called, and the excerpts themselves.
  excerpt_title    text not null check (char_length(excerpt_title) between 1 and 200),
  excerpts         text not null check (char_length(excerpts) between 1 and 20000),
  snapshot         jsonb not null
                   check (jsonb_typeof(snapshot) = 'object' and pg_column_size(snapshot) <= 2097152),
  -- Lesson titles, objectives and minutes by unit: what the catalogue shows before enrolling.
  outline          jsonb not null check (jsonb_typeof(outline) = 'array'),
  lesson_count     int not null check (lesson_count > 0),
  question_count   int not null check (question_count >= 0),
  from_generation  uuid,
  reviewed_by      text not null check (char_length(btrim(reviewed_by)) between 1 and 200),
  review_note      text check (review_note is null or char_length(review_note) <= 2000),
  published_at     timestamptz not null default now(),
  withdrawn_at     timestamptz,
  withdrawn_reason text check (withdrawn_reason is null or char_length(withdrawn_reason) <= 1000),
  constraint public_study_courses_withdrawn_why
    check ((withdrawn_at is null) = (withdrawn_reason is null))
);

create index public_study_courses_work_idx on public.public_study_courses (work_id);

comment on table public.public_study_courses is
  'A study course the project published from a rights-cleared work: a snapshot of validated '
  'claims, lessons and questions over short excerpts. Readers enrol by copy '
  '(enrol_public_course). Service role only; the catalogue is read through '
  'list_public_study_courses() and get_public_study_course(). See 20260925230000.';

alter table public.public_study_courses enable row level security;
create policy public_study_courses_no_api_access on public.public_study_courses
  for select using (false);
revoke all on public.public_study_courses from public, anon, authenticated;

/* A published course the catalogue may show: not withdrawn, from a work still cleared. */
create function public.public_study_course_open(p_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $fn$
  select exists (
    select 1
    from public.public_study_courses p
    join public.works w on w.id = p.work_id
    where p.id = p_id and p.withdrawn_at is null
      and w.rights_status in ('public_domain', 'licensed')
  )
$fn$;

revoke all on function public.public_study_course_open(uuid) from public, anon, authenticated;

-- ------------------------------------------------------------------ 2. the reader's copy

-- The reader's copy of a public course's excerpts: a source of its own format, which the
-- Studio does not list and nothing can save a version of (save_study_source_version accepts
-- only the formats a reader can upload).
alter table public.study_source_versions
  drop constraint study_source_versions_format_check,
  add constraint study_source_versions_format_check check (format in
    ('paste', 'text', 'markdown', 'pdf', 'docx', 'image_ocr', 'pdf_ocr', 'highlights',
     'public_course'));

alter table public.study_courses
  add column public_course_id uuid references public.public_study_courses (id) on delete restrict;
create index study_courses_public_course_idx on public.study_courses (public_course_id);
-- One copy of a public course per reader.
create unique index study_courses_one_copy on public.study_courses (owner_id, public_course_id)
  where public_course_id is not null;

-- A copied generation has no job and asked for no consent: nothing was sent anywhere.
alter table public.study_generations
  add column public_course_id uuid references public.public_study_courses (id) on delete restrict,
  alter column job_id drop not null,
  alter column processing_consent_at drop not null,
  add constraint study_generations_job_or_public_course
    check ((job_id is null) = (public_course_id is not null)
           and (processing_consent_at is null) = (public_course_id is not null));
create index study_generations_public_course_idx on public.study_generations (public_course_id);

/* How a reader's copy names where it came from: "From <work> (public domain)". */
create function public.public_study_course_label(p_id uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $fn$
  select 'From ' || w.title || ' (' ||
         case w.rights_status when 'public_domain' then 'public domain' else 'licensed' end || ')'
  from public.public_study_courses p
  join public.works w on w.id = p.work_id
  where p.id = p_id
$fn$;

revoke all on function public.public_study_course_label(uuid) from public, anon;
grant execute on function public.public_study_course_label(uuid) to authenticated, service_role;

-- ------------------------------------------------------------------ 3. publishing

/*
 * Publish a course the project prepared, from a rights-cleared work. Service role only.
 * Refused with 42501 `rights` for a work not public domain or licensed, 55000 `unvalidated`
 * for a generation whose text and lessons did not pass validation, 22023 `quotes` when a
 * quotation passes 300 characters or they together pass a tenth of the source or 20,000
 * characters, 22023 for a bad slug or reviewer, and P0002 for no such generation or work.
 */
create function public.publish_study_course(
  p_generation_id uuid,
  p_work_id uuid,
  p_slug text,
  p_reviewed_by text,
  p_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  gen          public.study_generations%rowtype;
  rights       public.rights_status;
  work_title   text;
  source_chars bigint;
  seg          record;
  excerpts     text := '';
  at_          int := 0;
  quoted       int := 0;
  offsets      jsonb := '{}'::jsonb;
  claims       jsonb;
  lessons      jsonb;
  items        jsonb;
  outline      jsonb;
  new_id       uuid;
begin
  if p_reviewed_by is null or char_length(btrim(p_reviewed_by)) not between 1 and 200 then
    raise exception 'say who reviewed the course' using errcode = '22023';
  end if;
  if p_slug is null or p_slug !~ '^[a-z0-9]+(-[a-z0-9]+)*$'
     or char_length(p_slug) not between 3 and 80 then
    raise exception 'a slug is 3 to 80 lower-case letters, digits and single hyphens'
      using errcode = '22023';
  end if;

  select * into gen from public.study_generations where id = p_generation_id for key share;
  if not found then
    raise exception 'no such prepared course' using errcode = 'P0002';
  end if;
  if gen.public_course_id is not null then
    raise exception 'a copy of a public course is not published again'
      using errcode = '55000', detail = 'unvalidated';
  end if;
  if gen.assembled_at is null or gen.text_status <> 'validated'
     or public.study_generation_rank(gen.id) < 2 then
    raise exception 'only a course whose text and lessons passed validation is published'
      using errcode = '55000', detail = 'unvalidated';
  end if;

  select w.rights_status, w.title into rights, work_title
  from public.works w where w.id = p_work_id;
  if not found then
    raise exception 'no such work' using errcode = 'P0002';
  end if;
  if rights not in ('public_domain', 'licensed') then
    raise exception 'only a public-domain or licensed work''s course is published, not %', rights
      using errcode = '42501', detail = 'rights';
  end if;

  -- The excerpts: each quoted span of a validated claim, once, in the source's order.
  select coalesce(sum(char_length(v.extracted_text)), 0) into source_chars
  from public.study_generation_sources gs
  join public.study_source_versions v on v.id = gs.source_version_id
  where gs.generation_id = gen.id;
  for seg in
    select distinct gs.position, e.start_offset, e.end_offset, e.span_text, c.source_version_id
    from public.study_claims c
    join public.study_claim_evidence e on e.claim_id = c.id
    join public.study_generation_sources gs
      on gs.generation_id = c.generation_id and gs.source_version_id = c.source_version_id
    where c.generation_id = gen.id and c.status = 'validated' and e.span_text is not null
    order by gs.position, e.start_offset, e.end_offset
  loop
    if char_length(seg.span_text) > 300 then
      raise exception 'a quotation is % characters; the limit is 300', char_length(seg.span_text)
        using errcode = '22023', detail = 'quotes';
    end if;
    if excerpts <> '' then
      excerpts := excerpts || E'\n\n';
      at_ := at_ + 2;
    end if;
    offsets := offsets || jsonb_build_object(
      seg.source_version_id::text || ':' || seg.start_offset || ':' || seg.end_offset, at_);
    excerpts := excerpts || seg.span_text;
    at_ := at_ + char_length(seg.span_text);
    quoted := quoted + char_length(seg.span_text);
  end loop;
  if quoted = 0 or quoted > 20000 or quoted * 10 > source_chars then
    raise exception 'the quotations total % characters of a % character source; the limit is a '
                    'tenth, and 20,000', quoted, source_chars
      using errcode = '22023', detail = 'quotes';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'key', c.claim_key, 'kind', c.kind, 'statement', c.statement,
           'qualifications', to_jsonb(c.qualifications), 'attribution', c.attribution,
           'promptHash', c.prompt_hash, 'schemaHash', c.schema_hash, 'model', c.model,
           'evidence', (
             select coalesce(jsonb_agg(jsonb_build_object(
                      'ordinal', e.ordinal, 'spanText', e.span_text, 'page', e.page,
                      'start', (offsets ->> (c.source_version_id::text || ':' || e.start_offset
                                             || ':' || e.end_offset))::int)
                      order by e.ordinal), '[]'::jsonb)
             from public.study_claim_evidence e
             where e.claim_id = c.id and e.span_text is not null))
           order by c.claim_key), '[]'::jsonb)
    into claims
  from public.study_claims c
  where c.generation_id = gen.id and c.status = 'validated';

  select coalesce(jsonb_agg(jsonb_build_object(
           'key', l.lesson_key, 'position', l.position, 'unitNo', l.unit_no,
           'unitTitle', l.unit_title, 'title', l.title, 'objective', l.objective,
           'explanation', l.explanation, 'example', l.example, 'recap', l.recap,
           'minutes', l.minutes, 'promptHash', l.prompt_hash, 'schemaHash', l.schema_hash,
           'model', l.model,
           'claimKeys', (select coalesce(jsonb_agg(c.claim_key order by c.claim_key), '[]'::jsonb)
                         from public.study_lesson_claims lc
                         join public.study_claims c on c.id = lc.claim_id
                         where lc.lesson_id = l.id and c.status = 'validated'))
           order by l.unit_no, l.position), '[]'::jsonb),
         coalesce(jsonb_agg(jsonb_build_object(
           'unitNo', l.unit_no, 'unitTitle', l.unit_title, 'title', l.title,
           'objective', l.objective, 'minutes', l.minutes)
           order by l.unit_no, l.position), '[]'::jsonb)
    into lessons, outline
  from public.study_lessons l
  where l.generation_id = gen.id and l.status = 'validated';

  select coalesce(jsonb_agg(jsonb_build_object(
           'key', i.item_key,
           'lessonKey', (select l.lesson_key from public.study_lessons l
                         where l.id = i.lesson_id and l.status = 'validated'),
           'purpose', i.purpose, 'kind', i.kind, 'prompt', i.prompt, 'answer', i.answer,
           'acceptedAnswers', to_jsonb(i.accepted_answers), 'distractors', i.distractors,
           'cloze', i.cloze, 'sequence', to_jsonb(i.sequence), 'pairs', i.pairs,
           'explanation', i.explanation, 'difficulty', i.difficulty,
           'promptHash', i.prompt_hash, 'schemaHash', i.schema_hash, 'model', i.model,
           'claimKeys', (select coalesce(jsonb_agg(c.claim_key order by c.claim_key), '[]'::jsonb)
                         from public.study_item_claims ic
                         join public.study_claims c on c.id = ic.claim_id
                         where ic.item_id = i.id and c.status = 'validated'))
           order by i.item_key), '[]'::jsonb)
    into items
  from public.study_items i
  where i.generation_id = gen.id and i.status = 'validated';

  insert into public.public_study_courses
    (slug, work_id, title, goal, overview, objectives, recap, excerpt_title, excerpts,
     snapshot, outline, lesson_count, question_count, from_generation, reviewed_by, review_note)
  values
    (p_slug, p_work_id, gen.title, gen.goal, gen.overview, gen.objectives, gen.recap,
     left('Excerpts: ' || work_title, 200), excerpts,
     jsonb_build_object('claims', claims, 'lessons', lessons, 'items', items,
                        'disagreements', gen.disagreements, 'withheld', gen.withheld),
     outline, jsonb_array_length(lessons), jsonb_array_length(items), gen.id,
     btrim(p_reviewed_by), p_note)
  returning id into new_id;

  insert into public.moderation_decisions (action, rationale)
  values ('publish_study_course',
          left(format('%s published %s (%s) from generation %s. %s',
                      btrim(p_reviewed_by), p_slug, new_id, gen.id, coalesce(p_note, '')), 2000));

  return jsonb_build_object('id', new_id, 'slug', p_slug, 'lessons', jsonb_array_length(lessons),
                            'questions', jsonb_array_length(items), 'quoted', quoted);
end
$fn$;

/*
 * Withdraw a public course: no new enrolments. `p_remove_copies` also deletes every reader's
 * copy and its excerpts -- for a rights complaint, where the copies are the thing complained
 * of. Service role only.
 */
create function public.withdraw_public_study_course(
  p_id uuid,
  p_by text,
  p_reason text,
  p_remove_copies boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  courses int := 0;
  sources int := 0;
begin
  if p_by is null or char_length(btrim(p_by)) not between 1 and 200
     or p_reason is null or char_length(btrim(p_reason)) not between 1 and 1000 then
    raise exception 'say who is withdrawing the course, and why' using errcode = '22023';
  end if;
  update public.public_study_courses
     set withdrawn_at = coalesce(withdrawn_at, now()),
         withdrawn_reason = coalesce(withdrawn_reason, btrim(p_reason))
   where id = p_id;
  if not found then
    raise exception 'no such public course' using errcode = 'P0002';
  end if;
  if p_remove_copies then
    with gone as (
      delete from public.study_courses c where c.public_course_id = p_id returning 1
    ) select count(*) into courses from gone;
    with gone as (
      delete from public.study_sources s
      where exists (select 1 from public.study_source_versions v
                    where v.source_id = s.id and v.format = 'public_course'
                      and v.origin_label = 'public_course:' || p_id::text)
      returning 1
    ) select count(*) into sources from gone;
  end if;
  insert into public.moderation_decisions (action, rationale)
  values ('withdraw_public_study_course',
          left(format('%s withdrew %s%s. %s', btrim(p_by), p_id,
                      case when p_remove_copies then ', with readers'' copies' else '' end,
                      btrim(p_reason)), 2000));
  return jsonb_build_object('withdrawn', true, 'coursesRemoved', courses,
                            'sourcesRemoved', sources);
end
$fn$;

revoke all on function public.publish_study_course(uuid, uuid, text, text, text)
  from public, anon, authenticated;
revoke all on function public.withdraw_public_study_course(uuid, text, text, boolean)
  from public, anon, authenticated;
grant execute on function public.publish_study_course(uuid, uuid, text, text, text)
  to service_role;
grant execute on function public.withdraw_public_study_course(uuid, text, text, boolean)
  to service_role;

-- ------------------------------------------------------------------ 4. the catalogue

/* The published courses of cleared works, newest first, for anyone. */
create function public.list_public_study_courses()
returns table (
  id             uuid,
  slug           text,
  title          text,
  goal           text,
  overview       text,
  objectives     text[],
  lesson_count   int,
  question_count int,
  work_title     text,
  work_kind      public.work_kind,
  rights_status  public.rights_status,
  published_at   timestamptz
)
language sql
stable
security definer
set search_path = ''
as $fn$
  select p.id, p.slug, p.title, p.goal, p.overview, p.objectives, p.lesson_count,
         p.question_count, w.title, w.kind, w.rights_status, p.published_at
  from public.public_study_courses p
  join public.works w on w.id = p.work_id
  where p.withdrawn_at is null and w.rights_status in ('public_domain', 'licensed')
  order by p.published_at desc, p.id
  limit 200
$fn$;

/* One published course by its slug, with its outline, for anyone. */
create function public.get_public_study_course(p_slug text)
returns table (
  id             uuid,
  slug           text,
  title          text,
  goal           text,
  overview       text,
  objectives     text[],
  recap          text,
  outline        jsonb,
  lesson_count   int,
  question_count int,
  work_title     text,
  work_kind      public.work_kind,
  rights_status  public.rights_status,
  published_at   timestamptz
)
language sql
stable
security definer
set search_path = ''
as $fn$
  select p.id, p.slug, p.title, p.goal, p.overview, p.objectives, p.recap, p.outline,
         p.lesson_count, p.question_count, w.title, w.kind, w.rights_status, p.published_at
  from public.public_study_courses p
  join public.works w on w.id = p.work_id
  where p.slug = p_slug and p.withdrawn_at is null
    and w.rights_status in ('public_domain', 'licensed')
$fn$;

revoke all on function public.list_public_study_courses() from public;
revoke all on function public.get_public_study_course(text) from public;
grant execute on function public.list_public_study_courses() to anon, authenticated, service_role;
grant execute on function public.get_public_study_course(text)
  to anon, authenticated, service_role;

-- ------------------------------------------------------------------ 5. enrolling

/*
 * Copy a public course into the reader's own study tables, as a private course of theirs.
 * No model call, no job, nothing against the reader's allowance: the course was prepared
 * once. One copy per reader -- enrolling again answers with the copy they have -- and twenty
 * new copies a day (54000). Refused with 28000 for a guest and P0002 for a course withdrawn
 * or not published.
 *
 * Lock order as every study write: the account row, the reader's study lock, then the rows.
 */
create function public.enrol_public_course(p_public_course_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  uid       uuid := auth.uid();
  pc        public.public_study_courses%rowtype;
  marker    text := 'public_course:' || p_public_course_id::text;
  v_course  uuid;
  v_source  uuid;
  v_version uuid;
  v_gen     uuid;
  today     int;
  claim     jsonb;
  ev        jsonb;
  lesson    jsonb;
  item      jsonb;
  key_      text;
  claim_ids jsonb := '{}'::jsonb;
  lesson_ids jsonb := '{}'::jsonb;
  new_id    uuid;
begin
  if uid is null then
    raise exception 'enrolling needs a signed-in reader' using errcode = '28000';
  end if;
  perform 1 from auth.users u where u.id = uid and u.is_anonymous is not true for key share;
  if not found then
    raise exception 'a public course is copied into an account, not a guest session'
      using errcode = '28000';
  end if;
  perform pg_advisory_xact_lock(
    pg_catalog.hashtextextended('study_progress:' || uid::text, 0));

  if not public.public_study_course_open(p_public_course_id) then
    raise exception 'no such public course' using errcode = 'P0002';
  end if;
  select * into pc from public.public_study_courses where id = p_public_course_id;

  select c.id into v_course
  from public.study_courses c
  where c.owner_id = uid and c.public_course_id = pc.id;
  if found then
    return jsonb_build_object('courseId', v_course, 'replayed', true);
  end if;

  select count(*) into today
  from public.study_courses c
  where c.owner_id = uid and c.public_course_id is not null
    and c.created_at >= date_trunc('day', now(), 'UTC');
  if today >= 20 then
    raise exception 'that is as many public courses as can be added today; more at 00:00 UTC'
      using errcode = '54000';
  end if;

  -- The reader's copy of the excerpts: kept after its course is deleted, and used again.
  select v.source_id, v.id into v_source, v_version
  from public.study_source_versions v
  where v.owner_id = uid and v.format = 'public_course' and v.origin_label = marker
  order by v.version_no desc
  limit 1;
  if not found then
    insert into public.study_sources (owner_id, latest_version_no)
    values (uid, 1) returning id into v_source;
    insert into public.study_source_versions
      (source_id, owner_id, version_no, client_mutation_id, title, format, origin_label,
       extracted_text)
    values
      (v_source, uid, 1, extensions.gen_random_uuid(), pc.excerpt_title, 'public_course', marker,
       pc.excerpts)
    returning id into v_version;
  end if;

  insert into public.study_courses (owner_id, goal, public_course_id)
  values (uid, pc.goal, pc.id) returning id into v_course;
  insert into public.study_course_sources (course_id, owner_id, source_id, position)
  values (v_course, uid, v_source, 1);
  insert into public.study_generations
    (owner_id, job_id, public_course_id, goal, processing_consent_at, title, overview,
     objectives, recap, disagreements, withheld, assembled_at, course_id)
  values
    (uid, null, pc.id, pc.goal, null, pc.title, pc.overview, pc.objectives, pc.recap,
     coalesce(pc.snapshot -> 'disagreements', '[]'::jsonb),
     coalesce(pc.snapshot -> 'withheld', '[]'::jsonb), now(), v_course)
  returning id into v_gen;
  insert into public.study_generation_sources (generation_id, owner_id, source_version_id, position)
  values (v_gen, uid, v_version, 1);

  perform set_config('study.status_reason', 'enrolled', true);

  for claim in select * from jsonb_array_elements(pc.snapshot -> 'claims') loop
    insert into public.study_claims
      (owner_id, generation_id, source_version_id, claim_key, kind, statement, qualifications,
       attribution, status, prompt_hash, schema_hash, model)
    values
      (uid, v_gen, v_version, claim ->> 'key', claim ->> 'kind', claim ->> 'statement',
       array(select jsonb_array_elements_text(claim -> 'qualifications')),
       claim ->> 'attribution', 'draft', claim ->> 'promptHash', claim ->> 'schemaHash',
       claim ->> 'model')
    returning id into new_id;
    claim_ids := claim_ids || jsonb_build_object(claim ->> 'key', new_id);
    for ev in select * from jsonb_array_elements(claim -> 'evidence') loop
      insert into public.study_claim_evidence
        (claim_id, owner_id, ordinal, model_quote, span_text, start_offset, end_offset, page,
         match)
      values
        (new_id, uid, (ev ->> 'ordinal')::smallint, ev ->> 'spanText', ev ->> 'spanText',
         (ev ->> 'start')::int, (ev ->> 'start')::int + char_length(ev ->> 'spanText'),
         (ev ->> 'page')::int, 'exact');
    end loop;
  end loop;

  for lesson in select * from jsonb_array_elements(pc.snapshot -> 'lessons') loop
    insert into public.study_lessons
      (owner_id, generation_id, lesson_key, position, unit_no, unit_title, title, objective,
       explanation, example, recap, minutes, status, prompt_hash, schema_hash, model)
    values
      (uid, v_gen, lesson ->> 'key', (lesson ->> 'position')::smallint,
       (lesson ->> 'unitNo')::smallint, lesson ->> 'unitTitle', lesson ->> 'title',
       lesson ->> 'objective', lesson ->> 'explanation', lesson ->> 'example',
       lesson ->> 'recap', (lesson ->> 'minutes')::smallint, 'draft',
       lesson ->> 'promptHash', lesson ->> 'schemaHash', lesson ->> 'model')
    returning id into new_id;
    lesson_ids := lesson_ids || jsonb_build_object(lesson ->> 'key', new_id);
    for key_ in select * from jsonb_array_elements_text(lesson -> 'claimKeys') loop
      insert into public.study_lesson_claims (lesson_id, claim_id, owner_id)
      values (new_id, (claim_ids ->> key_)::uuid, uid);
    end loop;
  end loop;

  for item in select * from jsonb_array_elements(pc.snapshot -> 'items') loop
    insert into public.study_items
      (owner_id, generation_id, lesson_id, item_key, purpose, kind, prompt, answer,
       accepted_answers, distractors, cloze, sequence, pairs, explanation, difficulty, status,
       prompt_hash, schema_hash, model)
    values
      (uid, v_gen, (lesson_ids ->> (item ->> 'lessonKey'))::uuid, item ->> 'key',
       item ->> 'purpose', item ->> 'kind', item ->> 'prompt', item ->> 'answer',
       array(select jsonb_array_elements_text(item -> 'acceptedAnswers')),
       coalesce(item -> 'distractors', '[]'::jsonb), item ->> 'cloze',
       array(select jsonb_array_elements_text(item -> 'sequence')),
       coalesce(item -> 'pairs', '[]'::jsonb), item ->> 'explanation',
       (item ->> 'difficulty')::smallint, 'draft', item ->> 'promptHash',
       item ->> 'schemaHash', item ->> 'model')
    returning id into new_id;
    for key_ in select * from jsonb_array_elements_text(item -> 'claimKeys') loop
      insert into public.study_item_claims (item_id, claim_id, owner_id)
      values (new_id, (claim_ids ->> key_)::uuid, uid);
    end loop;
  end loop;

  -- Everything copied passed validation where it was published, and was reviewed by a
  -- person; so it stands here, logged as enrolled rather than validated.
  update public.study_claims set status = 'validated' where generation_id = v_gen;
  update public.study_lessons set status = 'validated' where generation_id = v_gen;
  update public.study_items set status = 'validated' where generation_id = v_gen;
  update public.study_generations set text_status = 'validated' where id = v_gen;

  return jsonb_build_object('courseId', v_course, 'generationId', v_gen, 'replayed', false);
end
$fn$;

revoke all on function public.enrol_public_course(uuid) from public, anon, authenticated;
grant execute on function public.enrol_public_course(uuid) to authenticated;

-- ------------------------------------------------------------------ 6. the overview

/* As 20260925190000, with where a public course's copy came from. */
create or replace view public.study_course_overview with (security_invoker = true) as
-- Materialized: the proven set is computed once per query, not once per course.
with proven as materialized (
  select p.claim_id from public.study_proven_claims() as p
)
select
  c.id as course_id,
  c.goal,
  c.created_at,
  (select count(*) from public.study_course_sources s where s.course_id = c.id)::int
    as source_count,
  cur.id as generation_id,
  case when cur.text_status = 'validated' then cur.title end as title,
  case when cur.text_status = 'validated' then cur.overview end as overview,
  case when cur.text_status = 'validated' then cur.objectives else '{}'::text[] end
    as objectives,
  case when cur.text_status = 'validated' then cur.recap end as recap,
  case when cur.text_status = 'validated' then cur.disagreements else '[]'::jsonb end
    as disagreements,
  case when cur.text_status = 'validated' then cur.withheld else '[]'::jsonb end as withheld,
  latest.generation_id as latest_generation_id,
  latest.job_status as latest_job_status,
  coalesce(latest.job_status in ('queued', 'running'), false) as preparing,
  coalesce(newest.id is not null and newest.id is distinct from cur.id, false)
    as newer_generation_held_back,
  coalesce(saved.id is not null and exists (
    select 1
    from public.study_course_sources cs
    cross join lateral (
      select v.id from public.study_source_versions v
      where v.source_id = cs.source_id
      order by v.version_no desc
      limit 1
    ) as newest_version
    where cs.course_id = c.id
      and not exists (select 1 from public.study_generation_sources gs
                      where gs.generation_id = saved.id
                        and gs.source_version_id = newest_version.id)
  ), false) as update_available,
  (select count(*) from public.study_lessons l
   where l.generation_id = cur.id and l.status = 'validated')::int as lesson_count,
  (select count(*) from public.study_lessons l
   where l.generation_id = cur.id and l.status = 'validated'
     and exists (select 1 from public.study_lessons v
                 join public.study_progress_events e on e.lesson_id = v.id
                 where v.lineage_id = l.lineage_id and e.kind = 'lesson_read'))::int
    as lessons_read_count,
  (select count(*) from public.study_items i
   where i.generation_id = cur.id and i.status = 'validated')::int as question_count,
  (select count(*) from public.study_claims cl
   where cl.generation_id = cur.id and cl.status = 'validated')::int as claim_count,
  (select count(*) from public.study_claims cl
   where cl.generation_id = cur.id and cl.status = 'validated'
     and cl.id in (select proven.claim_id from proven))::int as claims_demonstrated_count,
  coalesce(cur.id is not null and public.study_generation_rank(cur.id) < 2, false) as held_back,
  public.study_generation_awaiting_validation(latest.generation_id) as awaiting_validation,
  -- The newest generation is saved and validation has settled it: whatever its job's
  -- status, it was not lost, and `newer_generation_held_back` or the current generation say
  -- what became of it.
  coalesce(latest.assembled_at is not null and latest.text_status <> 'pending', false)
    as latest_settled,
  c.public_course_id,
  public.public_study_course_label(c.public_course_id) as public_course_label
from public.study_courses c
left join lateral (
  select g.* from public.study_generations g
  where g.id = public.study_course_generation(c.id)
) as cur on true
left join lateral (
  select g.id from public.study_generations g
  where g.course_id = c.id and g.assembled_at is not null and g.text_status <> 'pending'
  order by g.created_at desc, g.id desc
  limit 1
) as newest on true
-- The newest generation that is finished or coming: a new version is judged against what
-- the reader has, or is about to have, not only against what validation has settled.
left join lateral (
  select g.id from public.study_generations g
  where g.course_id = c.id and g.assembled_at is not null
    and (g.text_status <> 'pending' or public.study_generation_awaiting_validation(g.id))
  order by g.created_at desc, g.id desc
  limit 1
) as saved on true
left join lateral (
  select g.id as generation_id, j.status as job_status, g.assembled_at, g.text_status
  from public.study_generations g
  join public.generation_jobs j on j.id = g.job_id
  where g.course_id = c.id
  order by g.created_at desc, g.id desc
  limit 1
) as latest on true;


-- ------------------------------------------------------------------ 7. preparing again

/* As 20260925220000, refusing to prepare a public course's copy again. */
create or replace function public.study_enqueue_course(
  p_source_version_ids uuid[],
  p_goal text,
  p_mutation_id uuid,
  p_processing_consent boolean,
  p_course_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  daily_fast_limit   constant int := 3;
  daily_hard_ceiling constant int := 50;
  stagger_seconds    constant int := 300;
  max_sources        constant int := 5;
  max_total_chars    constant int := 200000;

  uid        uuid := (select auth.uid());
  v_goal     text := btrim(coalesce(p_goal, ''));
  v_versions uuid[] := p_source_version_ids;
  v_course   uuid := p_course_id;
  v_replayed_course uuid;
  wanted     int;
  owned      int;
  total      bigint;
  used       int;
  over       boolean;
  delay_for  int;
  new_job    uuid;
  new_gen    uuid := extensions.gen_random_uuid();
  replayed   public.generation_jobs%rowtype;
begin
  if uid is null then
    raise exception 'study generation requires a signed-in reader' using errcode = '28000';
  end if;
  -- The account row before anything else is locked: saving a source and deleting the
  -- account both take it before the reader's sources, which a regeneration key-shares
  -- below. Taken after them, it deadlocked with either. It is also the guest check.
  perform 1 from auth.users u where u.id = uid and u.is_anonymous is not true for key share;
  if not found then
    raise exception 'study generation needs an account, not a guest session'
      using errcode = '28000';
  end if;
  if not public.study_generation_admitted(uid) then
    raise exception 'study generation is in a limited beta and is not open to this account yet'
      using errcode = '42501', detail = 'beta';
  end if;
  if p_mutation_id is null then
    raise exception 'study generation needs a mutation id' using errcode = '22023';
  end if;

  -- Per-reader serialisation first, so two presses of one submit cannot both miss the
  -- replay below and race to the unique index.
  perform pg_advisory_xact_lock(pg_catalog.hashtextextended(uid::text, 0));

  select * into replayed
  from public.generation_jobs gj
  where gj.requester_id = uid and gj.client_mutation_id = p_mutation_id;
  if found then
    if replayed.kind <> 'study_course' then
      raise exception 'that mutation id belongs to a different request' using errcode = '22023';
    end if;
    select g.course_id into v_replayed_course
    from public.study_generations g where g.job_id = replayed.id;
    -- A regeneration's replay answers only for its own course; a generation since deleted
    -- has no course to compare, and its replay still answers.
    if p_course_id is not null and v_replayed_course is not null
       and v_replayed_course <> p_course_id then
      raise exception 'that mutation id belongs to a different request' using errcode = '22023';
    end if;
    return jsonb_build_object(
      'jobId', replayed.id,
      'generationId', replayed.target ->> 'generationId',
      'courseId', v_replayed_course,
      'status', replayed.status,
      'replayed', true
    );
  end if;

  if p_processing_consent is not true then
    raise exception 'study generation sends your text to the model provider; confirm that first'
      using errcode = '22023';
  end if;

  if v_course is not null then
    -- The bundle's sources first, then the course: a source deletion takes the source
    -- before anything built on it. Only then are the course's goal and versions read.
    perform 1
    from public.study_sources s
    join public.study_course_sources cs on cs.source_id = s.id
    where cs.course_id = v_course and cs.owner_id = uid
    for key share of s;
    select c.goal into v_goal
    from public.study_courses c
    where c.id = v_course and c.owner_id = uid
    for key share;
    if not found then
      raise exception 'no such course' using errcode = 'P0002';
    end if;
    select array_agg(newest.id order by cs.position) into v_versions
    from public.study_course_sources cs
    cross join lateral (
      select v.id from public.study_source_versions v
      where v.source_id = cs.source_id and v.owner_id = uid
      order by v.version_no desc
      limit 1
    ) as newest
    where cs.course_id = v_course and cs.owner_id = uid;
  end if;

  if char_length(v_goal) not between 1 and 300 then
    raise exception 'the study goal must be 1 to 300 characters' using errcode = '22023';
  end if;

  select count(distinct v) into wanted
  from unnest(coalesce(v_versions, '{}'::uuid[])) as v
  where v is not null;
  if wanted < 1 or wanted > max_sources
     or wanted <> cardinality(coalesce(v_versions, '{}'::uuid[])) then
    raise exception 'choose one to % different source versions', max_sources
      using errcode = '22023';
  end if;

  select count(*), coalesce(sum(char_length(v.extracted_text)), 0) into owned, total
  from public.study_source_versions v
  where v.id = any (v_versions) and v.owner_id = uid;
  if owned <> wanted then
    raise exception 'a chosen source version is unavailable'
      using errcode = '42501', detail = 'unavailable';
  end if;
  if total > max_total_chars then
    raise exception 'the chosen sources total % characters; the limit is %', total, max_total_chars
      using errcode = '22023', detail = 'too_large';
  end if;

  if v_course is not null then
    -- A public course's copy is the project's course, not the reader's material, and the
    -- excerpts it carries are not a source to prepare anything from.
    if exists (select 1 from public.study_courses c
               where c.id = v_course and c.public_course_id is not null) then
      raise exception 'a public course is not prepared again'
        using errcode = '55000', detail = 'public';
    end if;
    -- On its way is a job queued or running, or a course saved and awaiting its validation:
    -- preparing again then would buy a duplicate of what the sweep is about to finish.
    if exists (select 1 from public.study_generations g
               join public.generation_jobs j on j.id = g.job_id
               where g.course_id = v_course
                 and (j.status in ('queued', 'running')
                      or public.study_generation_awaiting_validation(g.id))) then
      raise exception 'this course is already being prepared'
        using errcode = '55000', detail = 'preparing';
    end if;
    if exists (
      select 1 from public.study_generations g
      where g.course_id = v_course and g.assembled_at is not null and g.text_status <> 'pending'
        and (select array_agg(gs.source_version_id order by gs.source_version_id)
             from public.study_generation_sources gs where gs.generation_id = g.id)
            = (select array_agg(x order by x) from unnest(v_versions) as x)
    ) then
      raise exception 'nothing in this course''s sources has changed since it was last prepared'
        using errcode = '55000', detail = 'unchanged';
    end if;
  end if;

  if public.spend_today() + public.study_min_job_cents() > public.daily_spend_cap_cents() then
    raise exception 'the daily generation budget is spent. Study generation resumes at 00:00 UTC.'
      using errcode = '53400';
  end if;
  if public.study_requester_spend_today(uid) + public.study_min_job_cents()
     > public.study_requester_daily_cap_cents() then
    raise exception 'your share of today''s study generation budget is spent. It resets at 00:00 UTC.'
      using errcode = '53400';
  end if;

  select count(*) into used
  from public.generation_jobs
  where requester_id = uid
    and created_at >= date_trunc('day', (now() at time zone 'utc')) at time zone 'utc';
  if used >= daily_hard_ceiling then
    raise exception 'daily generation ceiling reached (% jobs); try again tomorrow',
      daily_hard_ceiling using errcode = 'check_violation';
  end if;
  over := used >= daily_fast_limit;
  delay_for := case when over then (used - daily_fast_limit + 1) * stagger_seconds else 0 end;

  if v_course is null then
    insert into public.study_courses (owner_id, goal) values (uid, v_goal)
    returning id into v_course;
    -- One entry per source, in the order its first chosen version was given. Before the
    -- versions are linked below: the sources first, as a deletion takes them.
    insert into public.study_course_sources (course_id, owner_id, source_id, position)
    select v_course, uid, s.source_id,
           row_number() over (order by s.first_ord)::smallint
    from (
      select v.source_id, min(x.ord) as first_ord
      from unnest(v_versions) with ordinality as x(id, ord)
      join public.study_source_versions v on v.id = x.id
      group by v.source_id
    ) as s;
  end if;

  insert into public.generation_jobs
    (requester_id, kind, target, status, current_step, client_mutation_id)
  values
    (uid, 'study_course', jsonb_build_object('generationId', new_gen), 'queued',
     'study_prepare', p_mutation_id)
  returning id into new_job;

  insert into public.study_generations
    (id, owner_id, job_id, goal, processing_consent_at, course_id)
  values (new_gen, uid, new_job, v_goal, now(), v_course);

  insert into public.study_generation_sources (generation_id, owner_id, source_version_id, position)
  select new_gen, uid, v.id, v.ord::smallint
  from unnest(v_versions) with ordinality as v(id, ord);

  perform pgmq.send('generation',
                    jsonb_build_object('jobId', new_job, 'step', 'study_prepare'),
                    delay_for);

  return jsonb_build_object(
    'jobId', new_job,
    'generationId', new_gen,
    'courseId', v_course,
    'status', 'queued',
    'queue', case when over then 'normal' else 'fast' end,
    'delaySeconds', delay_for,
    'remainingToday', daily_hard_ceiling - used - 1,
    'replayed', false
  );
end
$fn$;

