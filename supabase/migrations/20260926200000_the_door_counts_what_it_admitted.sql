-- The door counts the jobs it has already admitted.
--
-- `enqueue_generation_job` asked the day one question: does what is charged and held today
-- leave room for one more job at the least a job reserves? A job the door has admitted and
-- the worker has not yet started is neither charged nor held, so that question could not
-- see it. On an empty day every reader who asked was admitted, up to fifty jobs each. The
-- jobs the day could not fund went into the worker's budget wait (96 asks, fifteen minutes
-- apart) and failed a day later, while the Studio had told each reader "Started." The cap
-- held for the money, because `reserve_budget` enforces it. It did not hold for the promise:
-- law 2's "the worst case for a day is the cap and not the demand" was true of what the day
-- spent and false of what it had agreed to do.
--
-- The door now counts what the day has already agreed to, as well as what it has spent:
--
--   spend_today() + generation_waiting_cents() + min_job_cents() > daily_spend_cap_cents()
--
-- It refuses with the same 53400 and the same sentence as before. `generation_waiting_cents()`
-- is new here, and `generation_budget_state()` reads it too, so the screen and the door
-- still apply one test. 20260914170000 exists to keep them in agreement, and changing the
-- door alone would bring back the live submit button over a refused day that it removed.
--
-- What counts as waiting is set by four rules. Each one prevents a way of getting the count
-- wrong:
--
--   * Only jobs a READER asked for count. The catalogue's own jobs, which have no requester,
--     do not. The door answers a reader's request, and the catalogue is scheduled by the
--     operator. Counted, one seeding run closed the Studio to every reader until its backlog
--     drained, and a database replayed from zero, where 20260907011000 queues the whole
--     manifest and nothing locally runs it, showed the day as spent from the start.
--   * A job is WAITING while it is queued or running and today's spend does not include it:
--     nothing it cost has been charged today and nothing is held for it today. "Cost" means
--     `cost_cents > 0`. An attempt ledgered at nothing, such as a provider's 429 or a refused
--     connection, is not a start. Counted as one, a backlog left after an outage would drop
--     out of the count and let the door past the cap.
--   * A waiting job counts at the least its kind reserves: `min_job_cents()` for a summary
--     and `study_min_job_cents()` for a study course. A job that has started counts at what
--     it has charged and holds, which `spend_today()` already includes, so it is counted once.
--   * A reader's waiting study courses count for no more than that reader's study share can
--     still fund. Beyond that point they cannot start today, however much of the cap is left,
--     and counting them in full would let one reader's queue close the door for everyone.
--     Summaries have no share. The three-fast-then-stagger rule sets their pace and does not
--     limit what they spend, so each counts in full. Adding a share for summaries would
--     change law 2, and that change belongs in CLAUDE.md, not in this migration.
--
-- Law 2 holds: arithmetic over three tables, and no model runs in here.

/*
 * What jobs the day has admitted and not started will reserve, at the least.
 *
 * Readers' jobs only: `requester_id is not null`. A catalogue job, which has no requester,
 * spends the same cap once it runs, but it does not close the door. A seeding backlog waits
 * behind readers instead of shutting them out. The operator decides when the catalogue runs
 * and how much of it, and `reserve_budget` still bounds the day whoever holds the money. So
 * a day with a large catalogue backlog can admit a reader whose job then waits for the
 * catalogue's holds. That is the operator's schedule showing, and the cap still holds.
 *
 * `security definer` like `spend_today()`, and granted like it: `service_role` only. A
 * reader gets `generation_budget_state()`'s `open | low | spent` and never a figure.
 */
create function public.generation_waiting_cents()
returns numeric
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(sum(
           case
             when w.study then
               least(w.jobs * public.study_min_job_cents(),
                     greatest(public.study_requester_daily_cap_cents()
                              - public.study_requester_spend_today(w.requester_id), 0))
             else w.jobs * public.min_job_cents()
           end), 0)
  from (
    select j.requester_id, (j.kind = 'study_course') as study, count(*) as jobs
    from public.generation_jobs j
    where j.requester_id is not null
      and j.status in ('queued', 'running')
      and not exists (
        select 1 from public.cost_ledger cl
        where cl.job_id = j.id
          and cl.cost_cents > 0
          and cl.created_at >= date_trunc('day', (now() at time zone 'utc')) at time zone 'utc')
      and not exists (
        select 1 from public.budget_reservations br
        where br.job_id = j.id
          and br.settled_at is null
          and br.created_at >= now() - public.budget_reservation_ttl()
          and br.created_at >= date_trunc('day', (now() at time zone 'utc')) at time zone 'utc')
    group by j.requester_id, (j.kind = 'study_course')
  ) as w;
$$;

comment on function public.generation_waiting_cents() is
  'What the jobs readers asked for, admitted and not started, will reserve at the least: '
  'every queued or running job with a requester, nothing charged (cost_cents > 0) and '
  'nothing held today, at '
  'min_job_cents(), or at study_min_job_cents() capped by what its reader''s study share '
  'can still fund. The door in enqueue_generation_job and generation_budget_state() add it '
  'to spend_today(). See 20260926200000.';

revoke all on function public.generation_waiting_cents() from public, anon, authenticated;
grant execute on function public.generation_waiting_cents() to service_role;

/*
 * `generation_budget_state`, restated so `spent` is still the door's own test.
 *
 * The change is the figure. It is now what the day has spent plus what it has already
 * agreed to, so a reader sees `spent` at the moment the door stops admitting, and `low`
 * when four fifths of the day is spent or committed.
 */
create or replace function public.generation_budget_state()
returns text
language plpgsql
security definer
stable
set search_path = ''
as $$
declare
  -- Each read once: the reader's request path should not pay for the scans twice.
  committed numeric := public.spend_today() + public.generation_waiting_cents();
  cap       numeric := public.daily_spend_cap_cents();
begin
  -- The DOOR's test. A day whose room is already promised to queued jobs cannot fund
  -- another, and a screen that says otherwise only leads the reader to a refusal.
  if committed + public.min_job_cents() > cap then return 'spent'; end if;
  if committed >= cap * 0.8 then return 'low'; end if;
  return 'open';
end;
$$;

comment on function public.generation_budget_state() is
  'open | low | spent for the current UTC day, over what is spent and what is already '
  'admitted and waiting. `spent` is the same test the door in enqueue_generation_job '
  'applies, so a reader is never shown room that does not exist. Never the figures '
  'themselves: see 20260914030000.';

revoke all on function public.generation_budget_state() from public, anon;
grant execute on function public.generation_budget_state() to authenticated, service_role;

/*
 * `enqueue_generation_job`, restated from 20260914170000. It changes in two places, both in
 * the section headed "REFUSED WHERE A JOB COULD NOT RUN": the budget test adds
 * `generation_waiting_cents()`, and it now runs after the per-requester lock instead of
 * before it. Every other line is as that migration left it.
 */
create or replace function public.enqueue_generation_job(
  p_target jsonb,
  p_mutation_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  daily_fast_limit   constant int := 3;
  daily_hard_ceiling constant int := 50;
  stagger_seconds    constant int := 300;
  max_text_length    constant int := 200000;
  max_title_length   constant int := 200;
  -- What one job will reserve before it can do anything: synthesize plus embed.
  -- Read from `min_job_cents()` rather than pinned here, so the screen that says
  -- whether there is room and the door that decides cannot drift apart.
  min_job_cents      constant numeric := public.min_job_cents();

  uid        uuid := (select auth.uid());
  used       int;
  over       boolean;
  job_id     uuid;
  delay_for  int;
  job_kind   text;
  target     jsonb := coalesce(p_target, '{}'::jsonb);
  work_ref   text;
  spent      numeric;
  waiting    numeric;
  cap        numeric := public.daily_spend_cap_cents();
  replayed   public.generation_jobs%rowtype;
begin
  if uid is null then
    raise exception 'enqueue_generation_job requires an authenticated user';
  end if;

  if not exists (
    select 1 from auth.users u where u.id = uid and u.is_anonymous is not true
  ) then
    raise exception
      'Generating a summary needs an account. Sign in with an email address and try again.'
      using errcode = '28000';
  end if;

  /*
   * A REPLAY, answered before anything is spent or counted.
   *
   * Every other write in this app that can be retried carries a mutation id for this --
   * `explanations`, `convictions`, the recall grades -- and the one that spends money
   * did not. A submit whose response is lost (the request committed, the answer never
   * arrived) puts the screen's "that has not reached your account" in front of a reader
   * who then presses again, and the second press bought a second generation: real
   * provider spend against the day's cap, and on an adopted book a second summary of
   * one title on the reader's own shelf.
   *
   * Before the quota, the cap and the insert, so a replay costs nothing and counts for
   * nothing. The answer is the original job's, with `remainingToday` recomputed, because
   * what the caller needs is the job it already has.
   */
  if p_mutation_id is not null then
    /*
     * UNDER THE LOCK, which is the correction rather than a tidy-up.
     *
     * Read before it, two presses racing each other both saw no row -- the button
     * carries `aria-disabled` and stays clickable -- so both fell through, the first
     * inserted, and the second died on `generation_jobs_client_mutation_key` with a raw
     * constraint violation under the form while a job really had started. Taking the
     * per-requester lock first makes the second press wait, and by the time it reads,
     * the first is committed and it replays. The lock is per user and transaction-scoped,
     * and taking it here rather than further down only widens what it covers.
     */
    perform pg_advisory_xact_lock(pg_catalog.hashtextextended(uid::text, 0));

    select * into replayed
    from public.generation_jobs gj
    where gj.requester_id = uid and gj.client_mutation_id = p_mutation_id;

    if found then
      /*
       * A job that is OVER is over, whatever its place in the queue used to be.
       *
       * This recomputed the stagger for every replay and never looked at the status, so
       * a reader replaying a submit whose job had since failed -- a provider outage, or
       * the budget wait running out -- got `queue: 'fast', delaySeconds: 0`, which the
       * Studio prints as "Started." directly above a job list saying it did not finish.
       * The row already knows; this says so and lets the screen read the job itself.
       */
      if replayed.status in ('succeeded', 'failed', 'cancelled') then
        select count(*) into used
        from public.generation_jobs
        where requester_id = uid
          and created_at >= date_trunc('day', (now() at time zone 'utc')) at time zone 'utc';

        return jsonb_build_object(
          'jobId', replayed.id,
          'kind', replayed.kind,
          'queue', 'fast',
          'delaySeconds', 0,
          'replayed', true,
          'finished', true,
          'status', replayed.status,
          'remainingToday', greatest(daily_hard_ceiling - used, 0),
          'budget', public.generation_budget_state()
        );
      end if;

      /*
       * The placement it ACTUALLY got, not a cheerful default.
       *
       * This answered `queue: 'fast', delaySeconds: 0` for every replay, and the Studio
       * branches on exactly that to print "Started." -- so a reader replaying their 20th
       * job of the day was told a summary had begun that would not start for ninety
       * minutes. Nothing is stored about the delay, but everything needed to recompute it
       * is: the job's own position among that day's jobs is how many the requester had
       * queued before it, which is what decided the stagger at the time.
       */
      select count(*) into used
      from public.generation_jobs gj
      where gj.requester_id = uid
        and gj.created_at >= date_trunc('day', (replayed.created_at at time zone 'utc'))
                             at time zone 'utc'
        -- `(created_at, id)`, because `created_at` alone is not a total order: two jobs
        -- written in the same millisecond would each count the other as later and both
        -- claim the earlier slot. The pair is what the insert order actually was.
        and (gj.created_at, gj.id) < (replayed.created_at, replayed.id);

      over := used >= daily_fast_limit;
      delay_for := case
                     when over then (used - daily_fast_limit + 1) * stagger_seconds
                     else 0
                   end;

      -- What is LEFT of that wait, since some of it has already passed.
      delay_for := greatest(
        delay_for - floor(extract(epoch from (now() - replayed.created_at)))::int, 0);

      select count(*) into used
      from public.generation_jobs
      where requester_id = uid
        and created_at >= date_trunc('day', (now() at time zone 'utc')) at time zone 'utc';

      return jsonb_build_object(
        'jobId', replayed.id,
        'kind', replayed.kind,
        'queue', case when delay_for > 0 then 'normal' else 'fast' end,
        'delaySeconds', delay_for,
        'replayed', true,
        'remainingToday', greatest(daily_hard_ceiling - used, 0),
        'budget', public.generation_budget_state()
      );
    end if;
  end if;

  /*
   * An OBJECT, or nothing.
   *
   * `coalesce(p_target, '{}')` covers a missing target and not a malformed one: a
   * client that posts `{"p_target": "hello"}` sends a jsonb STRING, which survives
   * every `->>` below as NULL without complaint and then reaches `target - 'visibility'`
   * -- where `jsonb - text` raises `cannot delete from scalar`, an unhandled 22023 with
   * a message about the internals of a function the caller cannot see. Every other
   * refusal in here is a sentence; this was the one shape that got a stack trace.
   */
  if jsonb_typeof(target) <> 'object' then
    raise exception 'the generation target must be an object, not %', jsonb_typeof(target)
      using errcode = '22023';
  end if;

  job_kind := coalesce(nullif(target ->> 'jobKind', ''), 'canonical_summary');
  if job_kind not in ('canonical_summary', 'private_summary') then
    raise exception 'unknown job kind %; expected canonical_summary or private_summary',
      job_kind
      using errcode = '22023';
  end if;

  if length(coalesce(target ->> 'text', '')) > max_text_length then
    raise exception 'the submitted text is % characters; the limit is %',
      length(target ->> 'text'), max_text_length
      using errcode = 'check_violation';
  end if;

  if length(coalesce(target ->> 'title', '')) > max_title_length then
    raise exception 'the title is % characters; the limit is %',
      length(target ->> 'title'), max_title_length
      using errcode = 'check_violation';
  end if;

  target := target - 'visibility';
  work_ref := target ->> 'work_id';
  if work_ref is null
     or work_ref !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
     or not exists (
       select 1 from public.summaries s
       where s.work_id = work_ref::uuid and s.author_id = uid
     )
  then
    target := target - 'work_id';
  end if;

  /*
   * The per-requester lock, taken BEFORE the budget test now rather than after it.
   *
   * The test below sums every requester's waiting jobs, and the lock it runs under covers
   * only this requester. What that lock gives is that one reader's own concurrent submits
   * (two tabs, or two presses with different mutation ids) are ordered, so the second
   * counts the first's job. Two DIFFERENT readers at the door at the same moment can each
   * be counted without the other and both be admitted into room for one. That overshoot is
   * bounded by how many readers arrive within one transaction of each other, not by
   * demand, and the job it admits waits rather than overspends: `reserve_budget`, which
   * runs under one lock for the whole budget, is what holds the cap exactly.
   *
   * Not that budget lock. Every worker's reservation queues behind it, and this function
   * is callable by every signed-in reader. That includes calls it refuses, which cost the
   * reader nothing and count against no quota. Taking the lock here would give any reader
   * a free way to stall everyone's reservations, and the thing it would make exact is an
   * estimate in any case (below).
   */
  perform pg_advisory_xact_lock(pg_catalog.hashtextextended(uid::text, 0));

  /*
   * REFUSED WHERE A JOB COULD NOT RUN, not only where the budget is exactly gone.
   *
   * `spent >= cap` let a job in at 196 of 200 and told the reader it had started, and
   * `reserve_budget` then refused it at `196 + 6 > 200` -- so it parked in the 24-hour
   * budget wait while the screen said "Started. 46 more today." The door and the
   * reservation have to agree, so the door asks for what a job actually needs: the
   * worst case of the two provider steps it will reserve for.
   *
   * TWENTY, NOT SEVEN. Seven was 6 + 1, and the 6 was the EXPECTED cost of a Gemini
   * summary rather than a ceiling — `synthesize` now reserves the active provider's own
   * worst case, which at the Anthropic fallback's configured `max_tokens` and default
   * prices is 19 cents for one accepted source. A door pinned at 7 admitted jobs the
   * reservation then refused, which is the disagreement this check exists to prevent,
   * and the reservation is the half that may not be loosened: it is what stops the
   * ledger passing the cap.
   *
   * Stated in `min_job_cents()` rather than imported, because SQL cannot read
   * `providers.ts`. If the ceilings or the prices move, that function moves with them
   * -- and the failure if it does not is a job accepted into a wait, which is visible
   * rather than silent.
   *
   * It is a FLOOR now, not the ceiling for the largest source. `worstCaseCentsFor` is
   * per call: the input half is the prompt's own byte length, so a two-page essay holds
   * a fraction of what a 200,000-character book holds. A door pinned to the book would
   * refuse the essay with 30 cents of the day unspent and nothing able to use it. The
   * cost of the floor is the opposite case -- a maximal source admitted in the last
   * stretch of a day, whose reservation is then refused and which waits -- and between
   * throwing away a sixth of every day and parking the rare largest job, the job waits.
   *
   * AND WHAT IT HAS ALREADY ADMITTED (20260926200000). The day's spend does not include
   * a job a reader asked for that is queued and not yet started, so a test on spend alone
   * admitted every reader who asked on an empty day. The ones the day could not fund then waited out the
   * worker's day of budget waits and failed. `generation_waiting_cents()` counts each of
   * those jobs at the least it will reserve, and the rules for what counts are stated
   * there.
   *
   * It is an ESTIMATE, and on purpose. A waiting job is counted at the floor, a maximal
   * source can reserve nearly twice that, and a job that has started counts only at what
   * it holds and not at the steps still ahead of it. The estimate is what keeps a job from
   * being admitted into a wait. The reservation is what keeps the ledger from passing the
   * cap, and it is exact.
   */
  spent := public.spend_today();
  waiting := public.generation_waiting_cents();
  if spent + waiting + min_job_cents > cap then
    raise exception
      'the daily generation budget is spent. Summaries resume at 00:00 UTC.'
      using errcode = '53400';
  end if;

  select count(*) into used
  from public.generation_jobs
  where requester_id = uid
    and created_at >= date_trunc('day', (now() at time zone 'utc')) at time zone 'utc';

  if used >= daily_hard_ceiling then
    raise exception 'daily generation ceiling reached (% jobs); try again tomorrow',
      daily_hard_ceiling
      using errcode = 'check_violation';
  end if;

  over := used >= daily_fast_limit;

  delay_for := case
                 when over then (used - daily_fast_limit + 1) * stagger_seconds
                 else 0
               end;

  insert into public.generation_jobs (requester_id, kind, target, status, client_mutation_id)
  values (uid, job_kind, target, 'queued', p_mutation_id)
  returning id into job_id;

  perform pgmq.send('generation',
                    jsonb_build_object('jobId', job_id, 'step', 'resolve_identity'),
                    delay_for);

  return jsonb_build_object(
    'jobId', job_id,
    'kind', job_kind,
    'queue', case when over then 'normal' else 'fast' end,
    'delaySeconds', delay_for,
    'remainingToday', daily_hard_ceiling - used - 1,
    'budget', public.generation_budget_state()
  );
end;
$$;

revoke all on function public.enqueue_generation_job(jsonb, uuid) from public, anon, authenticated;
grant execute on function public.enqueue_generation_job(jsonb, uuid) to authenticated;
