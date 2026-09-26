-- Rights-cleared public study courses.
--
-- A reader's study course is private, and CLAUDE.md law 2 keeps it so: a public result of the
-- Studio would be a way to publish around law 4. A PUBLIC course is a different thing, and
-- this migration is the machinery that keeps it different (CLAUDE.md, law 2, "Public study
-- courses"):
--
-- 1. PREPARED BY THE PROJECT, FROM A CLEARED WORK -- AND NEVER FROM A READER'S MATERIAL.
--    `publish_study_course` is the service role's alone. It takes the current generation of a
--    course prepared by a CURATOR (`study_curators`, an account the service role named) from
--    source versions the service role registered as the text of that very work
--    (`study_curated_sources`), and a `works` row whose `rights_status` is `public_domain` or
--    `licensed` -- never `user_owned`, `review_required` or anything else -- and a reviewer's
--    name, and records a `moderation_decisions` row. A reader's course fails the first test,
--    and a curator's course of anything but the registered text fails the second.
-- 2. ANALYSIS, NOT REPRODUCTION (law 4). Only validated claims, lessons and questions are
--    published, and the source itself is not: what goes out are the evidence spans the claims
--    quote, merged where they overlap or lie within 200 characters of each other into one
--    quotation, each quotation at most 300 characters. Every course published -- a withdrawn
--    one too, whose readers keep their copies -- counts towards what the courses quote between
--    them: of each registered text, whatever work it is registered to, at most a tenth, and
--    of each work, at most 20,000 characters, a passage two courses both quote counted once.
--    They become the course's excerpts, and the evidence points into them. The course's own
--    text -- its lessons, claims, questions, overview -- may not repeat twelve words in a row
--    of the source from outside those quotations.
-- 3. ONE PREPARATION, MANY READERS -- the cost law pointing the right way again. Enrolling
--    (`enrol_public_course`) copies the published snapshot into the reader's own study tables:
--    no model call, no job, nothing against their allowance. Everything per reader then works
--    unchanged -- progress, answers, proof, memory, reports and corrections, on their copy.
-- 4. A PUBLISHED COURSE DOES NOT CHANGE. A new version is a new row; the row itself refuses
--    every change but its withdrawal. Withdrawing one stops new enrolments; for a rights
--    complaint, `remove_public_course_copies` then deletes the readers' copies, a batch at a time.
--
-- The catalogue is read through two definer functions that return only published courses of
-- cleared works, to signed-in readers; the table itself is service-role only, so that nothing
-- about who published what, and no excerpt, is read around those two.

-- ------------------------------------------------------------------ 1. curators

/*
 * The accounts that prepare public courses, named by the service role. A course is published
 * only from a curator's own generation, so no reader's course can be.
 */
create table public.study_curators (
  user_id  uuid primary key references auth.users (id) on delete cascade,
  added_by text not null check (char_length(btrim(added_by)) between 1 and 200),
  added_at timestamptz not null default now()
);

comment on table public.study_curators is
  'Accounts whose study courses may be published as public courses. Service role only. '
  'See 20260925230000.';

alter table public.study_curators enable row level security;
create policy study_curators_no_api_access on public.study_curators for select using (false);
revoke all on public.study_curators from public, anon, authenticated;

/*
 * A curator's saved source version, registered by the service role as the text of a work --
 * before the course is prepared from it. Publishing checks every source of the generation is
 * registered to the work it is published from, so a course is published only from the text
 * that was cleared, never from anything else a curator happened to save.
 */
create table public.study_curated_sources (
  source_version_id uuid primary key
                    references public.study_source_versions (id) on delete cascade,
  work_id           uuid not null references public.works (id) on delete cascade,
  registered_by     text not null check (char_length(btrim(registered_by)) between 1 and 200),
  registered_at     timestamptz not null default now()
);

create index study_curated_sources_work_idx on public.study_curated_sources (work_id);

comment on table public.study_curated_sources is
  'A curator''s source version registered as the text of a rights-cleared work, before a '
  'public course is prepared from it. Service role only. See 20260925230000.';

alter table public.study_curated_sources enable row level security;
create policy study_curated_sources_no_api_access on public.study_curated_sources
  for select using (false);
revoke all on public.study_curated_sources from public, anon, authenticated;

-- ------------------------------------------------------------------ 2. the published course

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
  -- What the reader's copy of the excerpts is called, and the excerpts themselves: at most
  -- 20,000 characters quoted -- a tenth of each source, of at most 200,000 characters between
  -- them (publish_study_course) -- with a blank line between each two of at most 1,200
  -- quotations: 400 claims of up to three spans.
  excerpt_title    text not null check (char_length(excerpt_title) between 1 and 200),
  excerpts         text not null check (char_length(excerpts) between 1 and 24000),
  -- Each quotation, in the excerpts' order: the registered text it quotes (`sha256`, of that
  -- text, and `chars`, its length), where in that text (`from`, `to`), and where in the
  -- excerpts (`at`), in characters. What the courses quote of a text, and of a work, between
  -- them is counted from these -- the source versions may be deleted after publishing -- and a
  -- reader's copy of the excerpts is cut into its quotations by them.
  quotations       jsonb not null
                   check (jsonb_typeof(quotations) = 'array' and jsonb_array_length(quotations) > 0),
  snapshot         jsonb not null
                   check (jsonb_typeof(snapshot) = 'object' and pg_column_size(snapshot) <= 2097152),
  -- Lesson titles, objectives and minutes by unit: what the catalogue shows before enrolling.
  outline          jsonb not null check (jsonb_typeof(outline) = 'array'),
  lesson_count     int not null check (lesson_count > 0),
  question_count   int not null check (question_count >= 0),
  -- The generation it was published from: once. Not a foreign key -- the published course
  -- outlives the curator's working copy -- but never the source of two public courses.
  from_generation  uuid unique,
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
  '(enrol_public_course). Never changes but to be withdrawn. Service role reads only; the '
  'catalogue is read through list_public_study_courses() and get_public_study_course(). '
  'See 20260925230000.';

alter table public.public_study_courses enable row level security;
create policy public_study_courses_no_api_access on public.public_study_courses
  for select using (false);
-- Written only by the definer functions below, which run as the owner: the service role reads.
revoke all on public.public_study_courses from public, anon, authenticated, service_role;
grant select on public.public_study_courses to service_role;

/*
 * A published course does not change. The one update allowed is its withdrawal, once:
 * `withdrawn_at` and `withdrawn_reason` from null to set. An update that changes nothing
 * passes, so a second withdrawal is not an error. It is deleted only once withdrawn and every
 * reader's copy is gone, and never truncated. A copy of the course refers to it; a copy of
 * its excerpts only names it (`origin_label`), and outlives a copy of the course the reader
 * deleted -- deleted before them, the course would stop counting what they hold of the work
 * (publish_study_course), and leave `remove_public_course_copies` nothing to find them by.
 */
create function public.public_study_course_is_final()
returns trigger
language plpgsql
set search_path = ''
as $fn$
begin
  if tg_op = 'TRUNCATE' then
    raise exception 'published courses are not truncated' using errcode = '55000';
  elsif tg_op = 'DELETE' then
    if old.withdrawn_at is null then
      raise exception 'a published course is withdrawn before it is deleted'
        using errcode = '55000';
    end if;
    if exists (select 1 from public.study_source_versions v
               where v.format = 'public_course'
                 and v.origin_label = 'public_course:' || old.id::text) then
      raise exception 'a published course is deleted once every reader''s copy of its excerpts '
                      'is removed (remove_public_course_copies)'
        using errcode = '55000';
    end if;
    return old;
  end if;
  if (to_jsonb(new) - 'withdrawn_at' - 'withdrawn_reason')
       is distinct from (to_jsonb(old) - 'withdrawn_at' - 'withdrawn_reason')
     or (old.withdrawn_at is not null
         and (new.withdrawn_at is distinct from old.withdrawn_at
              or new.withdrawn_reason is distinct from old.withdrawn_reason)) then
    raise exception 'a published course does not change; publish a new version'
      using errcode = '55000';
  end if;
  return new;
end
$fn$;

revoke all on function public.public_study_course_is_final()
  from public, anon, authenticated, service_role;

create trigger public_study_courses_are_final
  before update or delete on public.public_study_courses
  for each row execute function public.public_study_course_is_final();
create trigger public_study_courses_not_truncated
  before truncate on public.public_study_courses
  for each statement execute function public.public_study_course_is_final();

-- ------------------------------------------------------------------ 3. the reader's copy

-- The reader's copy of a public course's excerpts: a source of its own format, which the
-- Studio does not list, nothing prepares a course from (study_enqueue_course), and nothing
-- saves a version into (save_study_source_version).
alter table public.study_source_versions
  drop constraint study_source_versions_format_check,
  add constraint study_source_versions_format_check check (format in
    ('paste', 'text', 'markdown', 'pdf', 'docx', 'image_ocr', 'pdf_ocr', 'highlights',
     'public_course'));
-- Where each quotation lies in the reader's copy of the excerpts: [from, to) pairs, in
-- characters and in order, copied from the published course when the reader enrolled. A
-- quotation may hold a blank line of its own, so the text alone cannot say where one ends.
-- Only a copy of excerpts has them.
alter table public.study_source_versions
  add column quotations jsonb;
alter table public.study_source_versions
  add constraint study_source_versions_quotations_check
    check ((format = 'public_course') = (quotations is not null)
           and (quotations is null or jsonb_typeof(quotations) = 'array'));
-- A reader's excerpts by the public course they came from: how an enrolment finds the copy it
-- keeps, and how removing the copies finds every reader's.
create index study_source_versions_public_course_idx
  on public.study_source_versions (origin_label, owner_id) where format = 'public_course';

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

/*
 * A third author. A lesson or question a curator corrected before publishing is the
 * reader's (`'reader'`) in the curator's course, with no prompt, schema or model behind it;
 * copied into another reader's course it is not that reader's own words, and must not read
 * as them: it is the project's (`'project'`). A person reviewed it and this reader did not
 * write it, so -- like the model's -- an answer to it can prove recall, which a reader's own
 * version never can. Its provenance is as a reader's: none.
 */
alter table public.study_lessons
  drop constraint study_lessons_authored_by_check,
  add constraint study_lessons_authored_by_check
    check (authored_by in ('model', 'reader', 'project'));
alter table public.study_items
  drop constraint study_items_authored_by_check,
  add constraint study_items_authored_by_check
    check (authored_by in ('model', 'reader', 'project'));

/*
 * Where a reader's copy came from -- the work, and its rights in words -- for the reader who
 * owns a copy of that course, and nobody else: the catalogue is how anyone else learns of a
 * public course. The rights are said only while they hold: `public domain` or `licensed`,
 * and null for anything else, so a work whose rights came into question claims none. And
 * whether the course is still on offer -- not withdrawn, its work's rights holding -- which
 * is whether a copy deleted could be added again.
 */
create function public.public_study_course_origin(p_id uuid)
returns table (work_id uuid, work_title text, rights_label text, on_offer boolean)
language sql
stable
security definer
set search_path = ''
as $fn$
  select w.id, w.title,
         case w.rights_status when 'public_domain' then 'public domain'
                              when 'licensed' then 'licensed' end,
         p.withdrawn_at is null and w.rights_status in ('public_domain', 'licensed')
  from public.public_study_courses p
  join public.works w on w.id = p.work_id
  where p.id = p_id
    and exists (select 1 from public.study_courses c
                where c.public_course_id = p.id and c.owner_id = (select auth.uid()))
$fn$;

revoke all on function public.public_study_course_origin(uuid) from public, anon;
grant execute on function public.public_study_course_origin(uuid) to authenticated, service_role;

/*
 * Every public course a reader added, when: what the daily limit on enrolling counts. Kept
 * whether or not the copy is -- deleting a copy and adding it again is another enrolment --
 * and never written through the API. Deleted with the account.
 */
create table public.study_public_enrolments (
  id               uuid primary key default extensions.gen_random_uuid(),
  owner_id         uuid not null references auth.users (id) on delete cascade,
  public_course_id uuid not null references public.public_study_courses (id) on delete cascade,
  enrolled_at      timestamptz not null default now()
);

create index study_public_enrolments_owner_idx
  on public.study_public_enrolments (owner_id, enrolled_at desc);
create index study_public_enrolments_course_idx
  on public.study_public_enrolments (public_course_id);

comment on table public.study_public_enrolments is
  'Each time a reader added a public course (enrol_public_course): the daily limit counts '
  'these, not the copies they still have. Readable by its reader; written by definer '
  'functions only. See 20260925230000.';

alter table public.study_public_enrolments enable row level security;
create policy study_public_enrolments_read_own on public.study_public_enrolments
  for select to authenticated using (owner_id = (select auth.uid()));
revoke all on public.study_public_enrolments from public, anon, authenticated, service_role;
grant select on public.study_public_enrolments to authenticated, service_role;

-- ------------------------------------------------------------------ 4. publishing

/*
 * The runs of `p_words` words in a text, lower-cased with everything but letters and digits
 * read as a space: what "repeats the source" compares. Used when publishing, never on a read.
 * A window over the words, so linear in the text: slicing one array of a 200,000-character
 * source's words at every word took minutes.
 */
create function public.study_word_runs(p_text text, p_words int)
returns table (run text)
language sql
immutable
parallel safe
set search_path = ''
as $fn$
  select x.run
  from (
    select string_agg(w.word, ' ') over win as run, count(*) over win as k
    from regexp_split_to_table(
           btrim(regexp_replace(lower(coalesce(p_text, '')), '[^[:alnum:]]+', ' ', 'g')), ' ')
         with ordinality as w(word, n)
    window win as (order by w.n rows between current row and p_words - 1 following)
  ) as x
  where x.k = p_words
$fn$;

revoke all on function public.study_word_runs(text, int) from public, anon, authenticated;

/*
 * Publish a course the project prepared, from a rights-cleared work. Service role only.
 * Refused, in this order, with:
 *
 *   55000 `isolation`   the transaction is not READ COMMITTED
 *   22023               a bad slug, or no reviewer named
 *   P0002               no such generation
 *   55000 `public`      the generation is a reader's copy of a public course
 *   42501 `curator`     the generation's owner is not a curator
 *   55000 `unvalidated` its text did not pass validation, validation passed no lesson in it,
 *                       or no validated lesson would be published
 *   55000 `superseded`  it is not its course's current generation
 *   55000 `published`   it was published already
 *   P0002               no such work
 *   42501 `rights`      the work is not public domain or licensed
 *   42501 `unregistered` a source of the generation is not registered to that work
 *   22023 `too_large`   more than 400 validated claims or 300 questions
 *   22023 `quotes`      a quotation over 300 characters -- spans that overlap or lie within 200
 *                       characters of each other are one quotation, gap and all -- or, with
 *                       what every course published before it quotes, withdrawn or not, over
 *                       a tenth of a registered text, whatever work each course is of, or
 *                       over 20,000 characters of the work
 *   22023 `copied`      the course's own text repeats twelve words in a row of the source from
 *                       outside its quotations
 *
 * Of the course's disagreements, only one whose claims are all published goes with it: one
 * about a claim held back would say what the course does not.
 *
 * The work's row is locked, FOR NO KEY UPDATE, before its rights are read and its quotations
 * counted: two publications of one work queue there, so neither counts without the other,
 * and an enrolment -- which share-locks it -- waits for a publication rather than reading
 * rights a publication is about to rely on. Not FOR UPDATE: a save or a summary of the work
 * key-shares it, and has no reason to wait for a publication. A text may be registered to two
 * works, whose rows do not serialise their publications, so each registered text the course
 * quotes is locked too -- an advisory lock per text, in key order, after the work's row --
 * before what the courses quote of it is read.
 *
 * The locks serialise publications only if the count is read after they are granted, so a
 * course is published in a READ COMMITTED transaction alone: under REPEATABLE READ or
 * SERIALIZABLE the transaction's one snapshot is taken before them, and does not see the
 * course whose publication they waited for.
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
  max_quotation constant int := 300;
  quotation_gap constant int := 200;
  max_work      constant int := 20000;
  max_claims    constant int := 400;
  max_items     constant int := 300;
  copied_words  constant int := 12;

  gen          public.study_generations%rowtype;
  rights       public.rights_status;
  work_title   text;
  run_         record;
  src          record;
  runs         jsonb := '[]'::jsonb;
  quotations   jsonb := '[]'::jsonb;
  excerpts     text := '';
  quoted       int := 0;
  work_quoted  bigint;
  text_quoted  bigint;
  text_chars   bigint;
  text_hashes  text[];
  lock_key     bigint;
  unquoted     text[] := '{}';
  last_end     int;
  claims       jsonb;
  lessons      jsonb;
  items        jsonb;
  outline      jsonb;
  disagreements jsonb;
  copied       text;
  new_id       uuid;
begin
  if current_setting('transaction_isolation') <> 'read committed' then
    raise exception 'publish in a READ COMMITTED transaction: under an older snapshot, what is '
                    'counted would miss a publication it waited for'
      using errcode = '55000', detail = 'isolation';
  end if;
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
      using errcode = '55000', detail = 'public';
  end if;
  if not exists (select 1 from public.study_curators k where k.user_id = gen.owner_id) then
    raise exception 'only a curator''s course is published, never a reader''s'
      using errcode = '42501', detail = 'curator';
  end if;
  if gen.assembled_at is null or gen.text_status <> 'validated'
     or public.study_generation_rank(gen.id) < 2 then
    raise exception 'only a course whose text and lessons passed validation is published'
      using errcode = '55000', detail = 'unvalidated';
  end if;
  if public.study_course_generation(gen.course_id) is distinct from gen.id then
    raise exception 'only a course''s current version is published'
      using errcode = '55000', detail = 'superseded';
  end if;
  if exists (select 1 from public.public_study_courses p where p.from_generation = gen.id) then
    raise exception 'this version of the course is published already'
      using errcode = '55000', detail = 'published';
  end if;

  select w.rights_status, w.title into rights, work_title
  from public.works w where w.id = p_work_id
  for no key update;
  if not found then
    raise exception 'no such work' using errcode = 'P0002';
  end if;
  if rights not in ('public_domain', 'licensed') then
    raise exception 'only a public-domain or licensed work''s course is published, not %', rights
      using errcode = '42501', detail = 'rights';
  end if;
  if exists (select 1 from public.study_generation_sources gs
             where gs.generation_id = gen.id
               and not exists (select 1 from public.study_curated_sources r
                               where r.source_version_id = gs.source_version_id
                                 and r.work_id = p_work_id)) then
    raise exception 'every source of the course must be registered as this work''s text'
      using errcode = '42501', detail = 'unregistered';
  end if;

  if (select count(*) from public.study_claims c
      where c.generation_id = gen.id and c.status = 'validated') > max_claims
     or (select count(*) from public.study_items i
         where i.generation_id = gen.id and i.status = 'validated') > max_items then
    raise exception 'a public course has at most % claims and % questions', max_claims, max_items
      using errcode = '22023', detail = 'too_large';
  end if;

  -- The quotations: the validated claims' evidence spans, merged where they overlap or lie
  -- closer than `quotation_gap` -- a gap that short is published with them, and a reader would
  -- have the passage either way -- in the source's order. Each is the source's own text, and
  -- is recorded against that text by its hash: a version saved again with the same text is
  -- the same text.
  for run_ in
    with texts as materialized (
      select v.id, encode(sha256(convert_to(v.extracted_text, 'UTF8')), 'hex') as text_hash,
             char_length(v.extracted_text) as chars
      from public.study_generation_sources gs
      join public.study_source_versions v on v.id = gs.source_version_id
      where gs.generation_id = gen.id
    ),
    spans as (
      select distinct gs.position, c.source_version_id as version_id,
             e.start_offset as s, e.end_offset as t
      from public.study_claims c
      join public.study_claim_evidence e on e.claim_id = c.id
      join public.study_generation_sources gs
        on gs.generation_id = c.generation_id and gs.source_version_id = c.source_version_id
      where c.generation_id = gen.id and c.status = 'validated' and e.start_offset is not null
    ),
    opened as (
      select sp.*,
             case when sp.s - max(sp.t) over (partition by sp.version_id order by sp.s, sp.t
                                              rows between unbounded preceding and 1 preceding)
                       < quotation_gap
                  then 0 else 1 end as opens
      from spans sp
    ),
    numbered as (
      select o.*, sum(o.opens) over (partition by o.version_id order by o.s, o.t) as run_no
      from opened o
    ),
    merged as (
      select n.position, n.version_id, min(n.s) as s, max(n.t) as t
      from numbered n
      group by n.position, n.version_id, n.run_no
    )
    select m.position, m.version_id, m.s, m.t, x.text_hash, x.chars
    from merged m
    join texts x on x.id = m.version_id
    order by m.position, m.s
  loop
    if run_.t - run_.s > max_quotation then
      raise exception 'a quotation is % characters, counting what lies between spans closer than '
                      '% characters; the limit is %', run_.t - run_.s, quotation_gap, max_quotation
        using errcode = '22023', detail = 'quotes';
    end if;
    if excerpts <> '' then
      excerpts := excerpts || E'\n\n';
    end if;
    runs := runs || jsonb_build_object('v', run_.version_id, 's', run_.s, 't', run_.t,
                                       'at', char_length(excerpts));
    quotations := quotations || jsonb_build_object('sha256', run_.text_hash, 'chars', run_.chars,
                                                   'from', run_.s, 'to', run_.t,
                                                   'at', char_length(excerpts));
    excerpts := excerpts || (select substr(v.extracted_text, run_.s + 1, run_.t - run_.s)
                             from public.study_source_versions v where v.id = run_.version_id);
    quoted := quoted + (run_.t - run_.s);
  end loop;
  if quoted = 0 then
    raise exception 'a public course quotes the work it teaches, and this one quotes none of it'
      using errcode = '22023', detail = 'quotes';
  end if;

  -- One lock for each registered text the course quotes, in key order, after the work's row:
  -- two publications quoting one text -- of one work or of two -- queue here, so neither
  -- counts what the courses quote of it without the other. Nothing holding one waits for a
  -- work's row.
  text_hashes := array(select distinct q ->> 'sha256'
                       from jsonb_array_elements(quotations) as q);
  for lock_key in
    select distinct pg_catalog.hashtextextended('public_course_text:' || h, 0)
    from unnest(text_hashes) as h
    order by 1
  loop
    perform pg_advisory_xact_lock(lock_key);
  end loop;

  -- What the courses would quote between them of each text this one quotes: its quotations
  -- with those of every published course quoting the same text -- whatever work it was
  -- published from, since a text is known by its hash, not by the work it is registered to,
  -- and withdrawn too, since its readers keep their copies -- merged, so a passage two courses
  -- quote is counted once and publishing the same passages again takes nothing more. Checked
  -- against a tenth of each text, the most-quoted for its length.
  with ranges as (
    select q ->> 'sha256' as text_hash, (q ->> 'chars')::bigint as chars,
           int4range((q ->> 'from')::int, (q ->> 'to')::int) as r
    from public.public_study_courses p
    cross join jsonb_array_elements(p.quotations) as q
    where q ->> 'sha256' = any (text_hashes)
    union all
    select q ->> 'sha256', (q ->> 'chars')::bigint,
           int4range((q ->> 'from')::int, (q ->> 'to')::int)
    from jsonb_array_elements(quotations) as q
  ),
  by_text as (
    select x.text_hash, max(x.chars) as chars, range_agg(x.r) as quoted
    from ranges x
    group by x.text_hash
  ),
  measured as (
    select b.chars,
           (select sum(upper(piece) - lower(piece)) from unnest(b.quoted) as piece) as quoted
    from by_text b
  )
  select (array_agg(m.quoted order by m.quoted::numeric / greatest(m.chars, 1) desc))[1],
         (array_agg(m.chars order by m.quoted::numeric / greatest(m.chars, 1) desc))[1]
    into text_quoted, text_chars
  from measured m;
  if text_quoted * 10 > text_chars then
    raise exception 'the courses would quote % characters of a % character text between them; '
                    'the limit is a tenth', text_quoted, text_chars
      using errcode = '22023', detail = 'quotes';
  end if;

  -- And what the work's courses would quote of it between them: this one's quotations with
  -- those of every course published from the work, withdrawn too, merged text by text, against
  -- the work's 20,000 characters.
  with ranges as (
    select q ->> 'sha256' as text_hash, int4range((q ->> 'from')::int, (q ->> 'to')::int) as r
    from public.public_study_courses p
    cross join jsonb_array_elements(p.quotations) as q
    where p.work_id = p_work_id
    union all
    select q ->> 'sha256', int4range((q ->> 'from')::int, (q ->> 'to')::int)
    from jsonb_array_elements(quotations) as q
  ),
  by_text as (
    select range_agg(x.r) as quoted
    from ranges x
    group by x.text_hash
  )
  select sum(upper(piece) - lower(piece)) into work_quoted
  from by_text b
  cross join lateral unnest(b.quoted) as piece;
  if work_quoted > max_work then
    raise exception 'the work''s courses would quote % characters of it between them; the limit is %',
      work_quoted, max_work
      using errcode = '22023', detail = 'quotes';
  end if;

  -- What of the source is not quoted: each version's text around its quotations, in pieces, so
  -- no run of words is read across a quotation.
  for src in
    select gs.source_version_id as version_id, v.extracted_text as body
    from public.study_generation_sources gs
    join public.study_source_versions v on v.id = gs.source_version_id
    where gs.generation_id = gen.id
  loop
    last_end := 0;
    for run_ in
      select (r ->> 's')::int as s, (r ->> 't')::int as t
      from jsonb_array_elements(runs) as r
      where (r ->> 'v')::uuid = src.version_id
      order by 1
    loop
      unquoted := unquoted || substr(src.body, last_end + 1, run_.s - last_end);
      last_end := run_.t;
    end loop;
    unquoted := unquoted || substr(src.body, last_end + 1);
  end loop;

  -- The snapshot. Each evidence span is re-pointed into the excerpts: its quotation's place
  -- there, plus how far into the quotation it starts.
  select coalesce(jsonb_agg(jsonb_build_object(
           'key', c.claim_key, 'kind', c.kind, 'statement', c.statement,
           'qualifications', to_jsonb(c.qualifications), 'attribution', c.attribution,
           'promptHash', c.prompt_hash, 'schemaHash', c.schema_hash, 'model', c.model,
           'evidence', (
             select coalesce(jsonb_agg(jsonb_build_object(
                      'ordinal', e.ordinal, 'spanText', e.span_text, 'page', e.page,
                      'start', (select (r ->> 'at')::int + e.start_offset - (r ->> 's')::int
                                from jsonb_array_elements(runs) as r
                                where (r ->> 'v')::uuid = c.source_version_id
                                  and e.start_offset >= (r ->> 's')::int
                                  and e.end_offset <= (r ->> 't')::int))
                      order by e.ordinal), '[]'::jsonb)
             from public.study_claim_evidence e
             where e.claim_id = c.id and e.start_offset is not null))
           order by c.claim_key), '[]'::jsonb)
    into claims
  from public.study_claims c
  where c.generation_id = gen.id and c.status = 'validated';

  select coalesce(jsonb_agg(jsonb_build_object(
           'key', l.lesson_key, 'position', l.position, 'unitNo', l.unit_no,
           'unitTitle', l.unit_title, 'title', l.title, 'objective', l.objective,
           'explanation', l.explanation, 'example', l.example, 'recap', l.recap,
           'minutes', l.minutes, 'authoredBy', l.authored_by, 'promptHash', l.prompt_hash,
           'schemaHash', l.schema_hash, 'model', l.model,
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
  if jsonb_array_length(lessons) = 0 then
    raise exception 'no lesson of this course is validated now' using errcode = '55000',
      detail = 'unvalidated';
  end if;

  -- A question whose lesson is held back is not published: it belongs to a lesson the copy
  -- would not have, and would read there as the course's own, which it was not written as.
  -- Nor is one resting on a claim that is not published: here it proves nothing of that claim
  -- (study_answer_proves_recall), and in a copy without the claim it would prove the rest.
  select coalesce(jsonb_agg(jsonb_build_object(
           'key', i.item_key,
           'lessonKey', (select l.lesson_key from public.study_lessons l where l.id = i.lesson_id),
           'purpose', i.purpose, 'kind', i.kind, 'prompt', i.prompt, 'answer', i.answer,
           'acceptedAnswers', to_jsonb(i.accepted_answers), 'distractors', i.distractors,
           'cloze', i.cloze, 'sequence', to_jsonb(i.sequence), 'pairs', i.pairs,
           'explanation', i.explanation, 'difficulty', i.difficulty,
           'authoredBy', i.authored_by, 'promptHash', i.prompt_hash,
           'schemaHash', i.schema_hash, 'model', i.model,
           'claimKeys', (select coalesce(jsonb_agg(c.claim_key order by c.claim_key), '[]'::jsonb)
                         from public.study_item_claims ic
                         join public.study_claims c on c.id = ic.claim_id
                         where ic.item_id = i.id and c.status = 'validated'))
           order by i.item_key), '[]'::jsonb)
    into items
  from public.study_items i
  where i.generation_id = gen.id and i.status = 'validated'
    and (i.lesson_id is null
         or exists (select 1 from public.study_lessons l
                    where l.id = i.lesson_id and l.status = 'validated'))
    and not exists (select 1 from public.study_item_claims ic
                    join public.study_claims c on c.id = ic.claim_id
                    where ic.item_id = i.id and c.status <> 'validated');

  -- Nor is a disagreement, unless every claim it is between is published: one about a claim
  -- held back would say, in the course's voice, what the reviewer took out of it.
  select coalesce(jsonb_agg(x.d order by x.n), '[]'::jsonb) into disagreements
  from jsonb_array_elements(gen.disagreements) with ordinality as x(d, n)
  where jsonb_typeof(x.d -> 'claimKeys') = 'array'
    and jsonb_array_length(x.d -> 'claimKeys') > 0
    and not exists (select 1 from jsonb_array_elements_text(x.d -> 'claimKeys') as k(claim_key)
                    where not exists (select 1 from jsonb_array_elements(claims) as c
                                      where c ->> 'key' = k.claim_key));

  -- Analysis, not reproduction: every word the course says of its own -- all the snapshot's
  -- text but the evidence, which is quotation -- against the source outside its quotations.
  select f.run into copied
  from (
    select distinct r.run
    from jsonb_path_query(
           jsonb_build_array(gen.title, gen.goal, gen.overview, to_jsonb(gen.objectives),
                             gen.recap, disagreements, gen.withheld, lessons, items,
                             (select coalesce(jsonb_agg(c - 'evidence'), '[]'::jsonb)
                              from jsonb_array_elements(claims) as c)),
           'strict $.**') as j
    cross join lateral public.study_word_runs(j #>> '{}', copied_words) as r
    where jsonb_typeof(j) = 'string'
  ) as f
  where f.run in (select r.run
                  from unnest(unquoted) as u(piece)
                  cross join lateral public.study_word_runs(u.piece, copied_words) as r)
  limit 1;
  if copied is not null then
    raise exception 'the course''s own text repeats the work outside its quotations: "%"', copied
      using errcode = '22023', detail = 'copied';
  end if;

  insert into public.public_study_courses
    (slug, work_id, title, goal, overview, objectives, recap, excerpt_title, excerpts,
     quotations, snapshot, outline, lesson_count, question_count, from_generation, reviewed_by,
     review_note)
  values
    (p_slug, p_work_id, gen.title, gen.goal, gen.overview, gen.objectives, gen.recap,
     left('Excerpts: ' || work_title, 200), excerpts, quotations,
     jsonb_build_object('claims', claims, 'lessons', lessons, 'items', items,
                        'disagreements', disagreements, 'withheld', gen.withheld),
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
 * Withdraw a public course: no new enrolments, and out of the catalogue. Service role only.
 * It locks the course row first, FOR UPDATE -- an enrolment share-locks it, so one in flight
 * finishes first and the next sees the course withdrawn -- and touches nobody's copy: for a
 * rights complaint, `remove_public_course_copies` does that afterwards. Withdrawing again
 * keeps the first withdrawal and records the decision again.
 */
create function public.withdraw_public_study_course(
  p_id uuid,
  p_by text,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  pc public.public_study_courses%rowtype;
begin
  if p_by is null or char_length(btrim(p_by)) not between 1 and 200
     or p_reason is null or char_length(btrim(p_reason)) not between 1 and 1000 then
    raise exception 'say who is withdrawing the course, and why' using errcode = '22023';
  end if;
  select * into pc from public.public_study_courses where id = p_id for update;
  if not found then
    raise exception 'no such public course' using errcode = 'P0002';
  end if;
  if pc.withdrawn_at is null then
    update public.public_study_courses
       set withdrawn_at = now(), withdrawn_reason = btrim(p_reason)
     where id = p_id;
  end if;
  insert into public.moderation_decisions (action, rationale)
  values ('withdraw_public_study_course',
          left(format('%s withdrew %s. %s', btrim(p_by), p_id, btrim(p_reason)), 2000));
  return jsonb_build_object(
    'withdrawn', true,
    'copies', (select count(*) from public.study_courses c where c.public_course_id = p_id));
end
$fn$;

/*
 * Delete readers' copies of a withdrawn public course, and their copies of its excerpts: at
 * most `p_limit` readers' at a time, in owner-id order, each reader's study lock taken before
 * any row of theirs is touched, and then their sources before their courses -- the order every
 * study write keeps (docs/study-courses.md, "Lock order"). The excerpts are the copy's only
 * source, so deleting them takes the copy with them (the last-source trigger); a copy whose
 * excerpts the reader deleted went with them already. Returns how many readers it went
 * through -- one who deleted their copy while it waited for their lock is counted, and has
 * nothing left to remove -- so call it until it returns 0. Service role only; refused (55000)
 * while the course is still offered.
 */
create function public.remove_public_course_copies(p_id uuid, p_limit int default 100)
returns int
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  marker  text := 'public_course:' || p_id::text;
  gone    timestamptz;
  owners  uuid[];
  o       uuid;
begin
  if p_limit is null or p_limit not between 1 and 1000 then
    raise exception 'remove 1 to 1000 readers'' copies at a time' using errcode = '22023';
  end if;
  select p.withdrawn_at into gone from public.public_study_courses p where p.id = p_id;
  if not found then
    raise exception 'no such public course' using errcode = 'P0002';
  end if;
  if gone is null then
    raise exception 'withdraw the course before removing readers'' copies of it'
      using errcode = '55000';
  end if;

  owners := array(
    select x.owner_id from (
      select c.owner_id from public.study_courses c where c.public_course_id = p_id
      union
      select v.owner_id from public.study_source_versions v
      where v.format = 'public_course' and v.origin_label = marker
    ) as x
    order by x.owner_id
    limit p_limit);
  foreach o in array owners loop
    perform pg_advisory_xact_lock(pg_catalog.hashtextextended('study_progress:' || o::text, 0));
  end loop;

  delete from public.study_sources s
  where s.owner_id = any (owners)
    and exists (select 1 from public.study_source_versions v
                where v.source_id = s.id and v.format = 'public_course'
                  and v.origin_label = marker);
  delete from public.study_courses c
  where c.public_course_id = p_id and c.owner_id = any (owners);
  return cardinality(owners);
end
$fn$;

revoke all on function public.publish_study_course(uuid, uuid, text, text, text)
  from public, anon, authenticated;
revoke all on function public.withdraw_public_study_course(uuid, text, text)
  from public, anon, authenticated;
revoke all on function public.remove_public_course_copies(uuid, int)
  from public, anon, authenticated;
grant execute on function public.publish_study_course(uuid, uuid, text, text, text)
  to service_role;
grant execute on function public.withdraw_public_study_course(uuid, text, text)
  to service_role;
grant execute on function public.remove_public_course_copies(uuid, int) to service_role;

-- ------------------------------------------------------------------ 5. the catalogue

/*
 * The published courses of cleared works, newest first, for a signed-in reader: the app
 * offers them on /courses, which neither a visitor nor a guest is shown. A guest is refused
 * as a visitor is (42501): a public course is copied into an account, and a guest session
 * is not one. The service role reads the table itself.
 */
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
  work_id        uuid,
  work_title     text,
  work_kind      public.work_kind,
  rights_status  public.rights_status,
  published_at   timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $fn$
begin
  if not exists (select 1 from auth.users u
                 where u.id = (select auth.uid()) and u.is_anonymous is not true) then
    raise exception 'the public courses are offered to a signed-in reader' using errcode = '42501';
  end if;
  return query
  select p.id, p.slug, p.title, p.goal, p.overview, p.objectives, p.lesson_count,
         p.question_count, w.id, w.title, w.kind, w.rights_status, p.published_at
  from public.public_study_courses p
  join public.works w on w.id = p.work_id
  where p.withdrawn_at is null and w.rights_status in ('public_domain', 'licensed')
  order by p.published_at desc, p.id
  limit 200;
end
$fn$;

/* One published course by its slug, with its outline, for a signed-in reader, as the list is. */
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
  work_id        uuid,
  work_title     text,
  work_kind      public.work_kind,
  rights_status  public.rights_status,
  published_at   timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $fn$
begin
  if not exists (select 1 from auth.users u
                 where u.id = (select auth.uid()) and u.is_anonymous is not true) then
    raise exception 'the public courses are offered to a signed-in reader' using errcode = '42501';
  end if;
  return query
  select p.id, p.slug, p.title, p.goal, p.overview, p.objectives, p.recap, p.outline,
         p.lesson_count, p.question_count, w.id, w.title, w.kind, w.rights_status,
         p.published_at
  from public.public_study_courses p
  join public.works w on w.id = p.work_id
  where p.slug = p_slug and p.withdrawn_at is null
    and w.rights_status in ('public_domain', 'licensed');
end
$fn$;

revoke all on function public.list_public_study_courses() from public, anon, service_role;
revoke all on function public.get_public_study_course(text) from public, anon, service_role;
grant execute on function public.list_public_study_courses() to authenticated;
grant execute on function public.get_public_study_course(text) to authenticated;

-- ------------------------------------------------------------------ 6. enrolling

/*
 * Copy a public course into the reader's own study tables, as a private course of theirs.
 * No model call, no job, nothing against the reader's allowance: the course was prepared
 * once. One copy per reader -- enrolling again answers with the copy they have, and is not
 * counted -- and twenty enrolments a day (54000), counted from `study_public_enrolments`, so
 * deleting a copy and adding it again counts twice. Refused with 28000 for a guest and P0002
 * for a course withdrawn, not published, or whose work's rights came into question.
 *
 * Lock order, as every study write and before any row of the reader's (docs/study-courses.md,
 * "Lock order"): the account row, FOR NO KEY UPDATE -- as `delete_my_account` takes it, so an
 * enrolment waits for a deletion in flight here rather than key-sharing past it and meeting it
 * at the reader's study lock; then the course and its work, FOR SHARE, read open under that
 * lock -- a withdrawal locks the course FOR UPDATE, so it waits for this enrolment, and one
 * that follows sees it; then the reader's study lock.
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
begin
  if uid is null then
    raise exception 'enrolling needs a signed-in reader' using errcode = '28000';
  end if;
  perform 1 from auth.users u where u.id = uid and u.is_anonymous is not true
  for no key update;
  if not found then
    raise exception 'a public course is copied into an account, not a guest session'
      using errcode = '28000';
  end if;
  select p.* into pc
  from public.public_study_courses p
  join public.works w on w.id = p.work_id
  where p.id = p_public_course_id and p.withdrawn_at is null
    and w.rights_status in ('public_domain', 'licensed')
  for share of p, w;
  if not found then
    raise exception 'no such public course' using errcode = 'P0002';
  end if;
  perform pg_advisory_xact_lock(
    pg_catalog.hashtextextended('study_progress:' || uid::text, 0));

  select c.id into v_course
  from public.study_courses c
  where c.owner_id = uid and c.public_course_id = pc.id;
  if found then
    return jsonb_build_object('courseId', v_course, 'replayed', true);
  end if;

  select count(*) into today
  from public.study_public_enrolments e
  where e.owner_id = uid and e.enrolled_at >= date_trunc('day', now(), 'UTC');
  if today >= 20 then
    raise exception 'that is as many public courses as can be added today; more at 00:00 UTC'
      using errcode = '54000';
  end if;

  -- The reader's copy of the excerpts: kept after its course is deleted, and used again. With
  -- where each quotation lies in it, which the text alone does not say.
  select v.source_id, v.id into v_source, v_version
  from public.study_source_versions v
  where v.origin_label = marker and v.owner_id = uid and v.format = 'public_course'
  order by v.version_no desc
  limit 1;
  if not found then
    insert into public.study_sources (owner_id, latest_version_no)
    values (uid, 1) returning id into v_source;
    insert into public.study_source_versions
      (source_id, owner_id, version_no, client_mutation_id, title, format, origin_label,
       extracted_text, quotations)
    values
      (v_source, uid, 1, extensions.gen_random_uuid(), pc.excerpt_title, 'public_course', marker,
       pc.excerpts,
       (select jsonb_agg(jsonb_build_array((q ->> 'at')::int,
                                           (q ->> 'at')::int + (q ->> 'to')::int - (q ->> 'from')::int)
                         order by (q ->> 'at')::int)
        from jsonb_array_elements(pc.quotations) as q))
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

  -- The snapshot, a set at a time. Each link is made by key within the new generation, and a
  -- key that finds nothing leaves a null a NOT NULL column refuses, rather than a link lost.
  insert into public.study_claims
    (owner_id, generation_id, source_version_id, claim_key, kind, statement, qualifications,
     attribution, status, prompt_hash, schema_hash, model)
  select uid, v_gen, v_version, c ->> 'key', c ->> 'kind', c ->> 'statement',
         array(select jsonb_array_elements_text(c -> 'qualifications')),
         c ->> 'attribution', 'draft', c ->> 'promptHash', c ->> 'schemaHash', c ->> 'model'
  from jsonb_array_elements(pc.snapshot -> 'claims') as c;

  insert into public.study_claim_evidence
    (claim_id, owner_id, ordinal, model_quote, span_text, start_offset, end_offset, page, match)
  select sc.id, uid, (ev ->> 'ordinal')::smallint, ev ->> 'spanText', ev ->> 'spanText',
         (ev ->> 'start')::int, (ev ->> 'start')::int + char_length(ev ->> 'spanText'),
         (ev ->> 'page')::int, 'exact'
  from jsonb_array_elements(pc.snapshot -> 'claims') as c
  cross join jsonb_array_elements(c -> 'evidence') as ev
  left join public.study_claims sc on sc.generation_id = v_gen and sc.claim_key = c ->> 'key';

  -- A lesson or question a curator corrected is the project's in the reader's copy, not the
  -- reader's own: see the authored_by constraints above.
  insert into public.study_lessons
    (owner_id, generation_id, lesson_key, position, unit_no, unit_title, title, objective,
     explanation, example, recap, minutes, status, authored_by, prompt_hash, schema_hash, model)
  select uid, v_gen, l ->> 'key', (l ->> 'position')::smallint, (l ->> 'unitNo')::smallint,
         l ->> 'unitTitle', l ->> 'title', l ->> 'objective', l ->> 'explanation',
         l ->> 'example', l ->> 'recap', (l ->> 'minutes')::smallint, 'draft', a.by,
         case when a.by = 'model' then l ->> 'promptHash' end,
         case when a.by = 'model' then l ->> 'schemaHash' end,
         case when a.by = 'model' then l ->> 'model' end
  from jsonb_array_elements(pc.snapshot -> 'lessons') as l
  cross join lateral (
    select case l ->> 'authoredBy' when 'model' then 'model'
                                   when 'reader' then 'project' end as by
  ) as a;

  insert into public.study_lesson_claims (lesson_id, claim_id, owner_id)
  select sl.id, sc.id, uid
  from jsonb_array_elements(pc.snapshot -> 'lessons') as l
  cross join jsonb_array_elements_text(l -> 'claimKeys') as k(claim_key)
  left join public.study_lessons sl on sl.generation_id = v_gen and sl.lesson_key = l ->> 'key'
  left join public.study_claims sc on sc.generation_id = v_gen and sc.claim_key = k.claim_key;

  insert into public.study_items
    (owner_id, generation_id, lesson_id, item_key, purpose, kind, prompt, answer,
     accepted_answers, distractors, cloze, sequence, pairs, explanation, difficulty, status,
     authored_by, prompt_hash, schema_hash, model)
  select uid, v_gen, sl.id, i ->> 'key', i ->> 'purpose', i ->> 'kind', i ->> 'prompt',
         i ->> 'answer', array(select jsonb_array_elements_text(i -> 'acceptedAnswers')),
         coalesce(i -> 'distractors', '[]'::jsonb), i ->> 'cloze',
         array(select jsonb_array_elements_text(i -> 'sequence')),
         coalesce(i -> 'pairs', '[]'::jsonb), i ->> 'explanation',
         (i ->> 'difficulty')::smallint, 'draft', a.by,
         case when a.by = 'model' then i ->> 'promptHash' end,
         case when a.by = 'model' then i ->> 'schemaHash' end,
         case when a.by = 'model' then i ->> 'model' end
  from jsonb_array_elements(pc.snapshot -> 'items') as i
  cross join lateral (
    select case i ->> 'authoredBy' when 'model' then 'model'
                                   when 'reader' then 'project' end as by
  ) as a
  left join public.study_lessons sl on sl.generation_id = v_gen and sl.lesson_key = i ->> 'lessonKey';
  if exists (select 1 from jsonb_array_elements(pc.snapshot -> 'items') as i
             where i ->> 'lessonKey' is not null
               and not exists (select 1 from public.study_lessons sl
                               where sl.generation_id = v_gen
                                 and sl.lesson_key = i ->> 'lessonKey')) then
    raise exception 'a published question names a lesson the course does not have'
      using errcode = '23503';
  end if;

  insert into public.study_item_claims (item_id, claim_id, owner_id)
  select si.id, sc.id, uid
  from jsonb_array_elements(pc.snapshot -> 'items') as i
  cross join jsonb_array_elements_text(i -> 'claimKeys') as k(claim_key)
  left join public.study_items si on si.generation_id = v_gen and si.item_key = i ->> 'key'
  left join public.study_claims sc on sc.generation_id = v_gen and sc.claim_key = k.claim_key;

  -- Everything copied passed validation where it was published, and was reviewed by a
  -- person; so it stands here, logged as enrolled rather than validated.
  update public.study_claims set status = 'validated' where generation_id = v_gen;
  update public.study_lessons set status = 'validated' where generation_id = v_gen;
  update public.study_items set status = 'validated' where generation_id = v_gen;
  update public.study_generations set text_status = 'validated' where id = v_gen;

  insert into public.study_public_enrolments (owner_id, public_course_id) values (uid, pc.id);
  -- Nothing later in the reader's transaction is logged as enrolled.
  perform set_config('study.status_reason', '', true);

  return jsonb_build_object('courseId', v_course, 'generationId', v_gen, 'replayed', false);
end
$fn$;

revoke all on function public.enrol_public_course(uuid) from public, anon, authenticated;
grant execute on function public.enrol_public_course(uuid) to authenticated;

-- ------------------------------------------------------------------ 7. the overview

/*
 * As 20260925190000, with where a public course's copy came from: the public course, its
 * work, the work's rights in words while they hold, and whether the course is still on offer
 * (`public_study_course_origin`). The work's id only while the reader can open the work's
 * page -- read here as the reader, so under the policy that page is read under: a work is
 * listed while a summary of it is readable, and publishing a course does not need one.
 */
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
  origin.rights_label as public_course_label,
  case when exists (select 1 from public.works w where w.id = origin.work_id)
       then origin.work_id end as public_course_work_id,
  origin.work_title as public_course_work_title,
  coalesce(origin.on_offer, false) as public_course_on_offer
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
) as latest on true
left join lateral (
  select o.work_id, o.work_title, o.rights_label, o.on_offer
  from public.public_study_course_origin(c.public_course_id) as o
  where c.public_course_id is not null
) as origin on true;

-- ------------------------------------------------------------------ 8. the project's words prove

/* As 20260925080000, with a question the project corrected proving as the model's does. */
create or replace function public.study_answer_proves_recall(p_event_id uuid)
returns boolean
language sql
stable
set search_path = ''
as $fn$
  select coalesce((
    select e.correct
       and not e.hinted
       and e.grading = 'deterministic'
       and public.study_item_status_at(e.item_id, e.answered_at) = 'validated'
       and exists (select 1 from public.study_items i
                   where i.id = e.item_id and i.status = 'validated'
                     and i.authored_by in ('model', 'project'))
       and not exists (select 1 from public.study_item_claims ic
                       join public.study_claims c on c.id = ic.claim_id
                       where ic.item_id = e.item_id and c.status <> 'validated')
    from public.study_answer_events e
    where e.id = p_event_id), false)
$fn$;

/* As 20260925090000, with a question the project corrected proving as the model's does. */
create or replace function public.study_proven_claims()
returns table (claim_id uuid, proven_at timestamptz)
language sql
stable
security invoker
set search_path = ''
as $fn$
  select ic.claim_id, max(e.answered_at)
  from public.study_answer_events e
  join public.study_items i
    on i.id = e.item_id and i.status = 'validated' and i.authored_by in ('model', 'project')
  join public.study_item_claims ic on ic.item_id = e.item_id
  cross join lateral (
    select l.to_status
    from public.study_status_log l
    where l.item_id = e.item_id and l.at <= e.answered_at
    order by l.at desc, l.id desc
    limit 1
  ) as then_status
  where e.correct
    and not e.hinted
    and e.grading = 'deterministic'
    and then_status.to_status = 'validated'
    and not exists (select 1 from public.study_item_claims ic2
                    join public.study_claims c on c.id = ic2.claim_id
                    where ic2.item_id = e.item_id and c.status <> 'validated')
  group by ic.claim_id
$fn$;

/*
 * As 20260925100000: a row written by the model or copied from a public course starts as a
 * draft or rejected, and only a reader's own correction is written validated.
 */
create or replace function public.study_generated_rows_start_as_drafts()
returns trigger
language plpgsql
set search_path = ''
as $fn$
begin
  if new.status not in ('draft', 'rejected')
     and coalesce(to_jsonb(new) ->> 'authored_by', 'model') in ('model', 'project') then
    raise exception 'a generated % starts as a draft or rejected, not %',
      tg_argv[0], new.status using errcode = '22023';
  end if;
  return new;
end
$fn$;

/* As 20260925210000, with a question the project corrected scoring as the model's does. */
create or replace function public.study_remember(p_event_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  e       public.study_answer_events%rowtype;
  proves  boolean;
  scores  boolean;
  c       uuid;
  m       public.study_claim_memory%rowtype;
begin
  select * into e from public.study_answer_events where id = p_event_id;
  if not found then
    return;
  end if;
  if e.correct then
    -- A right answer moves the memory only as proof.
    if not public.study_answer_proves_recall(e.id) then
      return;
    end if;
    proves := true;
    scores := true;
  else
    -- A wrong one scores where a right one would have proved, hint or none: the proof rule
    -- without its first two clauses.
    proves := false;
    scores := e.grading = 'deterministic'
      and public.study_item_status_at(e.item_id, e.answered_at) = 'validated'
      and exists (select 1 from public.study_items i
                  where i.id = e.item_id and i.status = 'validated'
                    and i.authored_by in ('model', 'project'))
      and not exists (select 1 from public.study_item_claims ic
                      join public.study_claims cl on cl.id = ic.claim_id
                      where ic.item_id = e.item_id and cl.status <> 'validated');
  end if;

  -- The reader's own judgement or version, or a key they have disputed: never evidence to
  -- schedule by, but "not had" is still word that they do not remember it now. A claim
  -- tested only by short answers -- which a wrong typed answer can only reach self-graded --
  -- could otherwise never be un-known.
  if not scores then
    for c in select ic.claim_id from public.study_item_claims ic where ic.item_id = e.item_id loop
      insert into public.study_claim_memory as t (owner_id, claim_id, last_outcome, last_answered_at)
      values (e.owner_id, c, 'lapse', e.answered_at)
      on conflict (owner_id, claim_id) do update
        set last_outcome = 'lapse', last_answered_at = excluded.last_answered_at;
    end loop;
    return;
  end if;

  for c in select ic.claim_id from public.study_item_claims ic where ic.item_id = e.item_id loop
    select * into m from public.study_claim_memory
    where owner_id = e.owner_id and claim_id = c
    for update;
    if not found then
      m.stability := 1.0;
      m.difficulty := 0.3;
      m.reps := 0;
      m.lapses := 0;
      m.last_outcome := null;
      m.last_success_id := null;
      m.last_success_at := null;
    end if;

    if proves then
      if m.last_success_at is null
         or (m.last_outcome = 'success'
             and e.answered_at >= m.last_success_at + make_interval(secs => m.stability * 86400)) then
        m.stability := least(730.0, m.stability * (2.0 + (1.0 - m.difficulty)));
      end if;
      m.last_outcome := 'success';
      m.last_success_id := e.id;
      m.last_success_at := e.answered_at;
    else
      m.stability := greatest(0.5, m.stability * 0.35);
      m.difficulty := least(1.0, m.difficulty + 0.15);
      m.lapses := m.lapses + 1;
      m.last_outcome := 'lapse';
    end if;
    m.reps := m.reps + 1;

    insert into public.study_claim_memory as t
      (owner_id, claim_id, stability, difficulty, reps, lapses, last_outcome,
       last_success_id, last_success_at, last_answered_at)
    values
      (e.owner_id, c, m.stability, m.difficulty, m.reps, m.lapses, m.last_outcome,
       m.last_success_id, m.last_success_at, e.answered_at)
    on conflict (owner_id, claim_id) do update
      set stability = excluded.stability, difficulty = excluded.difficulty,
          reps = excluded.reps, lapses = excluded.lapses,
          last_outcome = excluded.last_outcome, last_success_id = excluded.last_success_id,
          last_success_at = excluded.last_success_at, last_answered_at = excluded.last_answered_at;
  end loop;
end
$fn$;

/* As 20260925210000, with a lapse a question the project corrected can clear. */
create or replace function public.study_claim_knowledge(p_course_id uuid, p_at timestamptz default null)
returns table (
  claim_id       uuid,
  known          boolean,
  retrievability double precision,
  due_at         timestamptz,
  lapsed         boolean,
  lapsed_at      timestamptz
)
language sql
stable
set search_path = ''
as $fn$
  with at as (select coalesce(p_at, now()) as t)
  select c.id,
         coalesce(m.last_outcome = 'success'
                  and r.recall > public.known_retrievability_floor()
                  and public.study_answer_proves_recall(m.last_success_id), false),
         r.recall,
         case when m.last_outcome = 'lapse' then m.last_answered_at + interval '30 minutes'
              when m.last_success_at is not null
              then m.last_success_at + make_interval(secs => m.stability * 86400) end,
         lapse.held,
         case when lapse.held then m.last_answered_at end
  from public.study_claims c
  cross join at
  left join public.study_claim_memory m on m.claim_id = c.id and m.owner_id = c.owner_id
  -- Recall at the moment asked about, once: null before a success, or after it when asked
  -- about the past.
  cross join lateral (
    select case when m.last_success_at is not null
                     and (p_at is null or m.last_success_at <= p_at)
                then public.retrievability(
                       m.stability::real, m.last_success_at,
                       least(at.t,
                             m.last_success_at + make_interval(secs => m.stability * 86400 * 1000)))
           end as recall
  ) as r
  cross join lateral (
    select coalesce(m.last_outcome = 'lapse', false)
           and exists (select 1 from public.study_item_claims ic
                       join public.study_items i on i.id = ic.item_id
                       where ic.claim_id = c.id and i.status = 'validated'
                         and i.authored_by in ('model', 'project')) as held
  ) as lapse
  where c.generation_id = (select public.study_course_generation(p_course_id))
    and c.status = 'validated'
$fn$;

/* As 20260925210000, with a question the project corrected demonstrated and due as the model's. */
create or replace function public.study_course_questions(p_course_id uuid)
returns table (
  generation_id    uuid,
  item_id          uuid,
  lesson_id        uuid,
  item_key         text,
  purpose          text,
  kind             text,
  difficulty       smallint,
  authored_by      text,
  state            text,
  first_shown_at   timestamptz,
  last_answered_at timestamptz,
  demonstrated_at  timestamptz,
  due_at           timestamptz,
  due              boolean
)
language sql
stable
set search_path = ''
as $fn$
  with items as (
    -- Validated now, by construction; and whether every claim under it is validated now.
    select i.*,
           not exists (select 1 from public.study_item_claims ic
                       join public.study_claims c on c.id = ic.claim_id
                       where ic.item_id = i.id and c.status <> 'validated') as claims_validated
    from public.study_items i
    where i.generation_id = (select public.study_course_generation(p_course_id))
      and i.status = 'validated'
  ),
  shown as (
    select i.id as item_id, min(e.occurred_at) as shown_at
    from items i
    join public.study_items v on v.lineage_id = i.lineage_id
    join public.study_progress_events e on e.item_id = v.id and e.kind = 'item_shown'
    group by i.id
  ),
  answered as (
    select a.item_id, max(a.answered_at) as last_answered_at
    from public.study_answer_events a
    where a.item_id in (select items.id from items)
    group by a.item_id
  ),
  -- The proof rule, set-based: a correct, unhinted, deterministically graded answer to a
  -- question the model wrote or the project corrected, validated when answered, validated
  -- now, on validated claims.
  demonstrated as (
    select a.item_id, min(a.answered_at) as demonstrated_at
    from items i
    join public.study_answer_events a on a.item_id = i.id
    cross join lateral (
      select l.to_status
      from public.study_status_log l
      where l.item_id = a.item_id and l.at <= a.answered_at
      order by l.at desc, l.id desc
      limit 1
    ) as then_status
    where i.authored_by in ('model', 'project')
      and i.claims_validated
      and a.correct
      and not a.hinted
      and a.grading = 'deterministic'
      and then_status.to_status = 'validated'
    group by a.item_id
  ),
  -- Due once answered, when the first of the claims it tests is due: its retrievability has
  -- fallen to 0.9, or the reader's last answer on it was wrong.
  due as (
    select ic.item_id, min(k.due_at) as due_at
    from public.study_item_claims ic
    join public.study_claim_knowledge(p_course_id) k on k.claim_id = ic.claim_id
    where ic.item_id in (select answered.item_id from answered)
      and ic.item_id in (select items.id from items
                         where items.authored_by in ('model', 'project'))
    group by ic.item_id
  )
  select i.generation_id,
         i.id,
         l.id,
         i.item_key,
         i.purpose,
         i.kind,
         i.difficulty,
         i.authored_by,
         case when demonstrated.demonstrated_at is not null then 'recall_demonstrated'
              when answered.last_answered_at is not null then 'answered'
              when shown.shown_at is not null then 'shown'
              else 'not_seen' end,
         shown.shown_at,
         answered.last_answered_at,
         demonstrated.demonstrated_at,
         due.due_at,
         coalesce(due.due_at <= now(), false)
  from items i
  -- Only a lesson the outline shows: a question whose lesson is held back (reported, or
  -- quarantined) reads as course-level until the lesson returns.
  left join public.study_lessons l on l.id = i.lesson_id and l.status = 'validated'
  left join shown on shown.item_id = i.id
  left join answered on answered.item_id = i.id
  left join demonstrated on demonstrated.item_id = i.id
  left join due on due.item_id = i.id
  order by l.unit_no nulls last, l.position nulls last,
           (substr(i.item_key, 2))::int
$fn$;

-- ------------------------------------------------------------------ 9. excerpts are not a source

/*
 * As 20260924010000, recording the replay identity of a version a reader saved -- and not of a
 * public course's excerpts, which enrolling writes and no reader's save ever replays: they do
 * not count against the reader's 1,000 saves.
 */
create or replace function public.record_study_source_mutation()
returns trigger
language plpgsql
security definer
set search_path = ''
as $trigger$
begin
  if new.format = 'public_course' then
    return new;
  end if;
  insert into public.study_source_mutations
    (owner_id, client_mutation_id, version_id, created_at)
  values (new.owner_id, new.client_mutation_id, new.id, new.created_at)
  on conflict (owner_id, client_mutation_id) do nothing;
  return new;
end
$trigger$;

/*
 * As 20260924010000, with a public course's excerpts neither counted against the reader's
 * 100 versions nor a source anything is saved into (55000 `public`): they are the course's,
 * copied in when the reader enrolled.
 */
create or replace function public.save_study_source_version(
  p_title text,
  p_format text,
  p_text text,
  p_mutation_id uuid,
  p_source_id uuid default null,
  p_origin_label text default null,
  p_extraction_notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  uid uuid := auth.uid();
  existing public.study_source_versions%rowtype;
  prior public.study_source_mutations%rowtype;
  parent public.study_sources%rowtype;
  saved public.study_source_versions%rowtype;
  next_no integer;
begin
  if uid is null then
    raise exception 'study import requires a signed-in reader' using errcode = '28000';
  end if;

  -- Serialises same-reader saves, including a lost response retried from another tab.
  perform 1 from auth.users
    where id = uid and is_anonymous is false
    for update;
  if not found then
    raise exception 'study import requires a non-guest reader' using errcode = '28000';
  end if;

  if p_mutation_id is null then
    raise exception 'study import needs a mutation id' using errcode = '22023';
  end if;
  select * into prior from public.study_source_mutations
    where owner_id = uid and client_mutation_id = p_mutation_id;
  if found then
    if prior.version_id is null then
      raise exception 'this study source was deleted; start a new import'
        using errcode = '55000';
    end if;
    select * into existing from public.study_source_versions
      where id = prior.version_id and owner_id = uid;
    if not found then
      raise exception 'the saved study source is unavailable' using errcode = '55000';
    end if;
    return jsonb_build_object(
      'sourceId', existing.source_id,
      'versionId', existing.id,
      'versionNo', existing.version_no,
      'replayed', true
    );
  end if;

  p_title := btrim(p_title);
  p_text := btrim(p_text);
  if p_title is null or char_length(p_title) not between 1 and 200 then
    raise exception 'title must be 1 to 200 characters' using errcode = '22023';
  end if;
  if p_text is null or char_length(p_text) not between 1 and 200000 then
    raise exception 'source text must be 1 to 200000 characters' using errcode = '22023';
  end if;
  if p_format is null or p_format not in
    ('paste', 'text', 'markdown', 'pdf', 'docx', 'image_ocr', 'pdf_ocr', 'highlights') then
    raise exception 'unsupported study source format' using errcode = '22023';
  end if;
  if p_origin_label is not null and char_length(p_origin_label) > 240 then
    raise exception 'origin label is too long' using errcode = '22023';
  end if;
  if p_extraction_notes is not null and char_length(p_extraction_notes) > 2000 then
    raise exception 'extraction notes are too long' using errcode = '22023';
  end if;

  if (select count(*) from public.study_source_mutations where owner_id = uid) >= 1000 then
    raise exception 'this reader has reached the 1000-save study source limit'
      using errcode = '54000';
  end if;

  if (select count(*) from public.study_source_versions
      where owner_id = uid and format <> 'public_course') >= 100 then
    raise exception 'this reader has reached the 100-version study source limit'
      using errcode = '54000';
  end if;

  if p_source_id is null then
    insert into public.study_sources (owner_id) values (uid) returning * into parent;
  else
    select * into parent from public.study_sources
      where id = p_source_id and owner_id = uid for update;
    if not found then
      raise exception 'study source is unavailable' using errcode = '42501';
    end if;
    if exists (select 1 from public.study_source_versions v
               where v.source_id = parent.id and v.format = 'public_course') then
      raise exception 'a public course''s excerpts are the course''s; save your own text as a new source'
        using errcode = '55000', detail = 'public';
    end if;
  end if;

  next_no := parent.latest_version_no + 1;
  insert into public.study_source_versions
    (source_id, owner_id, version_no, client_mutation_id, title, format,
     origin_label, extracted_text, extraction_notes)
  values
    (parent.id, uid, next_no, p_mutation_id, p_title, p_format,
     p_origin_label, p_text, p_extraction_notes)
  returning * into saved;
  -- The AFTER INSERT trigger records the replay identity atomically, including
  -- saves still running under the previous function body.
  update public.study_sources set latest_version_no = next_no where id = parent.id;

  return jsonb_build_object(
    'sourceId', parent.id,
    'versionId', saved.id,
    'versionNo', saved.version_no,
    'replayed', false
  );
end
$fn$;

-- ------------------------------------------------------------------ 10. preparing again

/*
 * As 20260925220000, refusing to prepare a public course's copy again, or anything from a
 * public course's excerpts (55000 `public`).
 */
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
  waiting    numeric;
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
  -- A public course's copy is the project's course, not the reader's material, and the
  -- excerpts it carries are not a source to prepare anything from. Said before anything else
  -- about the reader, which would suggest something they could change: a copy is never
  -- prepared again, in the beta or out of it. Read without a lock, as it never changes.
  if p_course_id is not null
     and exists (select 1 from public.study_courses c
                 where c.id = p_course_id and c.owner_id = uid
                   and c.public_course_id is not null) then
    raise exception 'a public course is not prepared again'
      using errcode = '55000', detail = 'public';
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

  -- A public course's excerpts are the course's, not the reader's material: nothing is
  -- prepared from them, which would be a model call over the project's quotations.
  if exists (select 1 from public.study_source_versions v
             where v.id = any (v_versions) and v.owner_id = uid
               and v.format = 'public_course') then
    raise exception 'a public course''s excerpts are not a source to prepare a course from'
      using errcode = '55000', detail = 'public';
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
  -- The study ceiling counts, besides what is charged and held, every course already admitted
  -- that today's study spend does not see yet -- queued or running, with nothing it cost
  -- charged today and nothing held for it -- at the least a course reserves. Counting spend
  -- alone, eight readers at an empty day were all admitted, and the five it could not fund
  -- waited out the worker's day of budget waits and then failed.
  --
  -- Two limits keep the count to what can actually be spent. An attempt ledgered at nothing,
  -- a provider's 429 or a refused connection, is not a start: counted as one, a backlog after
  -- an outage left the count and let the door past the ceiling. And one reader's waiting
  -- courses count together for no more than what is left of their share of study spend,
  -- which is all they can spend today whatever the ceiling holds: counted in full, one
  -- reader's queue closed the door to everyone. Their courses past it are still admitted --
  -- the reader's own check above reads their spend, not their queue -- and wait on the share.
  --
  -- Under the reader's lock, not the budget's: two readers at the door at once are each
  -- counted without the other, and the reservation, under one lock for the whole budget, is
  -- what holds the ceiling exactly.
  select coalesce(sum(least(w.courses * public.study_min_job_cents(),
                            greatest(public.study_requester_daily_cap_cents()
                                     - public.study_requester_spend_today(w.requester_id), 0))),
                  0)
    into waiting
  from (
    select j.requester_id, count(*) as courses
    from public.generation_jobs j
    where j.kind = 'study_course' and j.status in ('queued', 'running')
      and not exists (
        select 1 from public.cost_ledger cl
        where cl.job_id = j.id and cl.cost_cents > 0
          and cl.created_at >= date_trunc('day', (now() at time zone 'utc')) at time zone 'utc')
      and not exists (
        select 1 from public.budget_reservations br
        where br.job_id = j.id and br.settled_at is null
          and br.created_at >= now() - public.budget_reservation_ttl()
          and br.created_at >= date_trunc('day', (now() at time zone 'utc')) at time zone 'utc')
    group by j.requester_id
  ) as w;
  if public.study_spend_today() + waiting + public.study_min_job_cents()
     > public.study_daily_cap_cents() then
    raise exception 'today''s study generation budget is spent. Study generation resumes at 00:00 UTC.'
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

-- ------------------------------------------------------------------ the beta's views

/*
 * The beta's dashboards (20260925220000) measure courses readers prepared from their own
 * material. A public course's copy is none of that: it is the project's course, added by
 * enrolment, and its generation, claims, lessons and questions arrive with the snapshot --
 * counted, one enrolment would read as a course prepared, a generation validated, questions
 * passed. So each view leaves a copy out, and a reader's answers, reading, reports and
 * corrections in one: they are about the project's course, not about what the pipeline
 * prepared. The status view needs nothing: it counts only a generation with an
 * `assembly_provenance`, and enrolling -- which stamps `assembled_at` but asks no model --
 * writes none, so a copy has no provenance to be off the gate by.
 */

create or replace view ops.study_beta_mix as
with courses as (
  select c.id, c.owner_id, c.goal, public.study_course_generation(c.id) as generation_id
  from public.study_courses c
  where c.public_course_id is null
)
select 'format'::text as dimension,
       public.study_format_family(v.format) as value,
       count(distinct cs.id)::int as courses,
       count(distinct cs.owner_id)::int as readers
from courses cs
join public.study_generation_sources gs on gs.generation_id = cs.generation_id
join public.study_source_versions v on v.id = gs.source_version_id
group by 1, 2
union all
select 'goal', public.study_goal_kind(cs.goal), count(*)::int, count(distinct cs.owner_id)::int
from courses cs
where cs.generation_id is not null
group by 1, 2;

create or replace view ops.study_daily as
with jobs as (
  select j.id, j.status, j.created_at, j.finished_at
  from public.generation_jobs j
  where j.kind = 'study_course'
),
spend as (
  select (l.created_at at time zone 'UTC')::date as day, sum(l.cost_cents) as cents
  from public.cost_ledger l
  join jobs j on j.id = l.job_id
  group by 1
),
per_day as (
  select (j.created_at at time zone 'UTC')::date as day,
         count(*)::int as jobs,
         count(*) filter (where j.status = 'succeeded')::int as succeeded,
         count(*) filter (where j.status = 'failed')::int as failed,
         count(*) filter (where j.status = 'cancelled')::int as cancelled,
         count(*) filter (where j.status in ('queued', 'running'))::int as in_flight,
         percentile_cont(0.5) within group (
           order by extract(epoch from j.finished_at - j.created_at) / 60)
           filter (where j.status = 'succeeded') as median_minutes,
         percentile_cont(0.95) within group (
           order by extract(epoch from j.finished_at - j.created_at) / 60)
           filter (where j.status = 'succeeded') as p95_minutes
  from jobs j
  group by 1
),
courses as (
  select (c.created_at at time zone 'UTC')::date as day, count(*)::int as courses,
         count(distinct c.owner_id)::int as readers
  from public.study_courses c
  where c.public_course_id is null
  group by 1
)
select coalesce(p.day, c.day, s.day) as day,
       coalesce(c.courses, 0) as courses_created,
       coalesce(c.readers, 0) as readers_creating,
       coalesce(p.jobs, 0) as jobs,
       coalesce(p.succeeded, 0) as succeeded,
       coalesce(p.failed, 0) as failed,
       coalesce(p.cancelled, 0) as cancelled,
       coalesce(p.in_flight, 0) as in_flight,
       p.median_minutes,
       p.p95_minutes,
       coalesce(s.cents, 0) as spend_cents
from per_day p
full join courses c on c.day = p.day
full join spend s on s.day = coalesce(p.day, c.day);

create or replace view ops.study_validation_weekly as
with gens as (
  select g.id, date_trunc('week', g.created_at at time zone 'UTC')::date as week, g.text_status
  from public.study_generations g
  where g.public_course_id is null
)
select gens.week,
       count(*)::int as generations,
       count(*) filter (where gens.text_status = 'pending')::int as awaiting_validation,
       count(*) filter (where public.study_generation_rank(gens.id) = 0
                          and gens.text_status <> 'pending')::int as held_back,
       (select count(*) from public.study_claims c join gens g2 on g2.id = c.generation_id
        where g2.week = gens.week and c.status = 'validated')::int as claims_validated,
       (select count(*) from public.study_claims c join gens g2 on g2.id = c.generation_id
        where g2.week = gens.week and c.status = 'quarantined')::int as claims_quarantined,
       (select count(*) from public.study_lessons l join gens g2 on g2.id = l.generation_id
        where g2.week = gens.week and l.authored_by = 'model'
          and l.status = 'validated')::int as lessons_validated,
       (select count(*) from public.study_lessons l join gens g2 on g2.id = l.generation_id
        where g2.week = gens.week and l.authored_by = 'model'
          and l.status = 'quarantined')::int as lessons_quarantined,
       (select count(*) from public.study_items i join gens g2 on g2.id = i.generation_id
        where g2.week = gens.week and i.authored_by = 'model'
          and i.status = 'validated')::int as questions_validated,
       (select count(*) from public.study_items i join gens g2 on g2.id = i.generation_id
        where g2.week = gens.week and i.authored_by = 'model'
          and i.status = 'quarantined')::int as questions_quarantined
from gens
group by gens.week;

create or replace view ops.study_learning_weekly as
with every_answer as (
  -- Every answer to the question, in any of its versions and however graded, before the
  -- measure is filtered: a self-graded "not had" or a wrong answer to the reader's own
  -- version between two right ones is the last answer before the second.
  select e.owner_id,
         e.answered_at,
         e.correct,
         e.hinted,
         e.claims_known_before,
         e.grading = 'deterministic' and i.authored_by = 'model' as counted,
         lag(e.answered_at) over w as previous_at,
         lag(e.correct and not e.hinted and e.grading = 'deterministic') over w as previous_clean
  from public.study_answer_events e
  join public.study_items i on i.id = e.item_id and i.owner_id = e.owner_id
  join public.study_generations g on g.id = i.generation_id and g.public_course_id is null
  window w as (partition by e.owner_id, i.lineage_id order by e.answered_at, e.id)
),
answers as (
  select * from every_answer where counted
)
select date_trunc('week', a.answered_at at time zone 'UTC')::date as week,
       count(*)::int as answers,
       count(distinct a.owner_id)::int as readers,
       count(*) filter (where a.correct and not a.hinted)::int as right_unhinted,
       count(*) filter (where a.previous_clean
                          and a.answered_at - a.previous_at >= interval '7 days')::int
         as delayed_attempts,
       count(*) filter (where a.previous_clean
                          and a.answered_at - a.previous_at >= interval '7 days'
                          and a.correct and not a.hinted)::int
         as delayed_recalled,
       -- Unhinted only: a hinted answer is not a test of what the reader knew.
       count(*) filter (where a.claims_known_before and not a.hinted)::int as answers_when_known,
       count(*) filter (where a.claims_known_before and not a.hinted and not a.correct)::int
         as wrong_when_known
from answers a
group by 1;

create or replace view ops.study_trust_weekly as
with shown as (
  select date_trunc('week', p.recorded_at at time zone 'UTC')::date as week,
         count(*) filter (where p.kind = 'lesson_shown')::int as lessons_shown,
         count(*) filter (where p.kind = 'lesson_read')::int as lessons_read,
         count(*) filter (where p.kind = 'lesson_skipped')::int as lessons_skipped,
         count(*) filter (where p.kind = 'item_shown')::int as questions_shown
  from public.study_progress_events p
  where not exists (select 1 from public.study_generations g
                    where g.id = p.generation_id and g.public_course_id is not null)
  group by 1
),
reports as (
  select date_trunc('week', r.created_at at time zone 'UTC')::date as week,
         count(*)::int as reports,
         count(*) filter (where r.lesson_id is not null)::int as lesson_reports,
         count(*) filter (where r.claim_id is not null)::int as claim_reports,
         count(*) filter (where r.item_id is not null)::int as question_reports,
         count(*) filter (where r.status = 'dismissed')::int as reports_restored
  from public.study_reports r
  where not exists (select 1 from public.study_generations g
                    where g.id = r.generation_id and g.public_course_id is not null)
  group by 1
),
withdrawals as (
  -- The lesson, claim or question withdrawn; what rests on a withdrawn claim is logged as
  -- `claim_retired` and not counted again.
  select date_trunc('week', s.at at time zone 'UTC')::date as week, count(*)::int as withdrawn
  from public.study_status_log s
  where s.reason = 'retired'
    and not exists (
      select 1 from public.study_generations g
      where g.public_course_id is not null
        and g.id = coalesce(
              (select c.generation_id from public.study_claims c where c.id = s.claim_id),
              (select l.generation_id from public.study_lessons l where l.id = s.lesson_id),
              (select i.generation_id from public.study_items i where i.id = s.item_id)))
  group by 1
),
corrections as (
  select date_trunc('week', x.created_at at time zone 'UTC')::date as week,
         count(*)::int as corrected
  from (select l.created_at, l.generation_id from public.study_lessons l
        where l.authored_by = 'reader'
        union all
        select i.created_at, i.generation_id from public.study_items i
        where i.authored_by = 'reader') as x
  where not exists (select 1 from public.study_generations g
                    where g.id = x.generation_id and g.public_course_id is not null)
  group by 1
),
changes as (
  select coalesce(w.week, c.week) as week,
         coalesce(w.withdrawn, 0) as withdrawn,
         coalesce(c.corrected, 0) as corrected
  from withdrawals w
  full join corrections c on c.week = w.week
)
select coalesce(sh.week, r.week, ch.week) as week,
       coalesce(sh.lessons_shown, 0) as lessons_shown,
       coalesce(sh.lessons_read, 0) as lessons_read,
       coalesce(sh.lessons_skipped, 0) as lessons_skipped,
       coalesce(sh.questions_shown, 0) as questions_shown,
       coalesce(r.reports, 0) as reports,
       coalesce(r.lesson_reports, 0) as lesson_reports,
       coalesce(r.claim_reports, 0) as claim_reports,
       coalesce(r.question_reports, 0) as question_reports,
       coalesce(r.reports_restored, 0) as reports_restored,
       coalesce(ch.withdrawn, 0) as withdrawn,
       coalesce(ch.corrected, 0) as corrected
from shown sh
full join reports r on r.week = sh.week
full join changes ch on ch.week = coalesce(sh.week, r.week);
