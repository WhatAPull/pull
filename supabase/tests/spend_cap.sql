-- The daily budget: a reservation, not a reading.
--
-- The property worth protecting is the one a naive implementation gets wrong in a way
-- nobody notices until the invoice arrives: checking `spend_today()` before a provider
-- call is not a cap, because two workers read the same number and both proceed. So the
-- assertions here are mostly about CONCURRENCY and SETTLEMENT rather than about
-- arithmetic:
--
--   * a reservation is counted against the cap by everybody, not only by the worker
--     that took it -- which is what makes two workers unable to both fit in the same
--     remaining budget
--   * a step whose earlier hold is SETTLED takes that row over rather than stacking, so a
--     retry is not refused against money nobody is spending -- while a step redelivered
--     while its first call is still open adds to the hold, because both calls spend
--   * `record_job_step` replaces the hold with the charge in one transaction, so there
--     is no instant where the money is counted twice and none where it goes uncounted
--   * a step that dies holding a reservation is released by the stranded sweep, and by
--     the TTL if the sweep never runs
--   * `spend_today()` never counts `generation_jobs.cost_cents`, which `record_job_step`
--     already writes for every ledgered charge -- counting both halves the cap while
--     claiming not to
--   * `enqueue_generation_job` refuses at the door when the day is spent, validates the
--     job kind and the payload bounds, and keeps `work_id` only where the caller
--     authored a summary on that work
--   * and it counts what it has already admitted: a job a reader asked for, queued and
--     not yet started, is neither charged nor held, so the door adds it at the least it
--     will reserve (the catalogue's own jobs are not counted), and the screen reports
--     `spent` at the same point
--   * the API roles cannot insert a `generation_jobs` row of their own
--
-- Run as the owner where the subject is the arithmetic, and as `authenticated` where
-- the subject is what a reader may do -- RLS and grants are invisible to an owner-role
-- query, and half of this file would prove nothing without the switch.
--
-- Read-only in effect: everything below rolls back.
\set ON_ERROR_STOP on

begin;

do $$
declare
  reader      uuid := extensions.gen_random_uuid();
  other       uuid := extensions.gen_random_uuid();
  job_a       uuid;
  job_b       uuid;
  job_c       uuid;
  job_d       uuid;
  job_e       uuid;
  job_f       uuid;
  some_work   uuid;
  other_work  uuid;
  cap         numeric := public.daily_spend_cap_cents();
  spent       numeric;
  left_over   numeric;
  refused     boolean;
  queued      jsonb;
  held        int;
begin
  if cap <= 0 then
    raise exception 'daily_spend_cap_cents() is %, so nothing below can mean anything', cap;
  end if;

  insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                          email_confirmed_at, created_at, updated_at,
                          raw_app_meta_data, raw_user_meta_data, is_anonymous)
  values (reader, '00000000-0000-0000-0000-000000000000',
          'authenticated', 'authenticated',
          'spend-cap' || left(reader::text, 8) || '@example.test', '',
          now(), now(), now(),
          '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb, false),
         (other, '00000000-0000-0000-0000-000000000000',
          'authenticated', 'authenticated',
          'spend-cap' || left(other::text, 8) || '@example.test', '',
          now(), now(), now(),
          '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb, false);

  select w.id into some_work from public.works w order by w.id limit 1;
  select w.id into other_work from public.works w order by w.id desc limit 1;
  if some_work is null or some_work = other_work then
    raise exception 'the corpus has fewer than two works; this fixture needs two';
  end if;

  insert into public.generation_jobs (requester_id, target, status)
  values (reader, '{"text":"x"}'::jsonb, 'running') returning id into job_a;
  insert into public.generation_jobs (requester_id, target, status)
  values (reader, '{"text":"x"}'::jsonb, 'running') returning id into job_b;
  insert into public.generation_jobs (requester_id, target, status)
  values (reader, '{"text":"x"}'::jsonb, 'running') returning id into job_c;

  -- Aged at INSERT, not by a later update: `set_updated_at` is a `before update`
  -- trigger, so an `update ... set updated_at = ...` is stamped straight back to now()
  -- and the sweep below would find nothing. `stranded_jobs.sql` learned this first.
  insert into public.generation_jobs (requester_id, target, status, current_step, updated_at)
  values (reader, '{"text":"x"}'::jsonb, 'running', 'artwork', now() - interval '1 hour')
  returning id into job_d;

  -- --------------------------------------------- 1. a hold is everybody's hold
  --
  -- The reservation job A takes has to be visible to the sum job B is measured
  -- against. If it is not, two workers fit inside the same remaining budget and the
  -- overshoot is unbounded in the number of workers.
  spent := public.spend_today();
  if spent <> 0 then
    raise exception 'the fixture started with % cents already spent today', spent;
  end if;

  perform public.reserve_budget(job_a, 'synthesize', cap - 1);
  if public.spend_today() <> cap - 1 then
    raise exception
      'a hold of % is not counted by spend_today() (it says %). A reservation only its '
      'own worker can see is not a cap.', cap - 1, public.spend_today();
  end if;

  refused := false;
  begin
    perform public.reserve_budget(job_b, 'synthesize', 5);
  exception when configuration_limit_exceeded then
    refused := true;
  end;
  if not refused then
    raise exception
      'a second job reserved 5 cents while % of % were already held. Two workers just '
      'both decided they were under the cap.', cap - 1, cap;
  end if;

  -- And the budget that does fit is still granted, so the cap is a bound rather
  -- than a wall.
  left_over := public.reserve_budget(job_b, 'synthesize', 1);
  if left_over <> 0 then
    raise exception 'reserve_budget reported % left after filling the cap exactly', left_over;
  end if;

  -- ----------------------------------- 2. a RETRY re-reserves rather than stacking
  --
  -- pgmq can hand the same message out twice, and the two cases are not the same. A
  -- step that has finished -- failed or billed -- settled its hold on the way out, so
  -- the delivery that retries it finds a dead row and takes it over: one row, and the
  -- total where it was. Stacking there would refuse a retry against money nobody is
  -- spending. The other case, where the earlier call is still OPEN, is a second call
  -- and is asserted at 5b-ii below.
  perform public.settle_budget(job_b, 'synthesize');
  perform public.reserve_budget(job_b, 'synthesize', 1);
  select count(*) into held from public.budget_reservations br
   where br.job_id = job_b and br.step = 'synthesize';
  if held <> 1 then
    raise exception 'a redelivered step opened % reservations; it must reuse one', held;
  end if;
  if public.spend_today() <> cap then
    raise exception
      're-reserving a settled step moved the total to % rather than leaving it at %',
      public.spend_today(), cap;
  end if;

  -- ------------------------------------ 3. the ledger replaces the hold, atomically
  --
  -- `record_job_step` writes the charge and settles the reservation in one
  -- transaction. A sum that counted both would be double; one that counted neither
  -- would let the next caller spend money already spent.
  perform public.settle_budget(job_b, 'synthesize');
  if public.spend_today() <> cap - 1 then
    raise exception 'settling job B''s hold left the total at %', public.spend_today();
  end if;

  perform public.record_job_step(
    job_a, 'synthesize', 1, 'stub', 'v1', 100, 100, 10::numeric, 5, 'stub', true, null
  );
  spent := public.spend_today();
  if spent <> 10 then
    raise exception
      'after a 10-cent charge replaced a % cent hold, spend_today() says %. The hold '
      'and the charge must not both count, and one of them must.', cap - 1, spent;
  end if;

  -- The roll-up into generation_jobs.cost_cents happened too, and must NOT be counted.
  if (select gj.cost_cents from public.generation_jobs gj where gj.id = job_a) <> 10 then
    raise exception 'record_job_step stopped rolling the charge into the job total';
  end if;
  if public.spend_today() <> 10 then
    raise exception
      'spend_today() is % with one 10-cent charge on the ledger and the same 10 cents '
      'on the job row. Counting both halves the cap while claiming not to.',
      public.spend_today();
  end if;

  -- ------------------------------------------ 4. a failed step lets go of its hold
  perform public.reserve_budget(job_c, 'embed', 20);
  if public.spend_today() <> 30 then
    raise exception 'spend_today() is % after a 20-cent hold on top of 10 charged',
      public.spend_today();
  end if;
  perform public.record_failed_job_step(job_c, 'embed', 1, 'boom', 5, null, null, 0, 0, 0, false);
  if public.spend_today() <> 10 then
    raise exception
      'a failed step left % held. A provider outage would pin the cap shut.',
      public.spend_today() - 10;
  end if;

  -- --------------------------------------- 5. a stranded job releases what it held
  --
  -- Nothing will ever record for a job the sweep declares dead, so the sweep is the
  -- only thing between a crash and an hour of held budget.
  --
  -- Backdated with the job, because 20260914040000 made the settlement pass ignore a
  -- hold younger than its own threshold: a young hold belongs to a step that is still
  -- calling its provider, not to a crash. Nothing real puts a fresh hold on a job the
  -- sweep will fail -- `reserve_budget` runs immediately after a dispatch that stamps
  -- `updated_at`, and a job stamped seconds ago is not stranded -- so the fixture is
  -- what was unrealistic here, and it was hiding the sibling race the new bound closes.
  perform public.reserve_budget(job_d, 'artwork', 50);
  update public.budget_reservations
     set created_at = now() - interval '25 minutes'
   where job_id = job_d and step = 'artwork';
  if public.spend_today() <> 60 then
    raise exception 'the fixture for the sweep did not take; spend_today() is %',
      public.spend_today();
  end if;
  perform public.sweep_stranded_generation_jobs(interval '10 minutes');
  if public.spend_today() <> 10 then
    raise exception
      'the sweep failed a job and left % cents held against the cap',
      public.spend_today() - 10;
  end if;

  -- --------------------------- 5b. a terminal job holds nothing, however it ended
  --
  -- The sweep used to settle only the jobs IT failed, which misses the commonest
  -- terminal failure the pipeline has: the worker exhausting a step's retries and
  -- marking the job failed itself. That job is no longer `queued` or `running`, so the
  -- sweep's own selection can never reach it, and nothing else would until the TTL.
  --
  -- Backdated for the reason 5 above gives: the settlement pass leaves a hold younger
  -- than its threshold alone, because a young hold on a job that has just failed is a
  -- SIBLING STEP still inside its provider call. Section 11 asserts that half.
  insert into public.generation_jobs (requester_id, target, status)
  values (reader, '{"text":"x"}'::jsonb, 'running') returning id into job_e;
  perform public.reserve_budget(job_e, 'synthesize', 40);
  update public.budget_reservations
     set created_at = now() - interval '25 minutes'
   where job_id = job_e and step = 'synthesize';
  update public.generation_jobs set status = 'failed', finished_at = now() where id = job_e;
  if public.spend_today() <> 50 then
    raise exception 'the fixture for the terminal sweep did not take; spend_today() is %',
      public.spend_today();
  end if;
  perform public.sweep_stranded_generation_jobs(interval '10 minutes');
  if public.spend_today() <> 10 then
    raise exception
      'a job that failed outside the sweep kept % cents held. During a provider outage '
      'that is how a cap nobody spent closes for an hour.', public.spend_today() - 10;
  end if;

  -- ------------------- 5b-ii. two calls of ONE step are two holds, not one
  --
  -- pgmq redelivers on a visibility timeout, not on a proof that the last attempt died,
  -- so a `synthesize` call that runs past the worker's 180 s message hold is run a
  -- second time while the first is still inside the provider. `reserve_budget` used to
  -- upsert onto `(job, step)` while excluding that same key from the total it checked,
  -- so the second call was free -- and then the first to return stamped the row settled,
  -- leaving the second call's spend held by nothing.
  insert into public.generation_jobs (requester_id, target, status)
  values (reader, '{"text":"x"}'::jsonb, 'running') returning id into job_f;
  perform public.reserve_budget(job_f, 'synthesize', 6);
  perform public.reserve_budget(job_f, 'synthesize', 6);
  if public.spend_today() <> 22 then
    raise exception
      'two concurrent calls of one step came to % cents of hold, not 12. The cap cannot '
      'see money it is not counting.', public.spend_today() - 10;
  end if;

  -- The first call returns: its share goes back, the other call's does not.
  perform public.settle_budget(job_f, 'synthesize');
  if public.spend_today() <> 16 then
    raise exception
      'settling one of two outstanding calls left % held; the other call is still inside '
      'its provider and its six cents must stay held.', public.spend_today() - 10;
  end if;
  if (select br.settled_at from public.budget_reservations br
       where br.job_id = job_f and br.step = 'synthesize') is not null then
    raise exception 'the hold was stamped settled while a call was still outstanding';
  end if;

  perform public.settle_budget(job_f, 'synthesize');
  if public.spend_today() <> 10 then
    raise exception 'the last settle left % held', public.spend_today() - 10;
  end if;
  if (select br.settled_at from public.budget_reservations br
       where br.job_id = job_f and br.step = 'synthesize') is null then
    raise exception 'the last call released its share and the hold was left open';
  end if;

  -- --------------------- 5c. and two holds on one job are two independent holds
  --
  -- `settle_job_budget` released all of a job's holds in one call, and 20260914050000
  -- drops it: both callers now settle `(job, step)`, because a job being failed is not
  -- the same moment as every one of its steps being over -- `extract_evidence` runs
  -- beside `synthesize` and can still be mid-call. What has to hold is that settling
  -- one step leaves its sibling's money exactly where it was.
  perform public.reserve_budget(job_a, 'embed', 20);
  perform public.reserve_budget(job_a, 'artwork', 30);
  if public.spend_today() <> 60 then
    raise exception 'two holds on one job came to %', public.spend_today() - 10;
  end if;
  perform public.settle_budget(job_a, 'embed');
  if public.spend_today() <> 40 then
    raise exception
      'settling one step of a two-step job left % held; it should have released 20 and '
      'left the sibling''s 30 alone.', public.spend_today() - 10;
  end if;
  perform public.settle_budget(job_a, 'artwork');
  if public.spend_today() <> 10 then
    raise exception 'settling the sibling left % cents held', public.spend_today() - 10;
  end if;

  -- --------------------------- 5d. and a hold belongs to the day it was taken in
  --
  -- A hold taken at 23:58 for a call that stalls is still inside its one-hour TTL at
  -- 00:05. Counted, the new day opens with cents spent on it that belong to a day
  -- already closed out -- and a provider stall at the boundary produces several at
  -- once, so the first readers of the morning are refused for yesterday's ghosts.
  perform public.reserve_budget(job_a, 'artwork', 70);
  update public.budget_reservations
     set created_at = date_trunc('day', (now() at time zone 'utc')) at time zone 'utc'
                      - interval '2 minutes'
   where job_id = job_a and step = 'artwork';
  if public.spend_today() <> 10 then
    raise exception
      'a hold taken before midnight is counted against today (total %). The charge, if '
      'it lands, writes its ledger row on the day it lands.', public.spend_today();
  end if;
  delete from public.budget_reservations where job_id = job_a and step = 'artwork';

  -- ------------------------------------------------ 6. and the TTL is the backstop
  --
  -- If the sweep never runs, an ancient hold is ignored rather than believed for ever.
  perform public.reserve_budget(job_a, 'artwork', 50);
  update public.budget_reservations
     set created_at = now() - interval '2 hours'
   where job_id = job_a and step = 'artwork';
  if public.spend_today() <> 10 then
    raise exception
      'a two-hour-old hold is still counted (total %). Without a TTL one lost worker '
      'closes the budget until midnight.', public.spend_today();
  end if;
  delete from public.budget_reservations where job_id = job_a and step = 'artwork';

  raise notice 'spend_cap.sql: reservations hold, redeliver, settle and expire correctly';
end $$;

-- ------------------------------------------------- 7. what a reader may do
--
-- As `authenticated`, because grants and RLS are invisible to the owner.
do $$
declare
  reader     uuid;
  mine       uuid;
  theirs     uuid;
  other      uuid;
  refused    boolean;
  queued     jsonb;
  stored     jsonb;
  kept       text;
begin
  select u.id into reader from auth.users u
   where u.email like 'spend-cap%' order by u.email limit 1;
  select u.id into other from auth.users u
   where u.email like 'spend-cap%' and u.id <> reader limit 1;

  select w.id into mine from public.works w order by w.id limit 1;
  select w.id into theirs from public.works w order by w.id desc limit 1;

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', reader, 'role', 'authenticated')::text, true);

  if current_user <> 'authenticated' then
    raise exception 'these assertions must run as authenticated, not as %', current_user;
  end if;

  -- The reader may ask WHETHER there is budget, and not how much: 20260914010000
  -- argues a readable number tells somebody exactly how much to spend to close the
  -- door on everyone else, and then granted them the number. They may not reserve,
  -- settle, or insert a job row either.
  if public.generation_budget_state() not in ('open', 'low', 'spent') then
    raise exception 'generation_budget_state() answered something the client cannot read';
  end if;

  refused := false;
  begin
    perform public.spend_today();
  exception when insufficient_privilege then
    refused := true;
  end;
  if not refused then
    raise exception
      'a reader could read spend_today(). With daily_spend_cap_cents() beside it that '
      'is a live countdown to closing the day for everybody.';
  end if;

  refused := false;
  begin
    perform public.daily_spend_cap_cents();
  exception when insufficient_privilege then
    refused := true;
  end;
  if not refused then
    raise exception 'a reader could read the cap, which is the other half of the countdown.';
  end if;

  refused := false;
  begin
    perform public.reserve_budget(extensions.gen_random_uuid(), 'synthesize', 1);
  exception when insufficient_privilege then
    refused := true;
  end;
  if not refused then
    raise exception 'a reader could reserve budget. Anyone could starve the day at will.';
  end if;

  refused := false;
  begin
    perform public.settle_budget(extensions.gen_random_uuid(), 'synthesize');
  exception when insufficient_privilege then
    refused := true;
  end;
  if not refused then
    raise exception 'a reader could settle a reservation, and so release a hold at will.';
  end if;


  refused := false;
  begin
    insert into public.generation_jobs (requester_id, target, status)
    values (reader, '{"text":"x"}'::jsonb, 'queued');
  exception when insufficient_privilege then
    refused := true;
  end;
  if not refused then
    raise exception
      'a reader inserted a generation_jobs row directly. enqueue_generation_job is the '
      'only legitimate writer -- see 20260914010000.';
  end if;

  -- The budget table itself says nothing to a reader.
  if exists (select 1 from public.budget_reservations) then
    raise exception 'budget_reservations is readable through the API';
  end if;

  -- ---------------------------------------------------- the payload bounds
  refused := false;
  begin
    perform public.enqueue_generation_job('{"jobKind":"something_else","title":"x"}'::jsonb);
  exception when invalid_parameter_value then
    refused := true;
  end;
  if not refused then
    raise exception 'an unknown jobKind was accepted; the pipeline would never run it.';
  end if;

  refused := false;
  begin
    perform public.enqueue_generation_job(
      jsonb_build_object('title', repeat('t', 201), 'text', 'x'));
  exception when check_violation then
    refused := true;
  end;
  if not refused then
    raise exception 'a 201-character title was accepted; works.title is 200.';
  end if;

  refused := false;
  begin
    perform public.enqueue_generation_job(
      jsonb_build_object('title', 'ok', 'text', repeat('x', 200001)));
  exception when check_violation then
    refused := true;
  end;
  if not refused then
    raise exception 'a 200,001-character body was accepted; the pipeline truncates at 200,000.';
  end if;

  -- --------------------------------------- work_id survives only where it is theirs
  --
  -- The pipeline adopts `target.work_id` so an imported book gains a summary rather
  -- than a second `works` row. Adopting somebody else's would attach a reader's
  -- private generation to a work they have nothing to do with.
  queued := public.enqueue_generation_job(
    jsonb_build_object('jobKind', 'private_summary', 'title', 'Mine',
                       'text', 'x', 'work_id', theirs::text));
  select gj.target, gj.kind into stored, kept
  from public.generation_jobs gj where gj.id = (queued ->> 'jobId')::uuid;
  if stored ? 'work_id' then
    raise exception
      'a work the caller has authored nothing on survived into the target. The pipeline '
      'would adopt it.';
  end if;
  if kept <> 'private_summary' then
    raise exception 'generation_jobs.kind is % rather than the job kind that was asked for', kept;
  end if;

  -- Now author one, and the same call keeps it.
  insert into public.summaries (work_id, author_id, title, status, visibility, published_at)
  values (theirs, reader, 'A reader summary', 'published', 'private', now());

  queued := public.enqueue_generation_job(
    jsonb_build_object('jobKind', 'private_summary', 'title', 'Mine',
                       'text', 'x', 'work_id', theirs::text, 'visibility', 'public'));
  select gj.target into stored
  from public.generation_jobs gj where gj.id = (queued ->> 'jobId')::uuid;
  if (stored ->> 'work_id') <> theirs::text then
    raise exception
      'a work the caller authored a summary on was stripped from the target; an import '
      'would gain a second works row.';
  end if;
  -- `visibility` never survives, whoever sends it.
  if stored ? 'visibility' then
    raise exception 'a client-supplied visibility reached the job target.';
  end if;

  -- A malformed work_id is stripped rather than raised: it is a key the caller
  -- should not have sent, not an error they can act on.
  queued := public.enqueue_generation_job(
    jsonb_build_object('title', 'Mine', 'text', 'x', 'work_id', 'not-a-uuid'));
  if queued ->> 'jobId' is null then
    raise exception 'a malformed work_id failed the whole call';
  end if;

  raise notice 'spend_cap.sql: a reader may ask whether there is room and not how much, and may not reserve, settle or insert';
end $$;

-- ------------- 7b. a replayed submit returns the job it is replaying
--
-- A request that committed and whose response was lost leaves the Studio telling the
-- reader it never arrived. They press again, and without a mutation id that second press
-- is a second paid generation and a second summary of one book on their own shelf. Run
-- before the budget fixtures below spend the day, since the door refuses everything once
-- the cap is gone and there would be nothing left to replay.
do $$
declare
  reader  uuid;
  once    jsonb;
  twice   jsonb;
  mut     uuid := extensions.gen_random_uuid();
  jobs    int;
begin
  perform set_config('role', 'postgres', true);
  select u.id into reader from auth.users u
   where u.email like 'spend-cap%' order by u.email limit 1;

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', reader, 'role', 'authenticated')::text, true);

  once := public.enqueue_generation_job(
    jsonb_build_object('title', 'Replayed', 'text', 'x'), mut);
  twice := public.enqueue_generation_job(
    jsonb_build_object('title', 'Replayed', 'text', 'x'), mut);

  if (twice ->> 'jobId') <> (once ->> 'jobId') then
    raise exception
      'a replayed submit queued a second job (% then %). That is a second paid '
      'generation for one press.', once ->> 'jobId', twice ->> 'jobId';
  end if;
  if (twice ->> 'replayed')::boolean is not true then
    raise exception 'a replay was not reported as one, so the screen cannot tell';
  end if;

  /*
   * And it says where that job actually is. The first version answered `fast` / 0 for
   * every replay, and the Studio prints "Started." on exactly that — so a reader
   * replaying a staggered job was told a summary had begun that would not start for
   * another hour and a half.
   */
  declare
    staggered jsonb;
    late      uuid := extensions.gen_random_uuid();
  begin
    -- Past the free allowance, so the next job is genuinely delayed.
    for i in 1..4 loop
      perform public.enqueue_generation_job(
        jsonb_build_object('title', 'Filler ' || i, 'text', 'x'));
    end loop;

    -- Backdated, because `now()` is the TRANSACTION's clock: every row inserted in this
    -- block shares one `created_at`, and the placement is read from which jobs came
    -- before. A minute apart is what production gets for free.
    perform set_config('role', 'postgres', true);
    update public.generation_jobs set created_at = now() - interval '1 minute'
     where requester_id = reader;
    perform set_config('role', 'authenticated', true);
    perform set_config('request.jwt.claims',
      json_build_object('sub', reader, 'role', 'authenticated')::text, true);

    staggered := public.enqueue_generation_job(
      jsonb_build_object('title', 'Late', 'text', 'x'), late);
    if (staggered ->> 'queue') <> 'normal' or (staggered ->> 'delaySeconds')::int <= 0 then
      raise exception 'the fixture did not produce a staggered job: %', staggered;
    end if;

    staggered := public.enqueue_generation_job(
      jsonb_build_object('title', 'Late', 'text', 'x'), late);
    if (staggered ->> 'queue') <> 'normal' or (staggered ->> 'delaySeconds')::int <= 0 then
      raise exception
        'a replay of a staggered job reported %, so the screen says "Started." for a job '
        'that has not.', staggered;
    end if;
  end;

  select count(*) into jobs
  from public.generation_jobs gj
  where gj.requester_id = reader and gj.client_mutation_id = mut;
  if jobs <> 1 then
    raise exception 'one submission left % job rows', jobs;
  end if;

  -- A DIFFERENT id from the same reader is a different submission, not a replay.
  if (public.enqueue_generation_job(jsonb_build_object('title', 'Another', 'text', 'x'),
                                    extensions.gen_random_uuid()) ->> 'jobId')
     = (once ->> 'jobId') then
    raise exception 'a second submission was mistaken for a replay of the first';
  end if;

  /*
   * And a job that is OVER says so rather than reporting a place in the queue. The
   * Studio prints "Started." on `queue = 'fast'`, so a replay of a submit whose job had
   * since failed announced a summary that had already not happened.
   */
  perform set_config('role', 'postgres', true);
  update public.generation_jobs set status = 'failed', finished_at = now()
   where id = (once ->> 'jobId')::uuid;
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', reader, 'role', 'authenticated')::text, true);

  twice := public.enqueue_generation_job(
    jsonb_build_object('title', 'Replayed', 'text', 'x'), mut);
  if (twice ->> 'finished')::boolean is not true or (twice ->> 'status') <> 'failed' then
    raise exception
      'a replay of a job that had already failed answered %, so the screen says a summary '
      'has started.', twice;
  end if;

  raise notice 'spend_cap.sql: a replayed submit returns its job rather than buying another';
end $$;

-- ------------------------- 7c. the door counts the jobs it has already admitted
--
-- A job admitted and not yet started is neither charged nor held, so a door that asks
-- only `spend_today()` cannot see it. On an empty day it admitted every reader who asked,
-- and the jobs the day could not fund waited out the worker's day of budget waits and
-- failed under a screen that had said "Started." (20260926200000.) The door now refuses
-- at `spend + waiting + min > cap`. Waiting counts only jobs readers asked for, and no
-- reader's summaries for more than three jobs' worth (20260926210000). Every figure below
-- is derived from the functions that state it, not written in here. The catalogue's queued
-- backlog is left in place throughout.
--
-- Two refusals, and the difference is asserted every time. `spent` is spend alone leaving
-- no room, and keeps its sentence about midnight. `committed` is spend leaving room that
-- the waiting jobs take: DETAIL 'committed', a sentence that promises no hour, and a state
-- of its own from `generation_budget_state()`.
--
-- Each case is a probe: it sets up a day of its own, asserts, and raises 'probe done' so
-- that everything it did is rolled back before the next one.

/*
 * A day with exactly `p_charged` cents charged, nothing held and no reader's job waiting,
 * set up as the owner. The charge is on a finished job, so it is spend and not a job
 * waiting. The catalogue's queued backlog (20260907011000) is left where it is: it is not
 * a reader's, so the door must not count it, and every case below runs beside it.
 */
create or replace function pg_temp.door_day(p_charged numeric) returns void
language plpgsql as $fn$
declare
  paid uuid;
begin
  perform set_config('role', 'postgres', true);
  update public.generation_jobs set status = 'cancelled', finished_at = now()
   where status in ('queued', 'running') and requester_id is not null;
  delete from public.budget_reservations;
  delete from public.cost_ledger;
  insert into public.generation_jobs (target, status, finished_at)
  values ('{"text":"x"}'::jsonb, 'succeeded', now()) returning id into paid;
  insert into public.cost_ledger (job_id, provider, operation, unit, quantity, cost_cents)
  values (paid, 'test', 'synthesize', 'call', 1, p_charged);
  if public.spend_today() <> p_charged then
    raise exception 'the door fixture charged % and spend_today() says %',
      p_charged, public.spend_today();
  end if;
end $fn$;

/* A job for somebody else, staged as the owner in a state that is not a start. */
create or replace function pg_temp.door_stage(
  p_requester uuid, p_kind text, p_status text, p_state text default 'nothing'
) returns uuid
language plpgsql as $fn$
declare
  job      uuid;
  midnight timestamptz := date_trunc('day', (now() at time zone 'utc')) at time zone 'utc';
begin
  perform set_config('role', 'postgres', true);
  insert into public.generation_jobs (requester_id, kind, target, status, finished_at)
  values (p_requester, p_kind, '{"text":"x"}'::jsonb, p_status::public.job_status,
          case when p_status in ('succeeded', 'failed', 'cancelled') then now() end)
  returning id into job;
  case p_state
    when 'nothing' then null;
    -- A provider's 429: an attempt ledgered, at nothing.
    when 'a zero-cost attempt' then
      insert into public.cost_ledger (job_id, provider, operation, unit, quantity, cost_cents)
      values (job, 'test', 'synthesize', 'call', 1, 0);
    -- A hold taken today and handed back.
    when 'a settled hold' then
      insert into public.budget_reservations (job_id, step, reserved_cents, settled_at)
      values (job, 'synthesize', public.min_job_cents(), now());
    -- A hold older than the TTL and never settled: a worker that died holding it.
    when 'an expired hold' then
      insert into public.budget_reservations (job_id, step, reserved_cents, created_at)
      values (job, 'synthesize', public.min_job_cents(),
              now() - public.budget_reservation_ttl() - interval '1 minute');
    -- A hold taken before midnight, still open: yesterday's, not today's.
    when 'a hold from before midnight' then
      insert into public.budget_reservations (job_id, step, reserved_cents, created_at)
      values (job, 'synthesize', public.min_job_cents(), midnight - interval '2 minutes');
    -- A charge from before midnight, on a job still going: it has spent nothing today.
    when 'a charge from before midnight' then
      insert into public.cost_ledger
        (job_id, provider, operation, unit, quantity, cost_cents, created_at)
      values (job, 'test', 'synthesize', 'call', 1, public.min_job_cents(),
              midnight - interval '2 minutes');
    -- Started today, and holding one cent.
    when 'a cent held' then
      insert into public.budget_reservations (job_id, step, reserved_cents)
      values (job, 'embed', 1);
    -- Started today, and charged one cent.
    when 'a cent charged' then
      insert into public.cost_ledger (job_id, provider, operation, unit, quantity, cost_cents)
      values (job, 'test', 'embed', 'call', 1, 1);
    else
      raise exception 'no such staged state: %', p_state;
  end case;
  return job;
end $fn$;

/*
 * One submit, as whoever is signed in. NULL if it was admitted, otherwise which of the
 * door's two refusals it was, recognised by SQLSTATE, DETAIL and sentence together.
 * Anything else is raised: a refusal in the wrong words is a failure, not an answer.
 */
create or replace function pg_temp.door_refusal(p_title text, p_mutation uuid default null)
returns text
language plpgsql as $fn$
declare
  message text;
  detail  text;
begin
  perform public.enqueue_generation_job(
    jsonb_build_object('title', p_title, 'text', 'x'), p_mutation);
  return null;
exception when configuration_limit_exceeded then
  get stacked diagnostics message = message_text, detail = pg_exception_detail;
  if message = 'the daily generation budget is spent. Summaries resume at 00:00 UTC.'
     and coalesce(detail, '') = '' then
    return 'spent';
  end if;
  if message = 'today''s generation budget is committed to summaries already waiting to '
               'start. Try again in a little while.'
     and detail = 'committed' then
    return 'committed';
  end if;
  raise exception 'the door refused in words it does not use: % (detail %)', message, detail;
end $fn$;

/* One submit: true if admitted, false if the day refused it for either reason. */
create or replace function pg_temp.door_admits(p_title text, p_mutation uuid default null)
returns boolean
language plpgsql as $fn$
begin
  return pg_temp.door_refusal(p_title, p_mutation) is null;
end $fn$;

/*
 * As `p_reader`: the door admits exactly `p_room` more jobs, and the screen says there is
 * room (`open` or `low`) before each of them. After them the screen says `p_closed` and
 * the door refuses the next one with that same refusal.
 */
create or replace function pg_temp.door_admits_exactly(
  p_reader uuid, p_room int, p_case text, p_closed text default 'committed'
) returns void
language plpgsql as $fn$
declare
  refusal text;
begin
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_reader, 'role', 'authenticated')::text, true);
  if current_user <> 'authenticated' then
    raise exception 'the door must be asked as a reader, not as %', current_user;
  end if;

  for i in 1..p_room loop
    if public.generation_budget_state() not in ('open', 'low') then
      raise exception
        '%: with % admitted and not started, the screen said % though the day has room '
        'for %', p_case, i - 1, public.generation_budget_state(), p_room;
    end if;
    refusal := pg_temp.door_refusal(p_case || ' ' || i);
    if refusal is not null then
      raise exception '%: job % was refused as %, though the day has room for %',
        p_case, i, refusal, p_room;
    end if;
  end loop;

  if public.generation_budget_state() is distinct from p_closed then
    raise exception
      '%: with % admitted and not started the day has no room left, and the screen said % '
      'rather than %.', p_case, p_room, public.generation_budget_state(), p_closed;
  end if;
  refusal := pg_temp.door_refusal(p_case || ' one too many');
  if refusal is null then
    raise exception
      '%: with % admitted and not started, the door admitted one more. The day cannot '
      'fund it, so it waits a day in the worker''s budget wait and then fails, under a '
      'screen that said "Started."', p_case, p_room;
  end if;
  if refusal is distinct from p_closed then
    raise exception '%: the door refused as % where the day is %', p_case, refusal, p_closed;
  end if;
end $fn$;

do $$
declare
  cap      numeric;
  least_   numeric;
  s_least  numeric;
  share    numeric;
  reader   uuid := extensions.gen_random_uuid();
  other    uuid := extensions.gen_random_uuid();
  third    uuid := extensions.gen_random_uuid();
  charged  numeric;
  state    text;
  kind     text;
  courses  int;
  spent_s  numeric;
  job      uuid;
  mut      uuid := extensions.gen_random_uuid();
  first    jsonb;
  again    jsonb;
  rows_    int;
begin
  perform set_config('role', 'postgres', true);
  cap := public.daily_spend_cap_cents();
  least_ := public.min_job_cents();
  s_least := public.study_min_job_cents();
  share := public.study_requester_daily_cap_cents();
  if least_ <= 0 or cap < 5 * least_ + 1 then
    raise exception 'a cap of % cannot fund five jobs of %, so these cases mean nothing',
      cap, least_;
  end if;
  if s_least <= 0 or s_least = least_ or share < s_least or cap < 2 * share + least_ then
    raise exception 'a study share of %, a study floor of % and a cap of % do not leave '
      'room for the study cases', share, s_least, cap;
  end if;
  if ceil(cap * 0.8) + least_ > cap then
    raise exception 'a cap of % has no `low` band a job fits in', cap;
  end if;

  insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                          email_confirmed_at, created_at, updated_at,
                          raw_app_meta_data, raw_user_meta_data, is_anonymous)
  select u, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
         'door-count' || left(u::text, 8) || '@example.test', '', now(), now(), now(),
         '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb, false
  from unnest(array[reader, other, third]) as u;

  -- 1. The boundary, from both sides. With N admitted and not started, the next is refused
  --    exactly when spend + (N + 1) x min > cap: at three jobs' room it takes three, a cent
  --    less takes two, and a cent more still takes three. Spend alone leaves room in every
  --    one of these, so the day is committed, not spent.
  foreach charged in array array[cap - 3 * least_, cap - 3 * least_ + 1, cap - 3 * least_ - 1]
  loop
    begin
      perform pg_temp.door_day(charged);
      perform pg_temp.door_admits_exactly(reader, floor((cap - charged) / least_)::int,
                                          format('%s of %s charged', charged, cap));
      raise exception using errcode = 'P0001', message = 'probe done';
    exception when raise_exception then
      if sqlerrm is distinct from 'probe done' then raise; end if;
    end;
  end loop;

  -- 1b. Where committed ends and spent begins. With exactly one job's room left by spend,
  --     the job admitted into it makes the day committed: the door says "in a little
  --     while", because that room comes back if the job fails early. A cent more spent and
  --     there is no room for it to come back to: spent, and the sentence about midnight.
  begin
    perform pg_temp.door_day(cap - least_);
    perform pg_temp.door_admits_exactly(reader, 1, 'one job''s room', 'committed');
    raise exception using errcode = 'P0001', message = 'probe done';
  exception when raise_exception then
    if sqlerrm is distinct from 'probe done' then raise; end if;
  end;
  begin
    perform pg_temp.door_day(cap - least_ + 1);
    perform pg_temp.door_admits_exactly(reader, 0, 'a cent short of one job', 'spent');
    raise exception using errcode = 'P0001', message = 'probe done';
  exception when raise_exception then
    if sqlerrm is distinct from 'probe done' then raise; end if;
  end;

  -- 2. A job that has not started is waiting, whatever it has been through, and of either
  --    summary kind. Each is staged on a day with room for two: counted, it leaves room
  --    for one.
  foreach kind in array array['canonical_summary', 'private_summary'] loop
    foreach state in array array['nothing', 'a zero-cost attempt', 'a settled hold',
                                 'an expired hold', 'a hold from before midnight',
                                 'a charge from before midnight']
    loop
      begin
        perform pg_temp.door_day(cap - 2 * least_);
        perform pg_temp.door_stage(other, kind, 'running', state);
        if public.spend_today() <> cap - 2 * least_ then
          raise exception 'a job with % moved today''s spend to %', state, public.spend_today();
        end if;
        perform pg_temp.door_admits_exactly(reader, 1,
          format('beside a %s with %s', kind, state));
        raise exception using errcode = 'P0001', message = 'probe done';
      exception when raise_exception then
        if sqlerrm is distinct from 'probe done' then raise; end if;
      end;
    end loop;
  end loop;

  -- 2b. And the hold from before midnight is yesterday's because of the DAY bound, not
  --     only because it has aged out. With the default one-hour TTL the two agree for all
  --     but the first hour of the day, so the TTL is widened to two days inside this probe
  --     alone -- and rolled back with it -- to hold the day bound to account by itself.
  begin
    perform set_config('role', 'postgres', true);
    create or replace function public.budget_reservation_ttl()
    returns interval
    language sql
    immutable
    set search_path = ''
    as 'select interval ''2 days''';
    perform pg_temp.door_day(cap - 2 * least_);
    perform pg_temp.door_stage(other, 'canonical_summary', 'running',
                               'a hold from before midnight');
    perform pg_temp.door_admits_exactly(reader, 1,
      'beside a job holding since before midnight, under a two-day TTL');
    raise exception using errcode = 'P0001', message = 'probe done';
  exception when raise_exception then
    if sqlerrm is distinct from 'probe done' then raise; end if;
  end;
  perform set_config('role', 'postgres', true);
  if public.budget_reservation_ttl() <> interval '1 hour' then
    raise exception 'the widened TTL outlived its probe: %', public.budget_reservation_ttl();
  end if;

  -- 3. A job that HAS started counts at what it holds or has been charged, which today's
  --    spend already includes. It does not count again at the floor. One cent held and one
  --    cent charged leave room for exactly two. Counted twice, they would leave room for
  --    none.
  begin
    perform pg_temp.door_day(cap - 2 * least_ - 2);
    perform pg_temp.door_stage(other, 'canonical_summary', 'running', 'a cent held');
    perform pg_temp.door_stage(other, 'private_summary', 'running', 'a cent charged');
    if public.spend_today() <> cap - 2 * least_ then
      raise exception 'the fixture for started jobs did not take; spend_today() is %',
        public.spend_today();
    end if;
    perform pg_temp.door_admits_exactly(reader, 2, 'beside two started jobs');
    raise exception using errcode = 'P0001', message = 'probe done';
  exception when raise_exception then
    if sqlerrm is distinct from 'probe done' then raise; end if;
  end;

  -- 4. A finished job waits for nothing, however it finished.
  begin
    perform pg_temp.door_day(cap - 2 * least_);
    foreach state in array array['succeeded', 'failed', 'cancelled'] loop
      perform pg_temp.door_stage(other, 'canonical_summary', state);
    end loop;
    perform pg_temp.door_admits_exactly(reader, 2, 'beside finished jobs');
    raise exception using errcode = 'P0001', message = 'probe done';
  exception when raise_exception then
    if sqlerrm is distinct from 'probe done' then raise; end if;
  end;

  -- 5. No reader's summaries hold more than three jobs' worth of the day. Eleven of them
  --    waiting -- what one account can queue in a minute, each failing for nothing when it
  --    runs -- count as three, so on a day with room for five a second reader gets the
  --    other two. Counted in full they would close the door on everyone for hours.
  begin
    perform pg_temp.door_day(cap - 5 * least_);
    for i in 1..11 loop
      perform pg_temp.door_stage(other, 'canonical_summary', 'queued');
    end loop;
    perform pg_temp.door_admits_exactly(reader, 2, 'beside one reader''s eleven');
    raise exception using errcode = 'P0001', message = 'probe done';
  exception when raise_exception then
    if sqlerrm is distinct from 'probe done' then raise; end if;
  end;
  --    And on an otherwise empty day, a reader beside those eleven is simply admitted, and
  --    is told there is room.
  begin
    perform pg_temp.door_day(0);
    for i in 1..11 loop
      perform pg_temp.door_stage(other, 'private_summary', 'queued');
    end loop;
    perform set_config('role', 'authenticated', true);
    perform set_config('request.jwt.claims',
      json_build_object('sub', reader, 'role', 'authenticated')::text, true);
    if public.generation_budget_state() is distinct from 'open' then
      raise exception 'beside one reader''s eleven waiting jobs, an empty day reads %',
        public.generation_budget_state();
    end if;
    if not pg_temp.door_admits('Beside the eleven') then
      raise exception 'one reader''s eleven waiting jobs closed an empty day to another';
    end if;
    raise exception using errcode = 'P0001', message = 'probe done';
  exception when raise_exception then
    if sqlerrm is distinct from 'probe done' then raise; end if;
  end;

  -- 6. A waiting study course counts at the STUDY floor, not the summary one. One course
  --    on a day with a course and a summary's room left admits one summary; a cent less
  --    room admits none.
  foreach charged in array array[cap - s_least - least_, cap - s_least - least_ + 1] loop
    begin
      perform pg_temp.door_day(charged);
      perform pg_temp.door_stage(other, 'study_course', 'queued');
      perform pg_temp.door_admits_exactly(reader, floor((cap - charged - s_least) / least_)::int,
        format('beside one waiting course, %s of %s charged', charged, cap));
      raise exception using errcode = 'P0001', message = 'probe done';
    exception when raise_exception then
      if sqlerrm is distinct from 'probe done' then raise; end if;
    end;
  end loop;

  -- 6b. But a reader's courses count for no more than that reader's study share can still
  --     fund. More courses than the share can start count as the share, and a share partly
  --     spent today (by a course that has started) counts as what is left of it. Either
  --     way this day has room for exactly one summary.
  courses := floor(share / s_least)::int + 2;
  foreach spent_s in array array[0, s_least] loop
    begin
      perform pg_temp.door_day(cap - share - least_);
      for i in 1..courses loop
        perform pg_temp.door_stage(other, 'study_course', 'queued');
      end loop;
      if spent_s > 0 then
        job := pg_temp.door_stage(other, 'study_course', 'running');
        insert into public.cost_ledger (job_id, provider, operation, unit, quantity, cost_cents)
        values (job, 'test', 'study_extract', 'call', 1, spent_s);
      end if;
      perform pg_temp.door_admits_exactly(reader, 1,
        format('beside %s waiting courses, %s of the share spent', courses, spent_s));
      raise exception using errcode = 'P0001', message = 'probe done';
    exception when raise_exception then
      if sqlerrm is distinct from 'probe done' then raise; end if;
    end;
  end loop;

  -- 6c. And the share is EACH reader's, not one for everybody. Two readers each with more
  --     courses waiting than their share can start count as two shares.
  begin
    perform pg_temp.door_day(cap - 2 * share - least_);
    for i in 1..courses loop
      perform pg_temp.door_stage(other, 'study_course', 'queued');
      perform pg_temp.door_stage(third, 'study_course', 'queued');
    end loop;
    perform pg_temp.door_admits_exactly(reader, 1,
      format('beside two readers'' %s waiting courses each', courses));
    raise exception using errcode = 'P0001', message = 'probe done';
  exception when raise_exception then
    if sqlerrm is distinct from 'probe done' then raise; end if;
  end;

  -- 7. `low` is four fifths of the day spent OR COMMITTED. A day spent a job short of it,
  --    with one job waiting, is low; the same day without the waiting job is open.
  begin
    perform pg_temp.door_day(ceil(cap * 0.8) - least_);
    perform set_config('role', 'authenticated', true);
    perform set_config('request.jwt.claims',
      json_build_object('sub', reader, 'role', 'authenticated')::text, true);
    if public.generation_budget_state() is distinct from 'open' then
      raise exception 'a day spent short of four fifths, with nothing waiting, reads %',
        public.generation_budget_state();
    end if;
    perform pg_temp.door_stage(other, 'canonical_summary', 'queued');
    perform set_config('role', 'authenticated', true);
    if public.generation_budget_state() is distinct from 'low' then
      raise exception
        'a day with four fifths of it spent or committed reads %. The warning has to come '
        'from what the day has agreed to, not only from what it has spent.',
        public.generation_budget_state();
    end if;
    raise exception using errcode = 'P0001', message = 'probe done';
  exception when raise_exception then
    if sqlerrm is distinct from 'probe done' then raise; end if;
  end;

  -- 8. The catalogue's jobs are not a reader's, and do not close the door to one. More
  --    of them queued than the whole day could fund, plus one that has attempted and been
  --    ledgered at nothing, leave a day with room for two admitting exactly two. The
  --    reservation, not the door, is what stops them and the readers together passing the
  --    cap.
  begin
    perform pg_temp.door_day(cap - 2 * least_);
    for i in 1..(floor(cap / least_)::int + 1) loop
      perform pg_temp.door_stage(null, 'canonical_summary', 'queued');
    end loop;
    perform pg_temp.door_stage(null, 'canonical_summary', 'running', 'a zero-cost attempt');
    perform pg_temp.door_admits_exactly(reader, 2, 'beside a day''s worth of catalogue');
    raise exception using errcode = 'P0001', message = 'probe done';
  exception when raise_exception then
    if sqlerrm is distinct from 'probe done' then raise; end if;
  end;

  -- 9. A replay is still a replay on a full day. It is answered before the day is asked,
  --    because it spends nothing: it returns the job that was already admitted.
  begin
    perform pg_temp.door_day(cap - least_);
    perform set_config('role', 'authenticated', true);
    perform set_config('request.jwt.claims',
      json_build_object('sub', reader, 'role', 'authenticated')::text, true);

    first := public.enqueue_generation_job(
      jsonb_build_object('title', 'The last room', 'text', 'x'), mut);
    if pg_temp.door_refusal('After the last room', extensions.gen_random_uuid())
       is distinct from 'committed' then
      raise exception
        'the last room was taken by a job not yet started, and the door did not say the '
        'day is committed.';
    end if;
    again := public.enqueue_generation_job(
      jsonb_build_object('title', 'The last room', 'text', 'x'), mut);
    if (again ->> 'replayed')::boolean is not true
       or (again ->> 'jobId') is distinct from (first ->> 'jobId') then
      raise exception 'a replay on a full day answered % rather than the job %',
        again, first ->> 'jobId';
    end if;
    if (again ->> 'budget') is distinct from 'committed' then
      raise exception 'a replay on a committed day reported the budget as %',
        again ->> 'budget';
    end if;
    perform set_config('role', 'postgres', true);
    select count(*) into rows_ from public.generation_jobs gj
     where gj.requester_id = reader and gj.client_mutation_id = mut;
    if rows_ <> 1 then
      raise exception 'one submission and its replay left % job rows', rows_;
    end if;
    raise exception using errcode = 'P0001', message = 'probe done';
  exception when raise_exception then
    if sqlerrm is distinct from 'probe done' then raise; end if;
  end;

  raise notice 'spend_cap.sql: the door counts what readers asked for and it has not '
    'started, once, at the least it reserves and at most three jobs'' worth a reader, and '
    'says whether the day is spent or only committed';
end $$;

-- ------------------------------------------- 8. a spent day refuses at the door
--
-- Back to the owner, because the fixture writes a ledger row and then the assertion
-- has to be made as a reader.
do $$
declare
  reader uuid;
  job    uuid;
begin
  -- Back to the owner. `set_config(..., true)` is transaction-local, not block-local,
  -- so the previous block's `authenticated` is still in force here and `auth.users` is
  -- not readable by it.
  perform set_config('role', 'postgres', true);

  select u.id into reader from auth.users u
   where u.email like 'spend-cap%' order by u.email limit 1;

  insert into public.generation_jobs (requester_id, target, status)
  values (reader, '{"text":"x"}'::jsonb, 'running') returning id into job;

  -- The whole cap, charged.
  perform public.record_job_step(
    job, 'synthesize', 1, 'stub', 'v1', 1, 1,
    public.daily_spend_cap_cents(), 5, 'stub', true, null
  );
end $$;

do $$
declare
  reader  uuid;
  refused boolean := false;
begin
  select u.id into reader from auth.users u
   where u.email like 'spend-cap%' order by u.email limit 1;

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', reader, 'role', 'authenticated')::text, true);

  begin
    perform public.enqueue_generation_job('{"title":"After the budget","text":"x"}'::jsonb);
  exception when configuration_limit_exceeded then
    refused := true;
  end;
  if not refused then
    raise exception
      'a job was enqueued after the day''s whole budget was charged. The cap is the one '
      'bound the per-requester quotas cannot express.';
  end if;

  raise notice 'spend_cap.sql: a spent day refuses at the door rather than queueing a wait';
end $$;

-- ------------------- 9. and a day with less than one job left refuses too
--
-- The door and the reservation have to agree. `spent >= cap` let a job in at 196 of 200,
-- told the reader "Started. 46 more today.", and then `reserve_budget` refused it -- so
-- it parked in the 24-hour budget wait with the screen saying it had begun. Every job
-- enqueued in the last few cents of a day behaved that way.
--
-- TEN CENTS LEFT, deliberately: enough that `spent >= cap` is false, more than the seven
-- the door used to ask for, and less than the seventeen it asks for now that `synthesize`
-- reserves the provider's own worst case rather than the expected cost of a Gemini call.
-- Four cents -- what this used to wind the day back to -- is refused by both thresholds,
-- so it could not tell them apart.
--
-- And the SCREEN has to say the same thing, which is the second half below. A door that
-- refuses while `generation_budget_state()` still answers `low` is a live submit button
-- over a day that is over: the reader finds out by being turned away, once per press.
do $$
declare
  reader uuid;
  job    uuid;
begin
  perform set_config('role', 'postgres', true);
  select u.id into reader from auth.users u
   where u.email like 'spend-cap%' order by u.email limit 1;

  -- Wind the day back to ten cents left: `spent >= cap` is false, and ten is less than
  -- the seventeen a job reserves before it can run.
  delete from public.cost_ledger;
  insert into public.generation_jobs (requester_id, target, status)
  values (reader, '{"text":"x"}'::jsonb, 'running') returning id into job;
  perform public.record_job_step(
    job, 'synthesize', 1, 'stub', 'v1', 1, 1,
    public.daily_spend_cap_cents() - 10, 5, 'stub', true, null
  );
end $$;

do $$
declare
  reader  uuid;
  refused boolean := false;
begin
  select u.id into reader from auth.users u
   where u.email like 'spend-cap%' order by u.email limit 1;

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', reader, 'role', 'authenticated')::text, true);

  begin
    perform public.enqueue_generation_job('{"title":"Ten cents left","text":"x"}'::jsonb);
  exception when configuration_limit_exceeded then
    refused := true;
  end;
  if not refused then
    raise exception
      'a job was accepted with ten cents left, which is less than the seventeen it will '
      'reserve. It would park in a 24-hour wait under a screen saying it had started.';
  end if;

  -- The same moment, read by the client. `generation_budget_state()` is the only budget
  -- figure a reader gets, and the Studio draws its submit button from it -- so if it
  -- still answers `low` here, the screen is offering something the door will refuse.
  if public.generation_budget_state() <> 'spent' then
    raise exception
      'the door refused this day but generation_budget_state() reported %. The Studio '
      'would show "nearly used up" and a live button over a day that cannot fund a job.',
      public.generation_budget_state();
  end if;

  raise notice 'spend_cap.sql: the door refuses what the reservation could not grant, '
    'and the screen says so';
end $$;

-- ------------------------ 10. a malformed target is refused, not raised from within
--
-- Every other refusal in `enqueue_generation_job` is a sentence the caller can act on.
-- A jsonb SCALAR -- what `{"p_target": "hello"}` sends through PostgREST -- passed every
-- `->>` as NULL and then reached `target - 'visibility'`, where Postgres raises
-- `cannot delete from scalar`: a 500 out of the internals of a function the caller
-- cannot read. 20260914040000 refuses it at the top instead.
do $$
declare
  reader  uuid;
  refused text := null;
begin
  perform set_config('role', 'postgres', true);
  select u.id into reader from auth.users u
   where u.email like 'spend-cap%' order by u.email limit 1;

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', reader, 'role', 'authenticated')::text, true);

  begin
    perform public.enqueue_generation_job('"hello"'::jsonb);
  exception when others then
    refused := sqlerrm;
  end;

  if refused is null then
    raise exception 'a jsonb scalar was accepted as a generation target';
  end if;
  if refused like '%delete from scalar%' then
    raise exception
      'a malformed target still raises from inside the function: %. The caller gets a '
      'stack trace where every other bad shape gets a sentence.', refused;
  end if;
  if refused not like '%must be an object%' then
    raise exception 'a malformed target was refused, but not in terms a caller can read: %',
      refused;
  end if;

  /*
   * `null` and `'{}'` are NOT asserted here, and deliberately: by this point sections 8
   * and 9 have charged the day's whole cap inside this transaction, so an acceptable
   * target is refused for the budget rather than accepted. `coalesce(p_target, '{}')`
   * runs before the new guard and `jsonb_typeof('{}')` is `object`, so the shape the
   * guard must not break is the one every other section of this file enqueues with.
   */
  raise notice 'spend_cap.sql: a malformed target is refused in the same voice as the others';
end $$;

-- ----------------- 11. a hold still in use is not stranded, however dead its job is
--
-- `graph.ts` runs `extract_evidence` beside `synthesize` and `artwork` beside `embed`,
-- in separate invocations. So the instant one step exhausts its retries and fails the
-- JOB, a sibling can still be inside its provider call holding a live reservation --
-- and a terminal-status sweep that keys on status alone hands that money back before
-- the charge arrives. The sweep now leaves a hold younger than its own threshold alone.
do $$
declare
  reader   uuid;
  job      uuid;
  open_now int;
begin
  perform set_config('role', 'postgres', true);

  select u.id into reader from auth.users u
   where u.email like 'spend-cap%' order by u.email limit 1;

  insert into public.generation_jobs (requester_id, target, status, finished_at)
  values (reader, '{"text":"x"}'::jsonb, 'failed', now()) returning id into job;

  -- A sibling that reserved a second ago and is still calling its provider.
  insert into public.budget_reservations (job_id, step, reserved_cents, created_at)
  values (job, 'synthesize', 6, now());

  perform public.sweep_stranded_generation_jobs();

  select count(*) into open_now
  from public.budget_reservations br
  where br.job_id = job and br.settled_at is null;
  if open_now <> 1 then
    raise exception
      'the sweep released a hold taken seconds ago on a job that had just failed. The '
      'step holding it is still mid-call, and its charge will land against a total '
      'this pass made short by exactly that amount.';
  end if;

  -- The same row, once it is genuinely older than the threshold.
  update public.budget_reservations br
     set created_at = now() - interval '30 minutes'
   where br.job_id = job;

  perform public.sweep_stranded_generation_jobs();

  select count(*) into open_now
  from public.budget_reservations br
  where br.job_id = job and br.settled_at is null;
  if open_now <> 0 then
    raise exception
      'the sweep left a half-hour-old hold open on a terminal job. Nothing will ever '
      'record for it, so it is money held against the cap for a charge that cannot come.';
  end if;

  raise notice 'spend_cap.sql: the sweep settles a stranded hold and leaves a live one alone';
end $$;

rollback;
