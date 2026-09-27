-- A job counts once it is due, a job parked on the budget is a spent day, and a target
-- must carry something to summarise.
--
-- 20260926210000 capped each reader at three jobs' worth of the day, and that bound turned
-- out to be per ACCOUNT. Four accounts, each with eight empty jobs sitting in the stagger,
-- came to 204 cents of "waiting" on an empty day. Every fifth reader was refused as
-- `committed`, and the stagger held those jobs in place for about four hours, at no cost.
-- A second review found three more problems:
--
-- 1. A job IN ITS STAGGER DELAY holds nothing. The door schedules a reader's fourth job
--    and later ones with `pgmq.send(..., delay_for)`, so the job's message is not
--    visible until then and no worker can start it. A job that cannot run cannot spend,
--    and when it comes due the door counts it. So `generation_waiting()` reads the
--    `generation` queue and counts a job only when one of its messages is due: visible now
--    (`vt <= clock_timestamp()`) or already delivered (`read_ct > 0`, a worker is on it).
--    A job whose messages are all still delayed, or that has no message at all (a stranded
--    job, which the sweep fails), is not counted. The same goes for a job in a
--    held-source wait: it re-asks in a minute and is counted then.
--
-- 2. A job PARKED ON THE BUDGET, meaning one whose message carries `budgetWaits > 0`,
--    cannot reserve before midnight in practice: its own reservation has already been
--    refused. It still counts, whether or not its message is due. It is counted apart,
--    because when parked jobs and spend between them are what close the door, the day is
--    `spent`, with the midnight sentence, not `committed`. Before this, one parked job
--    turned the rest of the day into "There will be room again as they run" and had the
--    Studio polling until midnight.
--
-- 3. A target with NOTHING TO SUMMARISE is refused at the door: no text and no URL. It
--    used to fail at `resolve_identity` for nothing, which made it free to submit.
--
-- The per-reader cap is unchanged: at most three summaries a reader, all kinds together,
-- parked and due together, and courses up to what the reader's study share can still
-- fund.
--
-- WHAT IS LEFT. A reader's due jobs are their fast ones, at most three, and they start
-- within moments of being admitted. So one account can hold at most three jobs' worth of
-- the day, and only for as long as the worker takes to pick those jobs up. A bad URL still
-- costs nothing to submit and fails at `acquire` for nothing, so an account can do this
-- again and again, three jobs at a time, and many accounts together can keep the door
-- `committed` for those moments. The reservation still bounds the day whatever the door
-- admits.
--
-- Law 2 holds: arithmetic over the jobs, the ledger, the holds and the queue, and no model
-- runs in here.

/*
 * What the jobs readers asked for, admitted and not started, will reserve at the least,
 * in two parts.
 *
 * A job is WAITING while it is queued or running, has a requester, has nothing charged
 * to it today (`cost_cents > 0`) and nothing held for it today (all as 20260926200000).
 * A waiting job then counts in one of two ways, or not at all:
 *
 *   parked  a message of its carries `budgetWaits > 0`: its reservation was refused and
 *           it waits for a day that can fund it. Counted whether or not the message is
 *           due, because it will ask again.
 *   due     otherwise, a message of its is visible now or already delivered: it can start
 *           now, or has.
 *   --      otherwise (every message still delayed, or none): not counted. It cannot
 *           spend before it runs, and when it comes due it is counted.
 *
 * For each reader, parked and due together, in cents:
 *
 *   summaries  least(count, 3) x min_job_cents(), across both summary kinds
 *   courses    least(count x study_min_job_cents(), what their study share can still fund)
 *
 * and the parked part is taken first, so a reader's cap is never counted twice.
 *
 * `clock_timestamp()` and not `now()`, because `pgmq.send` stamps `vt` with it. A message
 * sent a moment ago in a transaction that started earlier would otherwise read as not yet
 * due.
 *
 * `security definer` like `spend_today()` (it reads `pgmq`, which no API role may), and
 * granted like it: `service_role` only.
 */
create function public.generation_waiting(out parked_cents numeric, out due_cents numeric)
returns record
language sql
stable
security definer
set search_path = ''
as $$
  with waiting as (
    select j.id, j.requester_id, (j.kind = 'study_course') as study
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
  ),
  queued as (
    select w.id,
           -- A CASE, not `and`: a missing key must read as false, not as null, and a value
           -- that is not a number must never reach the cast.
           bool_or(case when jsonb_typeof(q.message -> 'budgetWaits') = 'number'
                        then (q.message ->> 'budgetWaits')::numeric > 0
                        else false
                   end) as parked,
           bool_or(q.read_ct > 0 or q.vt <= clock_timestamp()) as due
    from waiting w
    join pgmq.q_generation q on q.message ->> 'jobId' = w.id::text
    group by w.id
  ),
  counted as (
    select w.requester_id, w.study,
           count(*) filter (where qd.parked) as parked,
           count(*) filter (where not qd.parked and qd.due) as due
    from waiting w
    join queued qd on qd.id = w.id
    group by w.requester_id, w.study
  ),
  priced as (
    select c.*,
           case when c.study
                then greatest(public.study_requester_daily_cap_cents()
                              - public.study_requester_spend_today(c.requester_id), 0)
           end as share_left
    from counted c
  )
  select
    coalesce(sum(case when p.study
                      then least(p.parked * public.study_min_job_cents(), p.share_left)
                      else least(p.parked, 3) * public.min_job_cents()
                 end), 0),
    coalesce(sum(case when p.study
                      then least((p.parked + p.due) * public.study_min_job_cents(), p.share_left)
                           - least(p.parked * public.study_min_job_cents(), p.share_left)
                      else (least(p.parked + p.due, 3) - least(p.parked, 3))
                           * public.min_job_cents()
                 end), 0)
  from priced p;
$$;

comment on function public.generation_waiting() is
  'What jobs readers asked for, admitted and not started, will reserve at the least: '
  'parked_cents for those parked on the budget (a message with budgetWaits > 0), due_cents '
  'for those with a message visible or delivered. A job whose messages are all delayed is '
  'not counted. At most three summaries a reader; courses up to the reader''s study share. '
  'See 20260926220000.';

revoke all on function public.generation_waiting() from public, anon, authenticated;
grant execute on function public.generation_waiting() to service_role;

/* The two parts together, for anything that asks one number (the study-door follow-up). */
create or replace function public.generation_waiting_cents()
returns numeric
language sql
stable
security definer
set search_path = ''
as $$
  select w.parked_cents + w.due_cents from public.generation_waiting() as w;
$$;

comment on function public.generation_waiting_cents() is
  'generation_waiting(): parked_cents + due_cents. See 20260926220000.';

revoke all on function public.generation_waiting_cents() from public, anon, authenticated;
grant execute on function public.generation_waiting_cents() to service_role;

/*
 * `generation_budget_state`, with the door's third test.
 *
 *   spent      spend alone, or spend and parked jobs together, leave no room for a job
 *   committed  otherwise, and the jobs that are due take the room: until some have run
 *   low        four fifths of the day spent, parked or due
 *   open       otherwise
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
  spent  numeric := public.spend_today();
  cap    numeric := public.daily_spend_cap_cents();
  parked numeric;
  due    numeric;
begin
  -- The DOOR's tests, in the door's order.
  if spent + public.min_job_cents() > cap then return 'spent'; end if;
  select w.parked_cents, w.due_cents into parked, due from public.generation_waiting() as w;
  if spent + parked + public.min_job_cents() > cap then return 'spent'; end if;
  if spent + parked + due + public.min_job_cents() > cap then return 'committed'; end if;
  if spent + parked + due >= cap * 0.8 then return 'low'; end if;
  return 'open';
end;
$$;

comment on function public.generation_budget_state() is
  'open | low | committed | spent for the current UTC day. `spent` and `committed` are the '
  'door''s refusals in enqueue_generation_job, in its order: spent when spend, or spend '
  'and jobs parked on the budget, leave no room; committed when jobs that are due take '
  'it. Never the figures themselves: see 20260914030000.';

revoke all on function public.generation_budget_state() from public, anon;
grant execute on function public.generation_budget_state() to authenticated, service_role;

/*
 * `enqueue_generation_job`, restated from 20260926210000. Two sections change: a new one
 * after the `work_id` check refuses a target with nothing to summarise, and "REFUSED WHERE
 * A JOB COULD NOT RUN" reads `generation_waiting()` in two parts, with the parked part
 * closing the day as spent. Every other line is as that migration left it.
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
  parked     numeric;
  due        numeric;
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
   * SOMETHING TO SUMMARISE (20260926220000). `resolve_identity` fails a job whose target
   * has neither text nor a URL, and it fails it for nothing, since no provider has been
   * called. So such a job was free to submit, and until it ran it counted against the
   * day like any other. A `work_id` is not a source: it says which work a summary should
   * attach to, and the pipeline still needs text or a URL to write one. Refused here, in
   * the same voice as the other malformed targets. The Studio always sends text, and the
   * catalogue always sends a URL.
   */
  -- `coalesce`, because a missing key makes `jsonb_typeof` null, and `not null` is null:
  -- the target with nothing at all in it is exactly the one an unguarded test lets in.
  if not (   coalesce(jsonb_typeof(target -> 'text') = 'string'
                      and btrim(target ->> 'text') <> '', false)
          or coalesce(jsonb_typeof(target -> 'url') = 'string'
                      and btrim(target ->> 'url') <> '', false))
  then
    raise exception 'the generation target must carry text or a URL to summarise'
      using errcode = '22023';
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
   * admitted every reader who asked on an empty day. The ones the day could not fund then
   * waited out the worker's day of budget waits and failed. `generation_waiting_cents()`
   * counts each of those jobs at the least it will reserve, and at no more than three
   * jobs' worth for any one reader (20260926210000). Since 20260926220000 it counts a job
   * only once it is due, and it counts a job parked on the budget apart from the rest.
   * The rules for what counts are stated on `generation_waiting()`.
   *
   * It is an ESTIMATE, and on purpose. A waiting job is counted at the floor, a maximal
   * source can reserve nearly twice that, a job that has started counts only at what it
   * holds and not at the steps still ahead of it, and a reader's jobs past their third
   * are not counted at all. The estimate is what keeps a job from being admitted into a
   * wait. The reservation is what keeps the ledger from passing the cap, and it is exact.
   *
   * TWO REFUSALS, because they are two different facts for the reader. When spend alone
   * leaves no room, the day is over and nothing changes that before midnight: the old
   * sentence, unchanged. When spend leaves room and the jobs already waiting take it, the
   * day is COMMITTED rather than spent. That room comes back as those jobs run, and one
   * that fails early hands its share straight back, so the refusal says "in a little
   * while" and not "at 00:00 UTC", and carries DETAIL `committed` so the Studio can tell
   * the two apart without parsing the sentence. `generation_budget_state()` draws the
   * same line.
   *
   * A job PARKED ON THE BUDGET is the exception (20260926220000). Its reservation has
   * already been refused, and it waits in fifteen-minute steps for a day that can fund
   * it, which in practice means the next one. When spend and parked jobs between them
   * leave no room, nothing that runs today will give it back, so the day is spent: the
   * first sentence again, without the DETAIL.
   */
  spent := public.spend_today();
  if spent + min_job_cents > cap then
    raise exception
      'the daily generation budget is spent. Summaries resume at 00:00 UTC.'
      using errcode = '53400';
  end if;
  select w.parked_cents, w.due_cents into parked, due from public.generation_waiting() as w;
  if spent + parked + min_job_cents > cap then
    raise exception
      'the daily generation budget is spent. Summaries resume at 00:00 UTC.'
      using errcode = '53400';
  end if;
  if spent + parked + due + min_job_cents > cap then
    raise exception
      'today''s generation budget is committed to summaries already waiting to start. '
      'Try again in a little while.'
      using errcode = '53400', detail = 'committed';
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
