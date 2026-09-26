-- Study courses: the broad beta.
--
-- Study courses have been open only to readers on an allowlist (`study_generation_access`,
-- 20260925010000). Opening them to every reader with an account is a decision about quality
-- as much as reach, and `docs/eval/study-quality.md` states the bar: a human-reviewed
-- release fixture of at least 24 source versions and 300 visible questions, no material
-- error in a visible answer key, at most 3% ambiguous questions, no adversarial item
-- reaching a learner, every fixture category covered, and a ledger entry for every
-- provider attempt. This migration makes that bar a property of the schema rather than of
-- a checklist:
--
-- 1. RELEASE GATES. `study_release_gates` records what the evaluator
--    (`scripts/study-eval.mjs`) reported for a reviewed fixture run, with the digest of the
--    run export kept outside the repository, the pipeline the run used (prompt, schema and
--    model, for extraction and for assembly) and when it ran. Whether it passed is computed
--    here from the report's gates AND its counts, never supplied: a report whose gates say
--    ready while its counts say otherwise does not pass. Rows are final, and a run's report
--    is recorded once. What the schema checks is the report; that a person reviewed the run
--    is the operator's word, recorded with their name.
--
-- 2. ONE FLAG, WHICH OPENS ONLY ON A GATE. `study_beta_settings` is a single row. It can be
--    set open only with a gate whose run passed in the last thirty days -- checked by a
--    trigger -- and `open_study_beta` also asks that the allowlisted beta so far covered
--    every kind of source and goal, or that the operator says why not. Every change is
--    logged in `study_beta_log`, which is append-only. Only the database owner writes any
--    of the three or calls open and close: not the service role, whose key every Edge
--    Function holds. An open beta admits no one once its gate's run is sixty days old.
--    Closing is always allowed; courses already queued finish, within their readers'
--    shares and the study ceiling.
--
-- 3. ADMISSION IN ONE PLACE. `study_generation_admitted` is the allowlist or the open flag,
--    and both doors -- `study_enqueue_course` and `study_generation_available` -- now ask
--    it. What bounds a day, open or not (CLAUDE.md, law 2): consent, size, the global daily
--    cap, each reader's share of study spend, the per-reader job counts -- and, new here, a
--    ceiling on study spend for all readers together (`study_daily_cap_cents()`, half the
--    day), so opening the beta cannot leave the catalogue's generation with nothing.
--
-- 4. INSTRUMENTATION. An answer now records whether the study Delta counted every claim it
--    tests as known just before it was given (`claims_known_before`), so false mastery --
--    a claim the course would have skipped, answered wrong -- is measured rather than
--    guessed. `study_claim_known` is 20260925210000's rule for one claim, held to
--    `study_claim_knowledge` by the suite.
--
-- 5. OPERATORS' DASHBOARDS. Schema `ops`, not exposed through the API, readable by the
--    service role: aggregate views of preparation, validation, cost, learning, trust and the
--    beta's mix. No row in them names a reader. `scripts/study-beta-report.mjs` prints them.
--    See docs/study-beta.md.

-- ------------------------------------------------------------------ 1. release gates

/*
 * Whether an evaluator report clears the broad-beta bar. Every gate must be true, and the
 * counts behind the gates are read again, each a whole number not below zero: at least 24
 * sources with visible questions and 300 visible questions, every visible question reviewed
 * twice and found grounded and answerable, no material error, adversarial items present
 * and every one reviewed twice with none leaked, at most 3% ambiguous, no fixture category
 * missing, and one pipeline for the whole run: the prompt, schema and model that extracted
 * its claims, and those that assembled its courses. A prompt edit in either stage is a new
 * pipeline, which a gate for the old one does not cover.
 */
create function public.study_gate_passes(p_report jsonb)
returns boolean
language plpgsql
immutable
set search_path = ''
as $fn$
declare
  gate    text;
  count_  text;
  stage   text;
  counts  jsonb;
  visible numeric;
begin
  if jsonb_typeof(p_report) is distinct from 'object' then
    return false;
  end if;
  foreach gate in array array['ready', 'minimumFixture', 'fixtureCoverage', 'answersSupported',
                               'ambiguity', 'adversarial', 'ledgerComplete',
                               'singlePipeline'] loop
    if (p_report -> 'gates' -> gate) is distinct from 'true'::jsonb then
      return false;
    end if;
  end loop;
  counts := p_report -> 'counts';
  foreach count_ in array array['visibleSources', 'visibleItems', 'doubleReviewedVisible',
                                 'groundedVisible', 'answerableVisible', 'materialErrors',
                                 'ambiguousVisible', 'adversarialItems', 'adversarialLeaks',
                                 'doubleReviewedAdversarial'] loop
    if jsonb_typeof(counts -> count_) is distinct from 'number'
       or (counts ->> count_)::numeric < 0
       or (counts ->> count_)::numeric <> trunc((counts ->> count_)::numeric) then
      return false;
    end if;
  end loop;
  foreach stage in array array['extract', 'assemble'] loop
    if jsonb_typeof(p_report -> 'pipeline' -> stage) is distinct from 'object'
       or coalesce(p_report -> 'pipeline' -> stage ->> 'promptHash', '') !~ '^[0-9a-f]{64}$'
       or coalesce(p_report -> 'pipeline' -> stage ->> 'schemaHash', '') !~ '^[0-9a-f]{64}$'
       or coalesce(char_length(p_report -> 'pipeline' -> stage ->> 'model'), 0)
          not between 1 and 100 then
      return false;
    end if;
  end loop;
  if jsonb_typeof(p_report -> 'coverage' -> 'missing') is distinct from 'array' then
    return false;
  end if;
  visible := (counts ->> 'visibleItems')::numeric;
  return (counts ->> 'visibleSources')::numeric >= 24
     and visible >= 300
     and (counts ->> 'doubleReviewedVisible')::numeric = visible
     and (counts ->> 'groundedVisible')::numeric = visible
     and (counts ->> 'answerableVisible')::numeric = visible
     and (counts ->> 'adversarialItems')::numeric > 0
     and (counts ->> 'doubleReviewedAdversarial')::numeric = (counts ->> 'adversarialItems')::numeric
     and (counts ->> 'materialErrors')::numeric = 0
     and (counts ->> 'adversarialLeaks')::numeric = 0
     and (counts ->> 'ambiguousVisible')::numeric <= 0.03 * visible
     and jsonb_array_length(p_report -> 'coverage' -> 'missing') = 0;
end
$fn$;

revoke all on function public.study_gate_passes(jsonb) from public, anon, authenticated;

create table public.study_release_gates (
  id             uuid primary key default extensions.gen_random_uuid(),
  recorded_at    timestamptz not null default now(),
  -- Who ran and adjudicated the review: an operator's name, not an account.
  recorded_by    text not null check (char_length(btrim(recorded_by)) between 1 and 200),
  -- The sha256 of the run export the report came from. The export, and the reviewed
  -- material in it, stay outside the public repository (docs/eval/study-quality.md).
  fixture_digest text not null check (fixture_digest ~ '^[0-9a-f]{64}$'),
  report         jsonb not null
                 check (jsonb_typeof(report) = 'object' and pg_column_size(report) <= 65536),
  -- When the reviewed run was made, and with what, from the report: a gate is as fresh as
  -- its run, not as its recording, and says what it is a gate for.
  ran_at         timestamptz not null,
  pipeline       jsonb not null check (jsonb_typeof(pipeline) = 'object'),
  passed         boolean not null,
  note           text check (note is null or char_length(note) <= 1000)
);

-- A report of a run is recorded once. Recording it again could not restart its clock --
-- `ran_at` is the run's, read from the report -- but would say twice what was said once. The
-- same run evaluated again, after a fix to the evaluator, is a new report and is recorded
-- beside the first; jsonb's text is canonical, so the same report hashes the same.
create unique index study_release_gates_one_per_report
  on public.study_release_gates (fixture_digest, md5(report::text));

comment on table public.study_release_gates is
  'What the study evaluator reported for a human-reviewed fixture run. `passed` is computed '
  'from the report on insert (study_gate_passes), never supplied, and `ran_at` and '
  '`pipeline` are read from it. Final once written. Written by the database owner only. '
  'See 20260925220000 and docs/study-beta.md.';

alter table public.study_release_gates enable row level security;
create policy study_release_gates_no_api_access on public.study_release_gates
  for select using (false);
revoke all on public.study_release_gates from public, anon, authenticated;

create function public.study_release_gate_recorded()
returns trigger
language plpgsql
set search_path = ''
as $fn$
begin
  if tg_op <> 'INSERT' then
    raise exception 'a release gate is final once recorded' using errcode = '55000';
  end if;
  -- A UTC time as the export writes it, and nothing else Postgres would read as one: not
  -- 'now', 'today' or 'epoch', not an infinity, not a time without its zone.
  new.ran_at := null;
  if jsonb_typeof(new.report -> 'ranAt') = 'string'
     and new.report ->> 'ranAt' ~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,6})?Z$' then
    begin
      new.ran_at := (new.report ->> 'ranAt')::timestamptz;
    exception when others then
      new.ran_at := null;
    end;
  end if;
  if new.ran_at is null or new.ran_at > now() + interval '5 minutes' then
    raise exception 'a release gate needs the time its run was made (ranAt), not in the future'
      using errcode = '22023';
  end if;
  new.pipeline := coalesce(new.report -> 'pipeline', '{}'::jsonb);
  if jsonb_typeof(new.pipeline) is distinct from 'object' then
    new.pipeline := '{}'::jsonb;
  end if;
  new.passed := public.study_gate_passes(new.report);
  new.recorded_at := now();
  new.recorded_by := btrim(new.recorded_by);
  return new;
end
$fn$;

revoke all on function public.study_release_gate_recorded() from public, anon, authenticated;

create trigger study_release_gates_recorded
  before insert or update or delete on public.study_release_gates
  for each row execute function public.study_release_gate_recorded();

/* TRUNCATE passes by every row trigger; the three tables of the switch refuse it. */
create function public.study_beta_not_truncated()
returns trigger
language plpgsql
set search_path = ''
as $fn$
begin
  raise exception '% is not truncated: it is the record of the beta', tg_table_name
    using errcode = '55000';
end
$fn$;

revoke all on function public.study_beta_not_truncated() from public, anon, authenticated;

create trigger study_release_gates_not_truncated
  before truncate on public.study_release_gates
  for each statement execute function public.study_beta_not_truncated();

-- ------------------------------------------------------------------ 2. the flag

create table public.study_beta_settings (
  id          boolean primary key default true check (id),
  open_to_all boolean not null default false,
  gate_id     uuid references public.study_release_gates (id),
  changed_at  timestamptz not null default now(),
  changed_by  text check (changed_by is null or char_length(changed_by) <= 200),
  constraint study_beta_settings_open_needs_gate check (not open_to_all or gate_id is not null)
);

create index study_beta_settings_gate_idx on public.study_beta_settings (gate_id);

comment on table public.study_beta_settings is
  'The one row saying whether study courses are open to every reader with an account, and '
  'on which release gate. Opens only on a gate whose run passed in the last thirty days. '
  'Written by the database owner only; readers learn the answer through '
  'study_generation_available(). See 20260925220000.';

insert into public.study_beta_settings (id) values (true);

alter table public.study_beta_settings enable row level security;
create policy study_beta_settings_no_api_access on public.study_beta_settings
  for select using (false);
revoke all on public.study_beta_settings from public, anon, authenticated;

create table public.study_beta_log (
  id              bigint generated always as identity primary key,
  at              timestamptz not null default now(),
  open_to_all     boolean not null,
  gate_id         uuid references public.study_release_gates (id),
  changed_by      text check (changed_by is null or char_length(changed_by) <= 200),
  -- Why the beta opened although its mix so far did not cover every kind of source and goal.
  override_reason text check (override_reason is null or char_length(override_reason) <= 1000),
  -- The database role that made the change, whatever name it gave.
  db_user         text not null default session_user
);

create index study_beta_log_gate_idx on public.study_beta_log (gate_id);

comment on table public.study_beta_log is
  'Every change to study_beta_settings, written by its trigger. Append-only; written by the '
  'database owner only.';

alter table public.study_beta_log enable row level security;
create policy study_beta_log_no_api_access on public.study_beta_log for select using (false);
revoke all on public.study_beta_log from public, anon, authenticated;

create function public.study_beta_settings_guard()
returns trigger
language plpgsql
set search_path = ''
as $fn$
begin
  if tg_op <> 'UPDATE' then
    raise exception 'study_beta_settings is one row, changed in place' using errcode = '55000';
  end if;
  -- Opening, or moving an open beta to another gate: the gate must have passed, recently.
  if new.open_to_all
     and not (old.open_to_all and new.gate_id is not distinct from old.gate_id)
     and not exists (select 1 from public.study_release_gates g
                     where g.id = new.gate_id and g.passed
                       and g.ran_at > now() - interval '30 days') then
    raise exception 'the beta opens only on a release gate whose run passed in the last thirty days'
      using errcode = '55000', detail = 'gate';
  end if;
  new.changed_at := now();
  return new;
end
$fn$;

revoke all on function public.study_beta_settings_guard() from public, anon, authenticated;

create trigger study_beta_settings_guard
  before insert or update or delete on public.study_beta_settings
  for each row execute function public.study_beta_settings_guard();

create trigger study_beta_settings_not_truncated
  before truncate on public.study_beta_settings
  for each statement execute function public.study_beta_not_truncated();

create function public.study_beta_settings_logged()
returns trigger
language plpgsql
set search_path = ''
as $fn$
begin
  insert into public.study_beta_log (open_to_all, gate_id, changed_by, override_reason)
  values (new.open_to_all, new.gate_id, new.changed_by,
          nullif(current_setting('study.beta_override', true), ''));
  return null;
end
$fn$;

revoke all on function public.study_beta_settings_logged() from public, anon, authenticated;

create trigger study_beta_settings_logged
  after update on public.study_beta_settings
  for each row execute function public.study_beta_settings_logged();

/* The log is the record of every change: appended to, never changed or removed. */
create function public.study_beta_log_appended()
returns trigger
language plpgsql
set search_path = ''
as $fn$
begin
  raise exception 'the beta''s log is appended to, never changed' using errcode = '55000';
end
$fn$;

revoke all on function public.study_beta_log_appended() from public, anon, authenticated;

create trigger study_beta_log_appended
  before update or delete on public.study_beta_log
  for each row execute function public.study_beta_log_appended();

create trigger study_beta_log_not_truncated
  before truncate on public.study_beta_log
  for each statement execute function public.study_beta_not_truncated();

-- The owner writes these three, from the SQL editor or psql, and calls open and close. The
-- service role's key is in every Edge Function's environment, and Supabase's default
-- privileges had given it every write on them: a key taken from a function could have
-- minted a gate, opened the beta, or rewritten the log. It keeps reading them.
revoke all on public.study_release_gates, public.study_beta_settings, public.study_beta_log
  from service_role;
grant select on public.study_release_gates, public.study_beta_settings, public.study_beta_log
  to service_role;

-- ------------------------------------------------------------------ 3. admission

/*
 * Whether a reader may prepare a course: on the allowlist, or the beta is open -- on a gate
 * whose run is less than sixty days old. A pipeline two months past its review is not the
 * one that was reviewed; an open beta lapses rather than staying open on it for ever.
 */
create function public.study_generation_admitted(p_user uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $fn$
  select exists (select 1 from public.study_generation_access a where a.user_id = p_user)
      or exists (select 1 from public.study_beta_settings s
                 join public.study_release_gates g on g.id = s.gate_id
                 where s.id and s.open_to_all and g.ran_at > now() - interval '60 days')
$fn$;

revoke all on function public.study_generation_admitted(uuid) from public, anon, authenticated;

/*
 * The day's ceiling on study spend, every reader's together: half the global cap. Each
 * reader's share bounds one reader; with the beta open, four could spend the whole day and
 * leave the catalogue's generation none of it. A narrower bound than law 2's, named there.
 */
create function public.study_daily_cap_cents()
returns numeric
language sql
immutable
set search_path = ''
as $fn$
  select 100::numeric
$fn$;

/* Study spend today, every reader's: charged, and held in open reservations, as the cap counts. */
create function public.study_spend_today()
returns numeric
language sql
stable
security definer
set search_path = ''
as $fn$
  select coalesce(
           (select sum(cl.cost_cents)
              from public.cost_ledger cl
              join public.generation_jobs j on j.id = cl.job_id
             where j.kind = 'study_course'
               and cl.created_at >= date_trunc('day', (now() at time zone 'utc')) at time zone 'utc'),
           0)
       + coalesce(
           (select sum(br.reserved_cents)
              from public.budget_reservations br
              join public.generation_jobs j on j.id = br.job_id
             where j.kind = 'study_course'
               and br.settled_at is null
               and br.created_at >= now() - public.budget_reservation_ttl()
               and br.created_at >= date_trunc('day', (now() at time zone 'utc')) at time zone 'utc'),
           0);
$fn$;

revoke all on function public.study_daily_cap_cents() from public, anon;
revoke all on function public.study_spend_today() from public, anon, authenticated;
grant execute on function public.study_spend_today() to service_role;

/* As 20260925010000, admitting through study_generation_admitted. */
create or replace function public.study_generation_available()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from auth.users u
    where u.id = (select auth.uid()) and u.is_anonymous is not true
  ) and public.study_generation_admitted((select auth.uid()));
$$;

/* As 20260925190000, admitting through study_generation_admitted. */
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
  if public.study_spend_today() + public.study_min_job_cents() > public.study_daily_cap_cents() then
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


-- ------------------------------------------------------------------ 4. what the beta covers

/* A source version's format, as the kinds the beta should cover. */
create function public.study_format_family(p_format text)
returns text
language sql
immutable
set search_path = ''
as $fn$
  select case p_format
           when 'paste' then 'typed'
           when 'text' then 'typed'
           when 'markdown' then 'typed'
           when 'pdf' then 'pdf'
           when 'docx' then 'docx'
           when 'image_ocr' then 'scanned'
           when 'pdf_ocr' then 'scanned'
           when 'highlights' then 'highlights'
           else 'other'
         end
$fn$;

/*
 * What a course is for, as the builder offers it (`GOAL_SUGGESTIONS` in
 * apps/web/src/lib/study-course.ts, held to this by study-course.test.ts), or `own` for a
 * goal in the reader's own words.
 */
create function public.study_goal_kind(p_goal text)
returns text
language sql
immutable
set search_path = ''
as $fn$
  select case lower(btrim(p_goal))
           when 'explain the argument' then 'explain'
           when 'prepare for a discussion' then 'discuss'
           when 'remember the key findings' then 'remember'
           when 'prepare for an assessment' then 'assess'
           else 'own'
         end
$fn$;

revoke all on function public.study_format_family(text) from public, anon, authenticated;
revoke all on function public.study_goal_kind(text) from public, anon, authenticated;
grant execute on function public.study_format_family(text) to service_role;
grant execute on function public.study_goal_kind(text) to service_role;

-- ------------------------------------------------------------------ 5. the study ceiling

/* As 20260925040000, with a study job also held to the study ceiling. */
create or replace function public.reserve_budget(p_job_id uuid, p_step text, p_cents numeric)
returns numeric
language plpgsql
security definer
set search_path = ''
as $$
declare
  cap       numeric := public.daily_spend_cap_cents();
  want      numeric := greatest(coalesce(p_cents, 0), 0);
  committed numeric;
  held      numeric;
  job_kind  public.generation_jobs.kind%type;
  requester uuid;
  mine      numeric;
begin
  if p_job_id is null or p_step is null or p_step = '' then
    raise exception 'reserve_budget needs a job and a step' using errcode = '22023';
  end if;

  -- One lock for the whole budget. The constant is arbitrary and only has to be
  -- the same one every caller uses.
  perform pg_advisory_xact_lock(pg_catalog.hashtextextended('what-a-pull:budget', 0));

  -- A study job is also bounded by its reader's share, under the same lock, so two of
  -- one reader's calls cannot both fit in what is left of it.
  select j.kind, j.requester_id into job_kind, requester
  from public.generation_jobs j
  where j.id = p_job_id;
  if job_kind = 'study_course' then
    mine := public.study_requester_spend_today(requester);
    if mine + want > public.study_requester_daily_cap_cents() then
      raise exception
        'this reader''s share of the day''s study budget is spent (% of % cents held or '
        'charged); this step needs % more',
        round(mine, 4), public.study_requester_daily_cap_cents(), round(want, 4)
        using errcode = '53400';
    end if;
    -- And every reader's together, under the same lock (20260925220000).
    if public.study_spend_today() + want > public.study_daily_cap_cents() then
      raise exception
        'the day''s study budget is spent (% of % cents held or charged); this step needs % more',
        round(public.study_spend_today(), 4), public.study_daily_cap_cents(), round(want, 4)
        using errcode = '53400';
    end if;
  end if;

  select coalesce(sum(cl.cost_cents), 0) into committed
  from public.cost_ledger cl
  where cl.created_at >= date_trunc('day', (now() at time zone 'utc')) at time zone 'utc';

  -- Every open hold, including this step's own, inside the TTL and inside today.
  select coalesce(sum(br.reserved_cents), 0) into held
  from public.budget_reservations br
  where br.settled_at is null
    and br.created_at >= now() - public.budget_reservation_ttl()
    and br.created_at >= date_trunc('day', (now() at time zone 'utc')) at time zone 'utc';

  if committed + held + want > cap then
    raise exception
      'the daily generation budget is spent (% of % cents held or charged); this step '
      'needs % more', round(committed + held, 4), cap, round(want, 4)
      using errcode = '53400';
  end if;

  -- Stacked onto an unsettled hold inside the TTL and inside today; anything else is
  -- replaced. Stacking is the safe direction (20260914100000 says why).
  insert into public.budget_reservations (job_id, step, reserved_cents, open_calls)
  values (p_job_id, p_step, want, 1)
  on conflict (job_id, step) do update
    set reserved_cents =
          case
            when budget_reservations.settled_at is null
             and budget_reservations.created_at >= now() - public.budget_reservation_ttl()
             and budget_reservations.created_at >=
                 date_trunc('day', (now() at time zone 'utc')) at time zone 'utc'
            then budget_reservations.reserved_cents + excluded.reserved_cents
            else excluded.reserved_cents
          end,
        open_calls =
          case
            when budget_reservations.settled_at is null
             and budget_reservations.created_at >= now() - public.budget_reservation_ttl()
             and budget_reservations.created_at >=
                 date_trunc('day', (now() at time zone 'utc')) at time zone 'utc'
            then budget_reservations.open_calls + 1
            else 1
          end,
        created_at = now(),
        settled_at = null;

  return cap - (committed + held + want);
end;
$$;

revoke all on function public.reserve_budget(uuid, text, numeric) from public, anon, authenticated;
grant execute on function public.reserve_budget(uuid, text, numeric) to service_role;

-- ------------------------------------------------------------------ 6. instrumentation

/*
 * Whether the study Delta counts a claim as known at a moment: 20260925210000's rule for one
 * claim, for the stamp on each answer -- the claim is validated, its last outcome was a
 * success by `p_at` (when given), that success still proves recall, and its recall then is
 * above `known_retrievability_floor()`, days counted to at most a thousand stabilities.
 * `study_claim_knowledge` keeps its own set-shaped copy, which the course page reads for
 * every claim at once; calling this per claim from there was three times slower. The suite
 * holds the two to one answer (`supabase/tests/study_beta.sql`).
 */
create function public.study_claim_known(
  p_owner uuid,
  p_claim uuid,
  p_at timestamptz default null
)
returns boolean
language sql
stable
set search_path = ''
as $fn$
  select coalesce((
    select m.last_outcome = 'success'
           and (p_at is null or m.last_success_at <= p_at)
           and public.retrievability(
                 m.stability::real, m.last_success_at,
                 least(coalesce(p_at, now()),
                       m.last_success_at + make_interval(secs => m.stability * 86400 * 1000)))
               > public.known_retrievability_floor()
           and public.study_answer_proves_recall(m.last_success_id)
    from public.study_claim_memory m
    join public.study_claims c on c.id = m.claim_id and c.owner_id = m.owner_id
    where m.owner_id = p_owner and m.claim_id = p_claim and c.status = 'validated'
  ), false)
$fn$;

revoke all on function public.study_claim_known(uuid, uuid, timestamptz) from public, anon;
grant execute on function public.study_claim_known(uuid, uuid, timestamptz)
  to authenticated, service_role;

alter table public.study_answer_events add column claims_known_before boolean;

comment on column public.study_answer_events.claims_known_before is
  'Whether the study Delta counted every claim this question tests as known just before this '
  'answer (study_claim_known). Stamped on insert for a deterministically graded answer to a '
  'question the model wrote -- the only answers the measure reads; null for the rest and '
  'for answers recorded before 20260925220000. Measures false mastery (docs/study-beta.md); '
  'the proof rule never reads it.';

create function public.study_answer_known_before()
returns trigger
language plpgsql
set search_path = ''
as $fn$
begin
  -- Before the insert, so before the recorder moves the memory for this answer; after the
  -- stamp trigger (triggers fire by name), so at the time the answer is recorded at. Only
  -- where the measure reads it: the per-claim rule costs, and the recorder holds its locks
  -- while it runs.
  if new.grading <> 'deterministic'
     or not exists (select 1 from public.study_items i
                    where i.id = new.item_id and i.authored_by = 'model') then
    new.claims_known_before := null;
    return new;
  end if;
  new.claims_known_before := coalesce((
    select bool_and(public.study_claim_known(new.owner_id, ic.claim_id, new.answered_at))
    from public.study_item_claims ic
    where ic.item_id = new.item_id and ic.owner_id = new.owner_id
  ), false);
  return new;
end
$fn$;

revoke all on function public.study_answer_known_before() from public, anon, authenticated;

create trigger study_answer_events_with_known_before
  before insert on public.study_answer_events
  for each row execute function public.study_answer_known_before();

-- ------------------------------------------------------------------ 7. dashboards

create schema ops;

comment on schema ops is
  'Operators'' aggregate views of study courses. Not exposed through the API (config.toml '
  'exposes only public); readable by the service role. No row names a reader. See '
  'docs/study-beta.md.';

revoke all on schema ops from public, anon, authenticated;
grant usage on schema ops to service_role;

/* What the beta so far covers: courses with a current generation, by source kind and goal. */
create view ops.study_beta_mix as
with courses as (
  select c.id, c.owner_id, c.goal, public.study_course_generation(c.id) as generation_id
  from public.study_courses c
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

/*
 * The kinds of source and goal the beta has not yet covered well enough to open: each needs
 * at least three courses from at least two readers. Of `ops.study_beta_mix`, or of its rows
 * as JSON when given: the report has read the mix once already, and reading it costs a
 * lookup of every course's current generation.
 */
create function public.study_beta_unrepresented(p_mix jsonb default null)
returns text[]
language sql
stable
security definer
set search_path = ''
as $fn$
  select coalesce(array_agg(w.dimension || ':' || w.value order by w.dimension, w.value), '{}')
  from (values ('format', 'typed'), ('format', 'pdf'), ('format', 'docx'),
               ('format', 'scanned'), ('format', 'highlights'),
               ('goal', 'explain'), ('goal', 'discuss'), ('goal', 'remember'),
               ('goal', 'assess'), ('goal', 'own')) as w (dimension, value)
  left join (
    select m.dimension, m.value, m.courses, m.readers
    from ops.study_beta_mix m
    where p_mix is null
    union all
    select m.dimension, m.value, m.courses, m.readers
    from jsonb_to_recordset(p_mix) as m (dimension text, value text, courses int, readers int)
  ) as m on m.dimension = w.dimension and m.value = w.value
  where coalesce(m.courses, 0) < 3 or coalesce(m.readers, 0) < 2
$fn$;

revoke all on function public.study_beta_unrepresented(jsonb) from public, anon, authenticated;
grant execute on function public.study_beta_unrepresented(jsonb) to service_role;

/*
 * Open study courses to every reader with an account, on a release gate. Refused with 55000
 * when the gate did not pass (DETAIL `gate_failed`), is more than thirty days old
 * (`gate_stale`), or the beta so far leaves a kind of source or goal uncovered
 * (`unrepresentative`) and no reason of at least twenty characters is given to open anyway.
 */
create function public.open_study_beta(
  p_gate_id uuid,
  p_by text,
  p_override_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  gate    public.study_release_gates%rowtype;
  missing text[];
begin
  if p_by is null or char_length(btrim(p_by)) not between 1 and 200 then
    raise exception 'say who is opening the beta' using errcode = '22023';
  end if;
  select * into gate from public.study_release_gates where id = p_gate_id;
  if not found then
    raise exception 'no such release gate' using errcode = 'P0002';
  end if;
  if not gate.passed then
    raise exception 'that release gate did not pass' using errcode = '55000', detail = 'gate_failed';
  end if;
  if gate.ran_at <= now() - interval '30 days' then
    raise exception 'that release gate''s run is more than thirty days old; review again'
      using errcode = '55000', detail = 'gate_stale';
  end if;
  missing := public.study_beta_unrepresented();
  if cardinality(missing) > 0
     and (p_override_reason is null or char_length(btrim(p_override_reason)) < 20) then
    raise exception 'the beta so far does not cover: %', array_to_string(missing, ', ')
      using errcode = '55000', detail = 'unrepresentative',
            hint = 'Admit readers who cover them, or give a reason to open anyway.';
  end if;
  perform set_config('study.beta_override',
                     case when cardinality(missing) > 0 then btrim(p_override_reason) else '' end,
                     true);
  update public.study_beta_settings
     set open_to_all = true, gate_id = p_gate_id, changed_by = btrim(p_by)
   where id;
  if not found then
    raise exception 'the beta''s settings row is missing' using errcode = '55000';
  end if;
  -- Not left behind for a later write in the same transaction to be logged with.
  perform set_config('study.beta_override', '', true);
  return jsonb_build_object('open', true, 'gateId', p_gate_id, 'uncovered', to_jsonb(missing));
end
$fn$;

/* Close study courses to everyone but the allowlist. Always allowed. */
create function public.close_study_beta(p_by text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
begin
  if p_by is null or char_length(btrim(p_by)) not between 1 and 200 then
    raise exception 'say who is closing the beta' using errcode = '22023';
  end if;
  perform set_config('study.beta_override', '', true);
  update public.study_beta_settings set open_to_all = false, changed_by = btrim(p_by) where id;
  if not found then
    raise exception 'the beta''s settings row is missing' using errcode = '55000';
  end if;
  return jsonb_build_object('open', false);
end
$fn$;

-- The owner's alone, as the tables are.
revoke all on function public.open_study_beta(uuid, text, text)
  from public, anon, authenticated, service_role;
revoke all on function public.close_study_beta(text)
  from public, anon, authenticated, service_role;

/*
 * The beta's state: open or not, on which gate and how old its run is, whether admission
 * through it has lapsed, preparations since it opened whose pipeline is not the gate's,
 * courses still queued for readers no longer admitted, how many readers are allowlisted,
 * and today's spend -- study and everything else -- against the caps.
 */
create view ops.study_beta_status as
select s.open_to_all,
       s.changed_at,
       s.changed_by,
       g.id as gate_id,
       g.ran_at as gate_ran_at,
       floor(extract(epoch from now() - g.ran_at) / 86400)::int as gate_age_days,
       g.passed as gate_passed,
       g.pipeline as gate_pipeline,
       s.open_to_all and not coalesce(g.ran_at > now() - interval '60 days', false)
         as admission_lapsed,
       -- Off the gate's pipeline in either stage: assembled with another prompt, schema or
       -- model, or with a claim extracted with another.
       (select count(*) from public.study_generations sg
        where s.open_to_all and sg.created_at >= s.changed_at
          and sg.assembly_provenance is not null
          and ((sg.assembly_provenance ->> 'promptHash', sg.assembly_provenance ->> 'schemaHash',
                sg.assembly_provenance ->> 'model')
               is distinct from (g.pipeline -> 'assemble' ->> 'promptHash',
                                 g.pipeline -> 'assemble' ->> 'schemaHash',
                                 g.pipeline -> 'assemble' ->> 'model')
               or exists (select 1 from public.study_claims c
                          where c.generation_id = sg.id
                            and (c.prompt_hash, c.schema_hash, c.model)
                                is distinct from (g.pipeline -> 'extract' ->> 'promptHash',
                                                  g.pipeline -> 'extract' ->> 'schemaHash',
                                                  g.pipeline -> 'extract' ->> 'model'))))::int
         as preparations_off_gate,
       (select count(*) from public.generation_jobs j
        where j.kind = 'study_course' and j.status = 'queued'
          and not public.study_generation_admitted(j.requester_id))::int
         as queued_for_readers_not_admitted,
       (select count(*) from public.study_generation_access)::int as allowlisted_readers,
       public.study_beta_unrepresented() as uncovered,
       public.study_spend_today() as study_spend_today_cents,
       public.study_daily_cap_cents() as study_cap_cents,
       public.spend_today() - public.study_spend_today() as other_spend_today_cents,
       public.daily_spend_cap_cents() as daily_cap_cents
from public.study_beta_settings s
left join public.study_release_gates g on g.id = s.gate_id;

-- A day or a week in these views is UTC's in every session: the time is read in UTC and then
-- truncated. date_trunc's own zone argument is not enough -- it truncates in UTC but returns
-- a timestamptz, which the cast to date reads in the session's zone, so a Monday's week was
-- labelled Sunday in Los Angeles.

/* Preparation, by UTC day: courses made, jobs by outcome, time to finish, and spend. */
create view ops.study_daily as
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

/* What validation passed, by the UTC week the generation was made. */
create view ops.study_validation_weekly as
with gens as (
  select g.id, date_trunc('week', g.created_at at time zone 'UTC')::date as week, g.text_status
  from public.study_generations g
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

/*
 * What the beta is for, by the UTC week an answer was given. Counted over deterministic
 * answers to model-written questions -- self-graded answers and the reader's own questions
 * are practice, and prove nothing either way.
 *
 * - Seven-day unhinted recall: an answer given at least seven days after the reader's last
 *   answer to the same question (in any of its versions, however graded) was right,
 *   unhinted and graded by the rule -- recalled when it is right and unhinted again.
 * - False mastery: an unhinted answer to a question whose every claim the study Delta
 *   counted as known just before it (`claims_known_before`) -- false when it is wrong.
 */
create view ops.study_learning_weekly as
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

/* Reading, reporting and correcting, by UTC week. */
create view ops.study_trust_weekly as
with shown as (
  select date_trunc('week', p.recorded_at at time zone 'UTC')::date as week,
         count(*) filter (where p.kind = 'lesson_shown')::int as lessons_shown,
         count(*) filter (where p.kind = 'lesson_read')::int as lessons_read,
         count(*) filter (where p.kind = 'lesson_skipped')::int as lessons_skipped,
         count(*) filter (where p.kind = 'item_shown')::int as questions_shown
  from public.study_progress_events p
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
  group by 1
),
withdrawals as (
  -- The lesson, claim or question withdrawn; what rests on a withdrawn claim is logged as
  -- `claim_retired` and not counted again.
  select date_trunc('week', s.at at time zone 'UTC')::date as week, count(*)::int as withdrawn
  from public.study_status_log s
  where s.reason = 'retired'
  group by 1
),
corrections as (
  select date_trunc('week', x.created_at at time zone 'UTC')::date as week,
         count(*)::int as corrected
  from (select l.created_at from public.study_lessons l where l.authored_by = 'reader'
        union all
        select i.created_at from public.study_items i where i.authored_by = 'reader') as x
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

revoke all on all tables in schema ops from public, anon, authenticated;
grant select on all tables in schema ops to service_role;
