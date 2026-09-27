-- Flashcards: a reader's own sets, their cards, and the two doors that write them.
--
-- What must hold, and under which role it is asserted:
--
--   as `authenticated` (RLS and grants in force)
--     * a save creates the set under the client's id, with the cards in the order sent; the
--       same save again is the same set and changes nothing
--     * a later save keeps the id of every card it names, updates its term, definition and
--       place, inserts the cards it does not know and deletes the ones it leaves out
--     * a card id from another set -- the reader's own or someone else's -- is refused and
--       never moved
--     * `updated_at` moves only when something changed, and whenever anything did: a card
--       deleted, a card added, the description
--     * a save that names the version it started from is refused when the set has changed
--       since, and when it is gone, so a stale screen neither saves over nor resurrects --
--       to the microsecond, and only when it would change something, so a retried save whose
--       answer was lost is made as nothing rather than refused
--     * another reader sees none of it, and cannot save into it or delete it: the same
--       answers a set that is not there would give
--     * no table here takes a direct write, and anon can read neither
--     * a guest is refused, as is a caller with no reader or with a reader who is gone
--     * every class of malformed input is refused with 22023, and every limit with 54000
--       and a detail saying which: sets, cards, size and total
--     * blank is one thing -- JavaScript's `.trim()` -- in the function and in the tables
--     * both doors take the reader's lock inside the caller's transaction
--     * deleting a set takes its cards; deleting the account takes both
--
-- Read-only in effect: everything below rolls back.
\set ON_ERROR_STOP on
begin;

create or replace function pg_temp.assert_is_reader() returns void
language plpgsql as $fn$
begin
  if current_user <> 'authenticated' then
    raise exception
      'assertions must run as the reader, not as %. RLS is invisible to an '
      'owner-role query, so this file would be proving nothing.', current_user;
  end if;
end $fn$;

create or replace function pg_temp.become_reader(p_uid uuid, p_guest boolean default false)
returns void language plpgsql as $fn$
begin
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_uid, 'role', 'authenticated', 'is_anonymous', p_guest)::text,
    true);
  perform pg_temp.assert_is_reader();
end $fn$;

create or replace function pg_temp.as_owner()
returns void language plpgsql as $fn$
begin
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);
end $fn$;

/*
 * What a statement was refused with: its SQLSTATE, and its DETAIL after a slash when it has
 * one -- or `ok` when it was not refused at all. Every refusal below is asserted as the pair,
 * since 42501 and 54000 each carry more than one meaning here.
 */
create or replace function pg_temp.refusal(p_sql text)
returns text language plpgsql as $fn$
declare
  v_state  text;
  v_detail text;
begin
  execute p_sql;
  return 'ok';
exception when others then
  get stacked diagnostics v_state = returned_sqlstate, v_detail = pg_exception_detail;
  return v_state || coalesce('/' || nullif(v_detail, ''), '');
end $fn$;

/* A payload for `save_flashcard_set`, as text for `refusal` to run. */
create or replace function pg_temp.save_sql(p_set jsonb)
returns text language sql as $fn$
  select format('select public.save_flashcard_set(%L::jsonb)', p_set::text)
$fn$;

/*
 * Whether this session holds the reader's flashcard lock -- the advisory lock both doors take
 * on `flashcards:<uid>`, as `pg_locks` shows a bigint key: its high half in `classid`, its
 * low half in `objid`, and `objsubid` 1.
 */
create or replace function pg_temp.holds_reader_lock(p_uid uuid)
returns boolean language sql as $fn$
  select exists (
    select 1 from pg_locks l
    where l.locktype = 'advisory' and l.pid = pg_backend_pid() and l.objsubid = 1
      and ((l.classid::bigint << 32) | l.objid::bigint)
          = pg_catalog.hashtextextended('flashcards:' || p_uid::text, 0))
$fn$;

grant execute on function pg_temp.assert_is_reader() to authenticated, anon;
grant execute on function pg_temp.become_reader(uuid, boolean) to authenticated, anon;
grant execute on function pg_temp.as_owner() to authenticated, anon;
grant execute on function pg_temp.refusal(text) to authenticated, anon;
grant execute on function pg_temp.save_sql(jsonb) to authenticated, anon;
grant execute on function pg_temp.holds_reader_lock(uuid) to authenticated, anon;

do $test$
declare
  reader_a  uuid := extensions.gen_random_uuid();
  reader_b  uuid := extensions.gen_random_uuid();
  -- A reader nothing runs for until the lock is looked for.
  reader_c  uuid := extensions.gen_random_uuid();
  guest     uuid := extensions.gen_random_uuid();
  set_a     uuid := extensions.gen_random_uuid();
  set_a2    uuid := extensions.gen_random_uuid();
  set_b     uuid := extensions.gen_random_uuid();
  set_big   uuid := extensions.gen_random_uuid();
  filler    uuid := extensions.gen_random_uuid();
  c1        uuid := extensions.gen_random_uuid();
  c2        uuid := extensions.gen_random_uuid();
  c3        uuid := extensions.gen_random_uuid();
  c5        uuid := extensions.gen_random_uuid();
  b1        uuid := extensions.gen_random_uuid();
  minted    uuid;
  minted2   uuid;
  first     jsonb;
  five      jsonb;
  big       jsonb;
  payload   jsonb;
  locked    boolean;
  out       jsonb;
  got       text;
  rows      text;
  n         bigint;
  stamp     timestamptz;
  ok_set    jsonb;
begin
  insert into auth.users
    (id, instance_id, aud, role, email, encrypted_password,
     email_confirmed_at, created_at, updated_at, is_anonymous,
     raw_app_meta_data, raw_user_meta_data)
  values
    (reader_a, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
     'flashcards-a-' || left(reader_a::text, 8) || '@example.test', '', now(), now(), now(),
     false, '{"provider":"email","providers":["email"]}', '{}'),
    (reader_b, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
     'flashcards-b-' || left(reader_b::text, 8) || '@example.test', '', now(), now(), now(),
     false, '{"provider":"email","providers":["email"]}', '{}'),
    (reader_c, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
     'flashcards-c-' || left(reader_c::text, 8) || '@example.test', '', now(), now(), now(),
     false, '{"provider":"email","providers":["email"]}', '{}'),
    (guest, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
     null, '', null, now(), now(), true,
     '{"provider":"anonymous","providers":["anonymous"]}', '{}');

  -- ---------------------------------------------------------------- a set is made
  perform pg_temp.become_reader(reader_a);
  first := jsonb_build_object(
    'id', set_a, 'title', '  Spanish verbs  ', 'description', 'Irregular, present tense.',
    'termLang', 'es', 'definitionLang', 'en',
    'cards', jsonb_build_array(
      jsonb_build_object('id', c1, 'term', 'ser', 'definition', 'to be (lasting)'),
      jsonb_build_object('id', c2, 'term', 'estar', 'definition', 'to be (for now)'),
      jsonb_build_object('id', c3, 'term', 'ir', 'definition', 'to go'),
      -- No id: the server gives it one.
      jsonb_build_object('term', 'tener', 'definition', E'to have\n(and to be, of age)')));
  out := public.save_flashcard_set(first);
  minted := (out -> 'cards' -> 3 ->> 'id')::uuid;
  if (out ->> 'id')::uuid is distinct from set_a
     or jsonb_array_length(out -> 'cards') <> 4
     or (out -> 'cards' -> 0 ->> 'id')::uuid is distinct from c1
     or (out -> 'cards' -> 2 ->> 'id')::uuid is distinct from c3
     or (out -> 'cards' -> 3 ->> 'position')::int <> 3
     or minted is null or minted in (c1, c2, c3)
     or out ->> 'updatedAt' is null then
    raise exception 'a new set did not come back as sent: %', out;
  end if;

  select string_agg(term || '@' || position, ',' order by position) into rows
  from public.flashcards where set_id = set_a;
  if rows is distinct from 'ser@0,estar@1,ir@2,tener@3' then
    raise exception 'the cards are not in the order sent: %', rows;
  end if;
  if not exists (select 1 from public.flashcard_sets
                 where id = set_a and owner_id = reader_a and title = 'Spanish verbs'
                   and term_lang = 'es' and definition_lang = 'en') then
    raise exception 'the set was not stored trimmed and whole';
  end if;

  -- The same save again, naming card 4 by the id the server gave it: the same set, nothing
  -- new. Not a verbatim retry -- sent again without that id, card 4 would be made twice --
  -- which is why the web mints every id itself, and this proves only the ids a client mints.
  out := public.save_flashcard_set(first || jsonb_build_object('cards',
    jsonb_set(first -> 'cards', '{3}', (first -> 'cards' -> 3) || jsonb_build_object('id', minted))));
  if (out ->> 'id')::uuid is distinct from set_a
     or (select count(*) from public.flashcard_sets) <> 1
     or (select count(*) from public.flashcards) <> 4
     or (out -> 'cards' -> 3 ->> 'id')::uuid is distinct from minted then
    raise exception 'a retried save was not the same set: %', out;
  end if;

  -- ---------------------------------------------------------------- updated_at, and only on change
  perform pg_temp.as_owner();
  update public.flashcard_sets set updated_at = '2000-01-01' where id = set_a;
  update public.flashcards set updated_at = '2000-01-01' where set_id = set_a;
  perform pg_temp.become_reader(reader_a);
  out := public.save_flashcard_set(first || jsonb_build_object('cards',
    jsonb_set(first -> 'cards', '{3}', (first -> 'cards' -> 3) || jsonb_build_object('id', minted))));
  if (select updated_at from public.flashcard_sets where id = set_a) <> '2000-01-01'
     or exists (select 1 from public.flashcards where set_id = set_a
                and updated_at <> '2000-01-01') then
    raise exception 'saving an unchanged set moved its updated_at';
  end if;
  out := public.save_flashcard_set(first || jsonb_build_object('title', 'Spanish verbs, I',
    'cards', jsonb_set(first -> 'cards', '{3}',
                       (first -> 'cards' -> 3) || jsonb_build_object('id', minted))));
  if (select updated_at from public.flashcard_sets where id = set_a) <> now()
     or (select title from public.flashcard_sets where id = set_a) <> 'Spanish verbs, I'
     or exists (select 1 from public.flashcards where set_id = set_a
                and updated_at <> '2000-01-01') then
    raise exception 'a new title did not move the set''s updated_at, or moved its cards''';
  end if;

  -- ---------------------------------------------------------------- an edit keeps ids
  perform pg_temp.as_owner();
  update public.flashcard_sets set updated_at = '2000-01-01' where id = set_a;
  perform pg_temp.become_reader(reader_a);
  -- `ir` first, `ser` renamed and second, `estar` gone, `tener` kept, and two new: one with
  -- the client's id and one without.
  out := public.save_flashcard_set(jsonb_build_object(
    'id', set_a, 'title', 'Spanish verbs, I', 'description', 'Irregular, present tense.',
    'termLang', 'es', 'definitionLang', 'en',
    'cards', jsonb_build_array(
      jsonb_build_object('id', c3, 'term', 'ir', 'definition', 'to go'),
      jsonb_build_object('id', c1, 'term', 'ser (yo soy)', 'definition', 'to be (lasting)'),
      jsonb_build_object('id', minted, 'term', 'tener', 'definition', E'to have\n(and to be, of age)'),
      jsonb_build_object('id', c5, 'term', 'hacer', 'definition', 'to do, to make'),
      jsonb_build_object('term', 'poder', 'definition', 'to be able to'))));
  minted2 := (out -> 'cards' -> 4 ->> 'id')::uuid;
  select string_agg(id::text || '=' || term || '@' || position, ',' order by position) into rows
  from public.flashcards where set_id = set_a;
  if rows is distinct from
       c3::text || '=ir@0,' || c1::text || '=ser (yo soy)@1,' || minted::text || '=tener@2,'
       || c5::text || '=hacer@3,' || minted2::text || '=poder@4' then
    raise exception 'an edit did not keep, move, insert and delete as sent: %', rows;
  end if;
  if exists (select 1 from public.flashcards where id = c2) then
    raise exception 'a card the save left out was kept';
  end if;
  if (select updated_at from public.flashcard_sets where id = set_a) <> now() then
    raise exception 'changing the cards alone did not move the set''s updated_at';
  end if;
  -- Moving a card counts as a change to it; a card that did not move is left alone.
  if (select updated_at from public.flashcards where id = minted) <> now()
     or (select updated_at from public.flashcards where id = c3) <> now() then
    raise exception 'a card that moved kept its old updated_at';
  end if;

  -- ---------------------------------------------------------------- what counts as a change
  five := jsonb_build_object(
    'id', set_a, 'title', 'Spanish verbs, I', 'description', 'Irregular, present tense.',
    'termLang', 'es', 'definitionLang', 'en',
    'cards', jsonb_build_array(
      jsonb_build_object('id', c3, 'term', 'ir', 'definition', 'to go'),
      jsonb_build_object('id', c1, 'term', 'ser (yo soy)', 'definition', 'to be (lasting)'),
      jsonb_build_object('id', minted, 'term', 'tener', 'definition', E'to have\n(and to be, of age)'),
      jsonb_build_object('id', c5, 'term', 'hacer', 'definition', 'to do, to make'),
      jsonb_build_object('id', minted2, 'term', 'poder', 'definition', 'to be able to')));
  -- Each changes one thing, in turn, and each is a change. In order: the second puts back
  -- the card the first took, so it is an insertion and nothing else.
  for payload, rows in
    select q.p, q.what from (values
      (five || jsonb_build_object('cards', (five -> 'cards') - 4), 'deleting a card and nothing else'),
      (five, 'adding a card and nothing else'),
      (five || jsonb_build_object('description', 'Irregular, present tense, every person.'),
       'changing the description and nothing else'),
      (five || jsonb_build_object('description', E' \u00a0\t\u3000'), 'blanking the description')
    ) as q (p, what)
  loop
    perform pg_temp.as_owner();
    update public.flashcard_sets set updated_at = '2000-01-01' where id = set_a;
    perform pg_temp.become_reader(reader_a);
    out := public.save_flashcard_set(payload);
    if (select updated_at from public.flashcard_sets where id = set_a) <> now() then
      raise exception '% did not move the set''s updated_at', rows;
    end if;
  end loop;
  if (select count(*) from public.flashcards where set_id = set_a) <> 5 then
    raise exception 'a card deleted and put back under its id is not there';
  end if;
  -- A description of nothing is none: null, not an empty string.
  if (select description from public.flashcard_sets where id = set_a) is not null then
    raise exception 'a blank description was stored as something';
  end if;

  -- ---------------------------------------------------------------- two screens, one set
  -- `now()` is fixed for the whole of this file, so a set that "changed since" is one whose
  -- time the owner moved.
  perform pg_temp.as_owner();
  update public.flashcard_sets set updated_at = '2000-01-01' where id = set_a;
  perform pg_temp.become_reader(reader_a);
  -- Opened at that time, and still at it: saved.
  out := public.save_flashcard_set(five || jsonb_build_object(
    'baseUpdatedAt', '2000-01-01T00:00:00+00:00', 'title', 'Spanish verbs, II'));
  if (select title from public.flashcard_sets where id = set_a) <> 'Spanish verbs, II' then
    raise exception 'a save from the version the set is at was not made';
  end if;
  -- A screen still on the old version -- one card, where the set now has five -- is refused,
  -- and none of its deletions are made.
  got := pg_temp.refusal(pg_temp.save_sql(five || jsonb_build_object(
    'baseUpdatedAt', '2000-01-01T00:00:00Z', 'cards', jsonb_build_array(five -> 'cards' -> 0))));
  if got <> '40001/changed' then
    raise exception 'a save from a stale version was not refused as changed: %', got;
  end if;
  if (select count(*) from public.flashcards where set_id = set_a) <> 5 then
    raise exception 'a stale save deleted the cards it did not know about';
  end if;
  -- The time a save answers with is the base for the next one, to the microsecond -- as is
  -- the time the API reads, which renders the column the same way.
  if out -> 'updatedAt' is distinct from
       (select to_jsonb(updated_at) from public.flashcard_sets where id = set_a) then
    raise exception 'a save answered with a time other than the one it stored: %', out;
  end if;
  out := public.save_flashcard_set(five || jsonb_build_object(
    'baseUpdatedAt', out -> 'updatedAt', 'title', 'Spanish verbs, I'));
  if (select title from public.flashcard_sets where id = set_a) <> 'Spanish verbs, I' then
    raise exception 'the time a save answered with was not accepted as the next base';
  end if;
  -- A save whose answer was lost, sent again: the same payload from the same base, which the
  -- first one made stale by landing. It would change nothing, so it is made as nothing and
  -- answers with the time the set is at -- not refused as "changed", which told the reader the
  -- set had been changed somewhere else and offered to save theirs over it.
  perform pg_temp.as_owner();
  update public.flashcard_sets set updated_at = '2001-01-01' where id = set_a;
  perform pg_temp.become_reader(reader_a);
  payload := five || jsonb_build_object('baseUpdatedAt', '2000-01-01T00:00:00Z');
  got := pg_temp.refusal(pg_temp.save_sql(payload));
  if got <> 'ok' then
    raise exception 'a retried save, changing nothing, was refused: %', got;
  end if;
  out := public.save_flashcard_set(payload);
  if (out ->> 'updatedAt')::timestamptz <> '2001-01-01'
     or (select updated_at from public.flashcard_sets where id = set_a) <> '2001-01-01' then
    raise exception 'a retried save moved the set, or answered with another time: %', out;
  end if;
  -- Anything it would change is refused, each alone: a field, a card's words, the order, a
  -- card taken out, a card added, a card under another id.
  for payload, rows in
    select q.p, q.what from (values
      (five || jsonb_build_object('title', 'Spanish verbs, III'), 'a title'),
      (five || jsonb_build_object('definitionLang', 'fr'), 'a language'),
      (five || jsonb_build_object('description', null), 'a description taken out'),
      (jsonb_set(five, '{cards,1,definition}', '"to be, lasting"'), 'a card''s definition'),
      (jsonb_set(five, '{cards,0,term}', '"iré"'), 'a card''s term'),
      (five || jsonb_build_object('cards', jsonb_build_array(five -> 'cards' -> 1, five -> 'cards' -> 0,
         five -> 'cards' -> 2, five -> 'cards' -> 3, five -> 'cards' -> 4)), 'the order'),
      (five || jsonb_build_object('cards', (five -> 'cards') - 4), 'a card taken out'),
      (five || jsonb_build_object('cards', (five -> 'cards')
         || jsonb_build_array(jsonb_build_object('term', 'ver', 'definition', 'to see'))), 'a card added'),
      (jsonb_set(five, '{cards,4,id}', to_jsonb(extensions.gen_random_uuid())), 'a card''s id')
    ) as q (p, what)
  loop
    got := pg_temp.refusal(pg_temp.save_sql(
      payload || jsonb_build_object('baseUpdatedAt', '2000-01-01T00:00:00Z')));
    if got <> '40001/changed' then
      raise exception 'a stale save changing % was not refused as changed: %', rows, got;
    end if;
  end loop;
  -- A base is a version to the microsecond, as the API renders it: one a microsecond off is
  -- another version, and a save that changes something from it is refused.
  got := pg_temp.refusal(pg_temp.save_sql(five || jsonb_build_object(
    'baseUpdatedAt', '2001-01-01T00:00:00.000001Z', 'title', 'Spanish verbs, III')));
  if got <> '40001/changed' then
    raise exception 'a base a microsecond off the set''s time was taken for it: %', got;
  end if;
  perform pg_temp.as_owner();
  update public.flashcard_sets set updated_at = '2001-01-01T00:00:00.000001Z' where id = set_a;
  perform pg_temp.become_reader(reader_a);
  got := pg_temp.refusal(pg_temp.save_sql(five || jsonb_build_object(
    'baseUpdatedAt', '2001-01-01T00:00:00Z', 'title', 'Spanish verbs, III')));
  if got <> '40001/changed' then
    raise exception 'a set a microsecond past its base was taken for it: %', got;
  end if;
  if (select title from public.flashcard_sets where id = set_a) <> 'Spanish verbs, I'
     or (select count(*) from public.flashcards where set_id = set_a) <> 5 then
    raise exception 'a refused stale save changed the set';
  end if;
  -- A set deleted on another screen is not put back by one that still had it open.
  got := pg_temp.refusal(pg_temp.save_sql(jsonb_build_object(
    'id', set_big, 'baseUpdatedAt', '2000-01-01T00:00:00Z', 'title', 'Deleted elsewhere',
    'cards', jsonb_build_array(jsonb_build_object('term', 'a', 'definition', 'b')))));
  if got <> 'P0002' or exists (select 1 from public.flashcard_sets where id = set_big) then
    raise exception 'a save from a set that is gone was not "no such set": %', got;
  end if;

  -- ---------------------------------------------------------------- a card is never moved
  got := pg_temp.refusal(pg_temp.save_sql(jsonb_build_object(
    'id', set_a2, 'title', 'Stealing a card',
    'cards', jsonb_build_array(jsonb_build_object('id', c1, 'term', 'ser', 'definition', 'x')))));
  if got <> '22023' then
    raise exception 'a card of another of the reader''s sets was taken: %', got;
  end if;
  if exists (select 1 from public.flashcard_sets where id = set_a2)
     or (select set_id from public.flashcards where id = c1) is distinct from set_a then
    raise exception 'a refused save left something behind';
  end if;

  -- ---------------------------------------------------------------- another reader
  perform pg_temp.become_reader(reader_b);
  if exists (select 1 from public.flashcard_sets) or exists (select 1 from public.flashcards) then
    raise exception 'reader B can see reader A''s flashcards';
  end if;
  got := pg_temp.refusal(pg_temp.save_sql(jsonb_build_object(
    'id', set_a, 'title', 'Mine now',
    'cards', jsonb_build_array(jsonb_build_object('term', 'a', 'definition', 'b')))));
  if got <> 'P0002' then
    raise exception 'reader B saving into A''s set was not "no such set": %', got;
  end if;
  -- With a base, too: the answer for a set that is not there, whatever the time says.
  got := pg_temp.refusal(pg_temp.save_sql(jsonb_build_object(
    'id', set_a, 'baseUpdatedAt', (select now()), 'title', 'Mine now',
    'cards', jsonb_build_array(jsonb_build_object('term', 'a', 'definition', 'b')))));
  if got <> 'P0002' then
    raise exception 'reader B saving into A''s set with a base was not "no such set": %', got;
  end if;
  got := pg_temp.refusal(pg_temp.save_sql(jsonb_build_object(
    'id', set_b, 'title', 'Taking a card',
    'cards', jsonb_build_array(jsonb_build_object('id', c1, 'term', 'a', 'definition', 'b')))));
  if got <> '22023' then
    raise exception 'reader B took one of A''s cards: %', got;
  end if;
  if public.delete_flashcard_set(set_a) then
    raise exception 'reader B deleted reader A''s set';
  end if;
  -- The answer B gets for A's set is the answer anyone gets for a set that is not there.
  if public.delete_flashcard_set(extensions.gen_random_uuid()) then
    raise exception 'deleting a set that does not exist said it did';
  end if;
  out := public.save_flashcard_set(jsonb_build_object(
    'id', set_b, 'title', 'Reader B''s own',
    'cards', jsonb_build_array(jsonb_build_object('id', b1, 'term', 'a', 'definition', 'b'))));
  if (select count(*) from public.flashcard_sets) <> 1 then
    raise exception 'reader B does not see exactly their own set';
  end if;
  perform pg_temp.as_owner();
  if (select title from public.flashcard_sets where id = set_a) <> 'Spanish verbs, I'
     or (select count(*) from public.flashcards where set_id = set_a) <> 5
     or (select owner_id from public.flashcard_sets where id = set_b) is distinct from reader_b then
    raise exception 'reader B''s attempts changed reader A''s set';
  end if;

  -- ---------------------------------------------------------------- no direct writes
  perform pg_temp.become_reader(reader_a);
  got := pg_temp.refusal(format(
    'insert into public.flashcard_sets (owner_id, title) values (%L, %L)', reader_a, 'Direct'));
  if got <> '42501' then raise exception 'a reader inserted a set directly: %', got; end if;
  got := pg_temp.refusal(format(
    'update public.flashcard_sets set title = %L where id = %L', 'Direct', set_a));
  if got <> '42501' then raise exception 'a reader updated a set directly: %', got; end if;
  got := pg_temp.refusal(format('delete from public.flashcard_sets where id = %L', set_a));
  if got <> '42501' then raise exception 'a reader deleted a set directly: %', got; end if;
  got := pg_temp.refusal(format(
    'insert into public.flashcards (set_id, owner_id, position, term, definition) '
    'values (%L, %L, 9, %L, %L)', set_a, reader_a, 'a', 'b'));
  if got <> '42501' then raise exception 'a reader inserted a card directly: %', got; end if;
  got := pg_temp.refusal(format(
    'update public.flashcards set term = %L where id = %L', 'Direct', c1));
  if got <> '42501' then raise exception 'a reader updated a card directly: %', got; end if;
  got := pg_temp.refusal(format('delete from public.flashcards where id = %L', c1));
  if got <> '42501' then raise exception 'a reader deleted a card directly: %', got; end if;
  -- The two doors are the reader's alone; nothing server-side calls them, so nothing else
  -- may. And the trimming rule is the tables' and the function's, not an endpoint.
  if has_function_privilege('service_role', 'public.save_flashcard_set(jsonb)', 'execute')
     or has_function_privilege('service_role', 'public.delete_flashcard_set(uuid)', 'execute')
     or has_function_privilege('anon', 'public.delete_flashcard_set(uuid)', 'execute')
     or has_function_privilege('authenticated', 'public.flashcard_trim(text)', 'execute') then
    raise exception 'a flashcard function is executable by a role that should not have it';
  end if;

  perform set_config('role', 'anon', true);
  perform set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
  got := pg_temp.refusal('select count(*) from public.flashcard_sets');
  if got <> '42501' then raise exception 'anon could read flashcard sets: %', got; end if;
  got := pg_temp.refusal('select count(*) from public.flashcards');
  if got <> '42501' then raise exception 'anon could read flashcards: %', got; end if;
  got := pg_temp.refusal(pg_temp.save_sql(jsonb_build_object(
    'title', 'Anon', 'cards', jsonb_build_array(jsonb_build_object('term', 'a', 'definition', 'b')))));
  if got <> '42501' then raise exception 'anon could call save_flashcard_set: %', got; end if;

  -- ---------------------------------------------------------------- who may save
  ok_set := jsonb_build_object(
    'title', 'A set', 'cards', jsonb_build_array(jsonb_build_object('term', 'a', 'definition', 'b')));
  -- Signed in as nobody: the role, with no reader in the claims.
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('role', 'authenticated')::text, true);
  perform pg_temp.assert_is_reader();
  got := pg_temp.refusal(pg_temp.save_sql(ok_set));
  if got <> '28000' then raise exception 'a save with no reader was not 28000: %', got; end if;
  got := pg_temp.refusal(format('select public.delete_flashcard_set(%L)', set_a));
  if got <> '28000' then raise exception 'a delete with no reader was not 28000: %', got; end if;
  -- A token that outlived its account: no reader either, rather than a foreign key failing.
  perform pg_temp.become_reader(extensions.gen_random_uuid());
  got := pg_temp.refusal(pg_temp.save_sql(ok_set));
  if got <> '28000' then
    raise exception 'a save by an account that is gone was not 28000: %', got;
  end if;

  perform pg_temp.become_reader(guest, true);
  got := pg_temp.refusal(pg_temp.save_sql(ok_set));
  if got <> '42501/guest' then raise exception 'a guest was not refused as a guest: %', got; end if;
  -- The table decides, not the claim: a guest whose token lacks `is_anonymous` is still one.
  perform pg_temp.become_reader(guest, false);
  got := pg_temp.refusal(pg_temp.save_sql(ok_set));
  if got <> '42501/guest' then
    raise exception 'a guest without the claim was not refused: %', got;
  end if;

  -- ---------------------------------------------------------------- malformed input
  perform pg_temp.become_reader(reader_a);
  for got, rows in
    select pg_temp.refusal(q.sql), q.what from (values
      ('select public.save_flashcard_set(null)', 'a null payload'),
      (pg_temp.save_sql('[]'), 'an array for a set'),
      (pg_temp.save_sql('"a set"'), 'a string for a set'),
      (pg_temp.save_sql(ok_set || '{"id": "not-a-uuid"}'), 'a set id that is not a uuid'),
      (pg_temp.save_sql(ok_set || '{"id": 42}'), 'a set id that is a number'),
      (pg_temp.save_sql(ok_set - 'title'), 'no title'),
      (pg_temp.save_sql(ok_set || '{"title": "   "}'), 'a blank title'),
      (pg_temp.save_sql(ok_set || '{"title": 7}'), 'a title that is a number'),
      (pg_temp.save_sql(ok_set || jsonb_build_object('title', repeat('t', 201))), 'a 201-character title'),
      (pg_temp.save_sql(ok_set || jsonb_build_object('description', repeat('d', 2001))), 'a 2,001-character description'),
      (pg_temp.save_sql(ok_set || '{"description": ["x"]}'), 'a description that is not text'),
      (pg_temp.save_sql(ok_set || '{"termLang": "english!"}'), 'a term language that is no tag'),
      (pg_temp.save_sql(ok_set || '{"definitionLang": "e"}'), 'a one-letter definition language'),
      -- The shape, 36 characters long: the function's own limit, not the table's check.
      (pg_temp.save_sql(ok_set || '{"termLang": "en-aaaaaaaa-bbbbbbbb-cccccccc-dddddd"}'),
       'a 36-character term language'),
      (pg_temp.save_sql(ok_set || '{"definitionLang": "en-aaaaaaaa-bbbbbbbb-cccccccc-dddddd"}'),
       'a 36-character definition language'),
      (pg_temp.save_sql(ok_set || '{"baseUpdatedAt": "not a time"}'), 'a base that is not a time'),
      (pg_temp.save_sql(ok_set || '{"baseUpdatedAt": 946684800}'), 'a base that is a number'),
      -- Blank as `.trim()` has it, which is wider than `btrim`'s spaces.
      (pg_temp.save_sql(ok_set || jsonb_build_object('title', E'\u00a0\u3000')),
       'a title of a no-break and an ideographic space'),
      (pg_temp.save_sql(ok_set || jsonb_build_object('cards', jsonb_build_array(
         jsonb_build_object('term', E'\u2028\ufeff\u2003', 'definition', 'b')))),
       'a term of a line separator, a byte-order mark and an em space'),
      (pg_temp.save_sql(ok_set - 'cards'), 'no cards'),
      (pg_temp.save_sql(ok_set || '{"cards": {}}'), 'cards that are an object'),
      (pg_temp.save_sql(ok_set || '{"cards": []}'), 'no cards in the array'),
      (pg_temp.save_sql(ok_set || '{"cards": ["a card"]}'), 'a card that is a string'),
      (pg_temp.save_sql(ok_set || '{"cards": [{"term": "a"}]}'), 'a card with no definition'),
      (pg_temp.save_sql(ok_set || '{"cards": [{"definition": "b"}]}'), 'a card with no term'),
      (pg_temp.save_sql(ok_set || '{"cards": [{"term": " \n ", "definition": "b"}]}'), 'a blank term'),
      (pg_temp.save_sql(ok_set || '{"cards": [{"term": 1, "definition": "b"}]}'), 'a term that is a number'),
      (pg_temp.save_sql(ok_set || jsonb_build_object('cards', jsonb_build_array(
         jsonb_build_object('term', repeat('t', 1001), 'definition', 'b')))), 'a 1,001-character term'),
      (pg_temp.save_sql(ok_set || jsonb_build_object('cards', jsonb_build_array(
         jsonb_build_object('term', 'a', 'definition', repeat('d', 2001))))), 'a 2,001-character definition'),
      (pg_temp.save_sql(ok_set || '{"cards": [{"id": "x", "term": "a", "definition": "b"}]}'), 'a card id that is not a uuid'),
      (pg_temp.save_sql(ok_set || jsonb_build_object('cards', jsonb_build_array(
         jsonb_build_object('id', c5, 'term', 'a', 'definition', 'b'),
         jsonb_build_object('id', c5, 'term', 'c', 'definition', 'd')))), 'one card id twice')
    ) as q (sql, what)
  loop
    if got <> '22023' then
      raise exception '% was not refused as malformed: %', rows, got;
    end if;
  end loop;
  if (select count(*) from public.flashcard_sets) <> 1 then
    raise exception 'a malformed save left a set behind';
  end if;

  -- Both edges hold: the longest title, term and definition are kept -- measured once
  -- trimmed, by the same rule, so the whitespace around each does not count against it.
  out := public.save_flashcard_set(jsonb_build_object(
    'id', set_a2, 'title', E'\u00a0' || repeat('t', 200) || E'\u2003',
    'description', repeat('d', 2000) || E'\u3000',
    'termLang', 'zh-Hant', 'definitionLang', 'en-GB',
    'cards', jsonb_build_array(jsonb_build_object('term', E'\u3000' || repeat('t', 1000),
                                                   'definition', repeat('d', 2000) || E'\ufeff'))));
  if (out ->> 'id')::uuid is distinct from set_a2
     or (select title from public.flashcard_sets where id = set_a2) <> repeat('t', 200)
     or (select term from public.flashcards where set_id = set_a2) <> repeat('t', 1000)
     or (select definition from public.flashcards where set_id = set_a2) <> repeat('d', 2000) then
    raise exception 'a set at every limit was refused, or stored untrimmed: %', out;
  end if;

  -- The tables hold the same rule, for a write that does not come through the function.
  perform pg_temp.as_owner();
  for got, rows in
    select pg_temp.refusal(q.sql), q.what from (values
      (format('insert into public.flashcard_sets (owner_id, title) values (%L, %L)',
              reader_a, E'\u00a0'), 'a blank title'),
      (format('insert into public.flashcard_sets (owner_id, title) values (%L, %L)',
              reader_a, ' untrimmed'), 'an untrimmed title'),
      (format('insert into public.flashcard_sets (owner_id, title, description) values (%L, %L, %L)',
              reader_a, 'A set', ''), 'an empty description'),
      (format('insert into public.flashcards (set_id, owner_id, position, term, definition) '
              'values (%L, %L, 99, %L, %L)', set_a2, reader_a, E'\u3000', 'b'), 'a blank term')
    ) as q (sql, what)
  loop
    -- A check's DETAIL is the failing row, so the SQLSTATE alone.
    if split_part(got, '/', 1) <> '23514' then
      raise exception '% was not refused by the table: %', rows, got;
    end if;
  end loop;
  perform pg_temp.become_reader(reader_a);

  -- ---------------------------------------------------------------- the card limit
  payload := jsonb_build_object('id', set_a2, 'title', 'Two thousand', 'cards',
    (select jsonb_agg(jsonb_build_object('term', 'term ' || i, 'definition', 'definition ' || i))
     from generate_series(1, 2000) as i));
  out := public.save_flashcard_set(payload);
  if (select count(*) from public.flashcards where set_id = set_a2) <> 2000 then
    raise exception '2,000 cards were not kept';
  end if;
  got := pg_temp.refusal(pg_temp.save_sql(payload || jsonb_build_object('cards',
    (payload -> 'cards') || '[{"term": "one", "definition": "too many"}]'::jsonb)));
  if got <> '54000/cards' then
    raise exception '2,001 cards were not refused as over the card limit: %', got;
  end if;

  -- ---------------------------------------------------------------- the total limit
  -- Five cards in one set and 2,000 in another; a third, made by the owner, brings the
  -- reader to exactly 20,000.
  perform pg_temp.as_owner();
  insert into public.flashcard_sets (id, owner_id, title) values (filler, reader_a, 'Filler');
  insert into public.flashcards (set_id, owner_id, position, term, definition)
  select filler, reader_a, i, 't' || i, 'd' || i from generate_series(0, 20000 - 2005 - 1) as i;
  perform pg_temp.become_reader(reader_a);
  if (select count(*) from public.flashcards) <> 20000 then
    raise exception 'the reader does not have 20,000 cards to test the total with';
  end if;
  got := pg_temp.refusal(pg_temp.save_sql(ok_set));
  if got <> '54000/total' then
    raise exception 'a card past 20,000 in a new set was not refused as over the total: %', got;
  end if;
  got := pg_temp.refusal(pg_temp.save_sql(five || jsonb_build_object('cards',
    (five -> 'cards') || '[{"term": "one", "definition": "too many"}]'::jsonb)));
  if got <> '54000/total' then
    raise exception 'a card past 20,000 in a set of the reader''s was not refused: %', got;
  end if;
  -- A set is counted as sent, not as it was: at the limit, it can still be saved, and made
  -- smaller.
  out := public.save_flashcard_set(payload);
  out := public.save_flashcard_set(five || jsonb_build_object('cards', (five -> 'cards') - 4));
  out := public.save_flashcard_set(five);
  perform pg_temp.as_owner();
  delete from public.flashcard_sets where id = filler;
  perform pg_temp.become_reader(reader_a);

  -- ---------------------------------------------------------------- the size limit
  -- 2 MB exactly, in UTF-8 bytes of what is stored: 174 cards of four-byte characters at both
  -- limits, four of one-byte ones, and one to make up the rest.
  big := jsonb_build_object('id', set_big, 'title', 'Big', 'cards',
    (select jsonb_agg(jsonb_build_object('term', repeat(U&'\+01F600', 1000),
                                         'definition', repeat(U&'\+01F600', 2000)))
     from generate_series(1, 174))
    || (select jsonb_agg(jsonb_build_object('term', 'x', 'definition', repeat('d', 2000)))
        from generate_series(1, 4))
    || jsonb_build_array(jsonb_build_object('term', 'x', 'definition', repeat('d', 1144))));
  if (select octet_length(big ->> 'title')
             + sum(octet_length(c ->> 'term') + octet_length(c ->> 'definition'))
      from jsonb_array_elements(big -> 'cards') as c) <> 2 * 1024 * 1024 then
    raise exception 'this test''s own arithmetic is off';
  end if;
  out := public.save_flashcard_set(big);
  if (select count(*) from public.flashcards where set_id = set_big) <> 179 then
    raise exception 'a set of exactly 2 MB was not kept';
  end if;
  -- One byte more, in a card, in the description or in the title, is over.
  got := pg_temp.refusal(pg_temp.save_sql(jsonb_set(big, '{cards,178,definition}',
                                                     to_jsonb(repeat('d', 1145)))));
  if got <> '54000/size' then
    raise exception 'a byte past 2 MB in a card was not refused as over the size: %', got;
  end if;
  got := pg_temp.refusal(pg_temp.save_sql(big || '{"description": "d"}'));
  if got <> '54000/size' then
    raise exception 'a byte past 2 MB in the description was not refused: %', got;
  end if;
  got := pg_temp.refusal(pg_temp.save_sql(big || '{"title": "Bigg"}'));
  if got <> '54000/size' then
    raise exception 'a byte past 2 MB in the title was not refused: %', got;
  end if;
  perform public.delete_flashcard_set(set_big);

  -- ---------------------------------------------------------------- the set limit
  perform pg_temp.as_owner();
  insert into public.flashcard_sets (owner_id, title)
  select reader_a, 'Filler ' || i from generate_series(1, 500 - 2) as i;
  perform pg_temp.become_reader(reader_a);
  if (select count(*) from public.flashcard_sets) <> 500 then
    raise exception 'the reader does not have 500 sets to test the limit with';
  end if;
  got := pg_temp.refusal(pg_temp.save_sql(ok_set));
  if got <> '54000/sets' then
    raise exception 'a 501st set was not refused as over the set limit: %', got;
  end if;
  -- A set the reader has already is still theirs to change at the limit.
  out := public.save_flashcard_set(ok_set || jsonb_build_object('id', set_a2));
  if (select title from public.flashcard_sets where id = set_a2) <> 'A set' then
    raise exception 'a set could not be edited at the set limit';
  end if;
  -- And the limit is per reader: B is nowhere near it.
  perform pg_temp.become_reader(reader_b);
  out := public.save_flashcard_set(ok_set);
  if (select count(*) from public.flashcard_sets) <> 2 then
    raise exception 'reader A''s limit reached reader B';
  end if;

  -- ---------------------------------------------------------------- deleting
  perform pg_temp.become_reader(reader_a);
  if not public.delete_flashcard_set(set_a) then
    raise exception 'the reader could not delete their own set';
  end if;
  if exists (select 1 from public.flashcard_sets where id = set_a) then
    raise exception 'a deleted set is still there';
  end if;
  perform pg_temp.as_owner();
  if exists (select 1 from public.flashcards where set_id = set_a) then
    raise exception 'a deleted set left its cards';
  end if;
  perform pg_temp.become_reader(reader_a);
  if public.delete_flashcard_set(set_a) then
    raise exception 'deleting a set twice said it went twice';
  end if;
  -- With a place under the limit again, a new set can be made.
  out := public.save_flashcard_set(ok_set);
  if (select count(*) from public.flashcard_sets) <> 500 then
    raise exception 'a set could not be made once one was deleted';
  end if;
  -- A save of a set deleted elsewhere puts it back, with what the reader saved -- and its
  -- cards under the ids they had, since those now exist nowhere.
  perform public.delete_flashcard_set((out ->> 'id')::uuid);
  out := public.save_flashcard_set(first || jsonb_build_object('cards', jsonb_build_array(
    jsonb_build_object('id', c1, 'term', 'ser', 'definition', 'to be (lasting)'))));
  if not exists (select 1 from public.flashcards where id = c1 and set_id = set_a) then
    raise exception 'a set saved after its deletion did not come back as saved';
  end if;

  -- ---------------------------------------------------------------- one at a time
  -- Both doors take the reader's lock, inside the caller's transaction -- where it holds until
  -- that ends -- so each call is made in a block of its own and rolled back, and asked of a
  -- reader nothing had run for. A lock taken in a rolled-back block goes with it.
  perform pg_temp.become_reader(reader_c);
  if pg_temp.holds_reader_lock(reader_c) then
    raise exception 'reader C''s lock was held before anything ran for them';
  end if;
  begin
    perform public.delete_flashcard_set(extensions.gen_random_uuid());
    locked := pg_temp.holds_reader_lock(reader_c);
    raise exception 'undo the delete';
  exception when raise_exception then
    null;
  end;
  if not locked then
    raise exception 'delete_flashcard_set did not take the reader''s lock';
  end if;
  if pg_temp.holds_reader_lock(reader_c) then
    raise exception 'the lock outlived the block that took it, so the next check means nothing';
  end if;
  begin
    perform public.save_flashcard_set(ok_set);
    locked := pg_temp.holds_reader_lock(reader_c);
    raise exception 'undo the save';
  exception when raise_exception then
    null;
  end;
  if not locked then
    raise exception 'save_flashcard_set did not take the reader''s lock';
  end if;

  -- ---------------------------------------------------------------- the account goes
  perform pg_temp.as_owner();
  delete from auth.users where id = reader_a;
  if exists (select 1 from public.flashcard_sets where owner_id = reader_a)
     or exists (select 1 from public.flashcards where owner_id = reader_a) then
    raise exception 'deleting the account left its flashcards';
  end if;
  if (select count(*) from public.flashcard_sets where owner_id = reader_b) <> 2 then
    raise exception 'deleting one account took another''s sets';
  end if;

  raise notice 'flashcards: saved by client id, ids kept across edits, private, refused '
    'when malformed or over a limit, and gone with the set and the account';
end $test$;

rollback;
