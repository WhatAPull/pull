-- The study door's share counts a course until it is ready, and its lasting refusals come
-- first.
--
-- A review of 20260927100000 found three things:
--
-- 1. A course left the reader's share count at its first charge or hold. A course that had
--    charged a few cents let a second in beside it (5 + 31 <= 60), and the second then
--    waited on the share past midnight, which is what 20260927100000 set out to stop. A
--    course being prepared now counts for what it still needs of the least a course
--    reserves -- that least, less what it has charged or holds today -- until it finishes.
--    With the share at 60 cents and a course at 31, a reader prepares one course at a time.
--
-- 2. The `share` refusal said "It resets at 00:00 UTC", which was not when it lifted. It now
--    lifts when the course being prepared finishes, and says "Try again once it is ready".
--    If what that course cost leaves no room, the next press is refused as the share spent,
--    until midnight, in those words.
--
-- 3. The day's `committed` test ran before the reader's share-spent test, so a reader whose
--    share was spent until midnight could be told to try again in a little while, and then
--    to wait until midnight. The refusals that last until midnight now come first: the day
--    spent, the day spent with parked jobs, the share spent; then `committed`, then `share`.
--
-- Nothing else in `study_enqueue_course` changes, and nothing else is redefined. Execute
-- stays with the owner alone, as CREATE OR REPLACE keeps it.
--
-- Law 2 holds: arithmetic over rows, and no model runs in here.

/*
 * As 20260927100000, with the share counting what each course being prepared still needs,
 * and the refusals ordered by how long they last.
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
  least_     numeric := public.study_min_job_cents();
  spent      numeric;
  cap        numeric;
  parked     numeric;
  due        numeric;
  mine       numeric;
  mine_need  numeric;
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

  -- The day and the reader's share, the refusals that last until midnight first and those that
  -- lift within minutes after them, so a reader told to try again in a little while is not
  -- then told to wait until midnight. Each test asks for the least a course reserves.
  --
  -- The day is tested as `enqueue_generation_job` tests it (20260926200000). Spend alone, or
  -- spend and the jobs parked on the budget, leave no room: the day is spent until midnight.
  -- Otherwise the jobs due to start may take the room that is left, and the day is committed
  -- to them until they start or fail -- 53400 with DETAIL `committed`, and no promise of
  -- midnight. `generation_waiting()` counts every reader's admitted, unstarted work of both
  -- kinds, a reader's summaries at three jobs' worth at most and their courses at no more than
  -- their study share can still fund; its rules are stated on it.
  spent := public.spend_today();
  cap := public.daily_spend_cap_cents();
  if spent + least_ > cap then
    raise exception 'the daily generation budget is spent. Study generation resumes at 00:00 UTC.'
      using errcode = '53400';
  end if;
  select w.parked_cents, w.due_cents into parked, due from public.generation_waiting() as w;
  if spent + parked + least_ > cap then
    raise exception 'the daily generation budget is spent. Study generation resumes at 00:00 UTC.'
      using errcode = '53400';
  end if;
  mine := public.study_requester_spend_today(uid);
  if mine + least_ > public.study_requester_daily_cap_cents() then
    raise exception 'your share of today''s study generation budget is spent. It resets at 00:00 UTC.'
      using errcode = '53400';
  end if;
  if spent + parked + due + least_ > cap then
    raise exception 'today''s generation budget is committed to work already waiting to start. '
                    'Try again in a little while.'
      using errcode = '53400', detail = 'committed';
  end if;

  -- The reader's share, with what their courses being prepared still need. A course is being
  -- prepared while it is queued or running and its message is on the queue -- a job the sweep
  -- has yet to fail as stranded is not -- and it needs at least `study_min_job_cents()` of
  -- the share over the day, of which what it has charged or holds today is already in the
  -- reader's spend. So each counts for the rest of that least, until it finishes. Counted only
  -- until its first charge or hold (20260927100000), a course that had charged a few cents
  -- let a second in beside it, and the second waited on the share past midnight. With the
  -- share at 60 cents and a course at 31, a reader prepares one course at a time: the next is
  -- refused with DETAIL `share` until this one is ready, and then only if what it cost leaves
  -- room. A charge from before midnight is not today's, so it leaves the course's need whole.
  select coalesce(sum(greatest(least_ - coalesce(c.charged, 0) - coalesce(h.held, 0), 0)), 0)
    into mine_need
  from public.generation_jobs j
  left join lateral (
    select sum(cl.cost_cents) as charged
    from public.cost_ledger cl
    where cl.job_id = j.id
      and cl.created_at >= date_trunc('day', (now() at time zone 'utc')) at time zone 'utc'
  ) as c on true
  left join lateral (
    select sum(br.reserved_cents) as held
    from public.budget_reservations br
    where br.job_id = j.id and br.settled_at is null
      and br.created_at >= now() - public.budget_reservation_ttl()
      and br.created_at >= date_trunc('day', (now() at time zone 'utc')) at time zone 'utc'
  ) as h on true
  where j.requester_id = uid and j.kind = 'study_course' and j.status in ('queued', 'running')
    and exists (select 1 from pgmq.q_generation q where q.message ->> 'jobId' = j.id::text);
  if mine + mine_need + least_ > public.study_requester_daily_cap_cents() then
    raise exception 'your share of today''s study generation budget is set aside for another '
                    'course of yours being prepared. Try again once it is ready.'
      using errcode = '53400', detail = 'share';
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
  -- reader's queue closed the door to everyone. The reader's own check above now keeps their
  -- courses being prepared within their share; the cap here still holds for courses admitted
  -- before it did (20260927110000).
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

