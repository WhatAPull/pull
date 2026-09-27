-- Flashcards: a reader's own sets of term/definition cards, made, imported and studied in
-- the app. Roadmap PR 12.
--
--   flashcard_sets   a set: its title, an optional description, and the languages its two
--                    sides are written in (used only to choose a voice on the device).
--   flashcards       its cards, in order. A card's id survives every edit of its set -- the
--                    term, the definition and the position change, the id does not -- so
--                    the memory spaced review keeps per card (PR 13) has something stable
--                    to key on.
--
-- Private, and nothing else. A set is the reader's own text: it is never published, never
-- joins the catalogue (law 4), and nothing here calls a model (law 2) -- studying it is
-- client-side arithmetic over rows the reader already has.
--
-- RLS and policies live in this migration, beside the tables (law 5). Neither table takes a
-- direct write from the API: `save_flashcard_set` and `delete_flashcard_set` are the only
-- ways in, because the limits below are properties of a reader's whole collection, and a
-- policy sees one row at a time.
--
-- Limits, against abuse and not as a tier (law 3): 500 sets a reader, 2,000 cards and 2 MB of
-- text a set, and 20,000 cards across all of a reader's sets. A set of 2,000 cards is already
-- longer than anyone studies in a sitting. The other two are what make the first two safe to
-- multiply: 500 sets of 2,000 cards, every side at its longest in four-byte characters, was
-- 11.5 GB for one account and a scripted afternoon's work. Now it is at most 20,000 cards of
-- 12 KB each, and no one save carries more than 2 MB of them.
--
-- BLANK MEANS ONE THING. What `flashcard_trim` takes off both ends is what JavaScript's
-- `.trim()` does -- `study_space_class()`, the repository's one spelling of it -- and every
-- check here, the function's and the tables', uses it. The function once trimmed space, tab
-- and the two line breaks, and the tables' checks spaces alone: a title of one no-break space
-- was a title to the database and blank to the editor, whose rule is the one a reader sees.

-- ------------------------------------------------------------------ blank

/*
 * A text without the whitespace at either end, as `.trim()` leaves it.
 *
 * A standard body (`return`), which Postgres parses when the function is made and so records
 * as calling `study_space_class()`. The tables' checks below call this function, and a quoted
 * body left that second link unrecorded: `drop function public.study_space_class()` went
 * through, and every save would have failed from then on. Now the drop is refused. What no
 * record refuses is a `create or replace` of that function, which would change what the checks
 * accept without checking the rows already stored -- so its comment, below, says so.
 */
create function public.flashcard_trim(p_text text)
returns text
language sql
immutable
parallel safe
set search_path = ''
return regexp_replace(
  p_text, '^' || public.study_space_class() || '+|' || public.study_space_class() || '+$', '', 'g');

comment on function public.study_space_class() is
  'JavaScript''s \s, as .trim() and /\s+/ read it. Table checks depend on it through '
  'public.flashcard_trim (20260926100000): redefining it changes what they accept, and the '
  'rows already stored are not checked again.';

revoke all on function public.flashcard_trim(text) from public, anon, authenticated, service_role;

-- ------------------------------------------------------------------ sets

create table public.flashcard_sets (
  -- Supplied by the client when it creates a set, so a save retried after a lost response
  -- is the same set rather than a second one.
  id               uuid primary key default extensions.gen_random_uuid(),
  owner_id         uuid not null references auth.users (id) on delete cascade,
  -- Stored trimmed, so "1 to 200 characters after trimming" is simply 1 to 200.
  title            text not null check (char_length(title) between 1 and 200
                                        and title = public.flashcard_trim(title)),
  -- Null rather than blank: a description of nothing is no description.
  description      text check (char_length(description) between 1 and 2000
                               and description = public.flashcard_trim(description)),
  -- A language tag (`en`, `es-MX`, `zh-Hant`), and only to pick a voice: nothing else reads
  -- it. Loosely BCP 47 -- the shape a browser's `SpeechSynthesisVoice.lang` has.
  term_lang        text check (term_lang ~ '^[A-Za-z]{2,3}(-[A-Za-z0-9]{1,8})*$'
                               and char_length(term_lang) <= 35),
  definition_lang  text check (definition_lang ~ '^[A-Za-z]{2,3}(-[A-Za-z0-9]{1,8})*$'
                               and char_length(definition_lang) <= 35),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  unique (id, owner_id)
);

-- The reader's list, newest change first -- and the owner's foreign key.
create index flashcard_sets_owner_idx on public.flashcard_sets (owner_id, updated_at desc);

alter table public.flashcard_sets enable row level security;

create policy flashcard_sets_read_own on public.flashcard_sets
  for select to authenticated using (owner_id = (select auth.uid()));

revoke all on public.flashcard_sets from public, anon, authenticated, service_role;
grant select on public.flashcard_sets to authenticated;

comment on table public.flashcard_sets is
  'A reader''s own flashcard set: private, never published, studied on the device. Written only through save_flashcard_set and delete_flashcard_set.';

-- ------------------------------------------------------------------ cards

create table public.flashcards (
  id          uuid primary key default extensions.gen_random_uuid(),
  set_id      uuid not null,
  owner_id    uuid not null,
  -- The card's place in its set, 0 first. Written only by `save_flashcard_set`, which
  -- writes the whole of a set's order at once, so it is 0..n-1 without gaps.
  position    int not null check (position >= 0),
  term        text not null check (char_length(term) between 1 and 1000
                                   and term = public.flashcard_trim(term)),
  definition  text not null check (char_length(definition) between 1 and 2000
                                   and definition = public.flashcard_trim(definition)),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  -- For PR 13: a card's memory will reference (id, owner_id), so a reader's memory can only
  -- ever name a reader's own card. Written owner first, which a foreign key on (id, owner_id)
  -- accepts just the same, so the one index also serves the account export's walk of a
  -- reader's cards by id and the count of them the total limit takes.
  unique (owner_id, id),
  foreign key (set_id, owner_id) references public.flashcard_sets (id, owner_id)
    on delete cascade
);

-- A set's cards in order -- and the set's foreign key.
create index flashcards_set_idx on public.flashcards (set_id, owner_id, position);

alter table public.flashcards enable row level security;

create policy flashcards_read_own on public.flashcards
  for select to authenticated using (owner_id = (select auth.uid()));

revoke all on public.flashcards from public, anon, authenticated, service_role;
grant select on public.flashcards to authenticated;

comment on table public.flashcards is
  'One card of a reader''s flashcard set. Its id is stable across edits of the set, so a per-card memory can key on it.';

-- ------------------------------------------------------------------ saving a set

/*
 * Make the reader's set be this: its fields, and exactly these cards in this order.
 *
 *   p_set  { id?, baseUpdatedAt?, title, description?, termLang?, definitionLang?,
 *            cards: [{ id?, term, definition }] }   1 to 2,000 cards
 *
 * Returns { id, updatedAt, cards: [{ id, position }] }.
 *
 * AN UPSERT BY THE CLIENT'S ID. A set that does not exist is created with the id the
 * client sent, so a save retried after its response was lost finds the set it made and
 * changes nothing further. The same holds for cards: a card carrying an id that is in this
 * set keeps it, with its term, definition and position updated; a card carrying an id that
 * exists nowhere is inserted under it; a card with none is given one. The web mints every
 * id itself, so a retry is exact. Cards of the set the payload does not name are deleted.
 *
 * TWO SCREENS DO NOT SAVE OVER EACH OTHER UNSEEN. `baseUpdatedAt` is the `updated_at` of the
 * set the editor started from. When the set has changed since, and this save would change it
 * again, the save is refused (40001 changed) rather than made: a tab left open on the old
 * cards would otherwise save them back, deleting every card another tab had added -- and with
 * them, from PR 13, each card's memory. When the set is gone, deleted on another screen, it is
 * refused as not found rather than put back. The web then says so, and sends the save again
 * without `baseUpdatedAt` only when the reader chooses to save over the newer set; a save
 * without it is the reader's word, and puts back a set deleted elsewhere, with what they saved.
 *
 * AND A RETRY IS NOT A CONFLICT. A save that landed and whose answer was lost is sent again as
 * it was, from the same base -- which the first one has just made stale. It was refused as
 * "changed", and the editor told the reader the set had been changed somewhere else, which it
 * had not, and offered to save theirs over it. So a stale base is refused only when the save
 * would change something: the set's fields, or its cards -- their ids, words and order, as
 * stored. A save that would change nothing is made as nothing, and answers with the time the
 * set is at.
 *
 * Refusals, each with its SQLSTATE and, where one code covers several, a DETAIL:
 *
 *   28000          not signed in, or signed in as an account that no longer exists
 *   42501 guest    a guest session: a guest's rows are swept a day after last use, and a
 *                  set is exactly the kind of work that should not vanish with a tab
 *   22023          malformed: not an object, an id that is not a uuid, a base that is not a
 *                  time, a title, description, language, term or definition out of range,
 *                  cards not an array or empty, a card id twice, or a card id that belongs to
 *                  another set -- a card is never moved between sets, since its memory would
 *                  move with it
 *   40001 changed  `baseUpdatedAt` is not the set's `updated_at` -- it changed since -- and
 *                  this save would change it
 *   54000 sets     the reader already has 500 sets and this would be another
 *   54000 cards    more than 2,000 cards
 *   54000 size     more than 2 MB of text in the set: its title, description, terms and
 *                  definitions, trimmed, in UTF-8 bytes
 *   54000 total    more than 20,000 cards across the reader's sets, counting this one as sent
 *   P0002          the id is another reader's set, or -- with `baseUpdatedAt` -- a set that
 *                  does not exist. One code for both, which is all it says: an id taken by
 *                  somebody, out of 2^122, or none. Nothing of that set is read or shown.
 *
 * One save at a time per reader, so no limit can be raced past by two tabs.
 *
 * `updated_at` moves only when something changed, so reopening and saving a set untouched
 * does not reorder the reader's list.
 */
create function public.save_flashcard_set(p_set jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  set_limit   constant int := 500;
  card_limit  constant int := 2000;
  total_limit constant int := 20000;
  size_limit  constant int := 2 * 1024 * 1024;
  uuid_shape  constant text := '^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$';
  lang_shape  constant text := '^[A-Za-z]{2,3}(-[A-Za-z0-9]{1,8})*$';

  uid          uuid := (select auth.uid());
  v_id         uuid;
  v_base       timestamptz;
  v_guest      boolean;
  v_bytes      bigint;
  v_title      text;
  v_desc       text;
  v_term_lang  text;
  v_def_lang   text;
  v_existing   public.flashcard_sets%rowtype;
  v_created    boolean := false;
  v_changed    boolean := false;
  v_cards      jsonb;
  v_card       jsonb;
  v_ord        bigint;
  v_card_id    uuid;
  v_term       text;
  v_definition text;
  v_ids        uuid[] := '{}';
  v_terms      text[] := '{}';
  v_defs       text[] := '{}';
  v_had_ids    uuid[];
  v_had_terms  text[];
  v_had_defs   text[];
  v_now        timestamptz := now();
  n            int;
begin
  if uid is null then
    raise exception 'saving a flashcard set requires a signed-in reader' using errcode = '28000';
  end if;
  -- Read from `auth.users` rather than from the claim, as the other definer doors do
  -- (20260901190000): the table is the fact, and the claim a copy of it. Once, and a token
  -- that outlived its account is no reader -- not a foreign key failing on the insert below.
  -- Key-share locked, as the study doors read it (20260925230000): an account being deleted
  -- waits for this save to finish, and a save that arrives while it is deleted waits for the
  -- deletion and is no reader. Unlocked, it read the row a deletion had not yet committed,
  -- went on, and failed on its own foreign key -- or deadlocked the deletion.
  select u.is_anonymous into v_guest from auth.users u where u.id = uid for key share;
  if not found then
    raise exception 'saving a flashcard set requires a signed-in reader' using errcode = '28000';
  end if;
  if v_guest then
    raise exception 'a guest session cannot keep flashcard sets'
      using errcode = '42501', detail = 'guest';
  end if;

  if jsonb_typeof(p_set) is distinct from 'object' then
    raise exception 'a flashcard set must be an object' using errcode = '22023';
  end if;

  -- ---------------------------------------------------------------- the set's own fields
  if p_set -> 'id' is null or jsonb_typeof(p_set -> 'id') = 'null' then
    v_id := extensions.gen_random_uuid();
  elsif jsonb_typeof(p_set -> 'id') <> 'string' or (p_set ->> 'id') !~ uuid_shape then
    raise exception 'the set id is not a uuid' using errcode = '22023';
  else
    v_id := (p_set ->> 'id')::uuid;
  end if;

  if coalesce(jsonb_typeof(p_set -> 'baseUpdatedAt'), 'null') = 'null' then
    v_base := null;
  elsif jsonb_typeof(p_set -> 'baseUpdatedAt') <> 'string' then
    raise exception 'the base time is not a time' using errcode = '22023';
  else
    begin
      v_base := (p_set ->> 'baseUpdatedAt')::timestamptz;
    exception when data_exception then
      raise exception 'the base time is not a time' using errcode = '22023';
    end;
  end if;

  if jsonb_typeof(p_set -> 'title') is distinct from 'string' then
    raise exception 'a set needs a title' using errcode = '22023';
  end if;
  v_title := public.flashcard_trim(p_set ->> 'title');
  if char_length(v_title) not between 1 and 200 then
    raise exception 'a title is 1 to 200 characters' using errcode = '22023';
  end if;

  if coalesce(jsonb_typeof(p_set -> 'description'), 'null') = 'null' then
    v_desc := null;
  elsif jsonb_typeof(p_set -> 'description') <> 'string' then
    raise exception 'a description is text' using errcode = '22023';
  else
    v_desc := nullif(public.flashcard_trim(p_set ->> 'description'), '');
    if char_length(v_desc) > 2000 then
      raise exception 'a description is at most 2000 characters' using errcode = '22023';
    end if;
  end if;

  if coalesce(jsonb_typeof(p_set -> 'termLang'), 'null') = 'null' then
    v_term_lang := null;
  elsif jsonb_typeof(p_set -> 'termLang') <> 'string'
        or (p_set ->> 'termLang') !~ lang_shape or char_length(p_set ->> 'termLang') > 35 then
    raise exception 'the term language is not a language tag' using errcode = '22023';
  else
    v_term_lang := p_set ->> 'termLang';
  end if;

  if coalesce(jsonb_typeof(p_set -> 'definitionLang'), 'null') = 'null' then
    v_def_lang := null;
  elsif jsonb_typeof(p_set -> 'definitionLang') <> 'string'
        or (p_set ->> 'definitionLang') !~ lang_shape
        or char_length(p_set ->> 'definitionLang') > 35 then
    raise exception 'the definition language is not a language tag' using errcode = '22023';
  else
    v_def_lang := p_set ->> 'definitionLang';
  end if;

  -- ---------------------------------------------------------------- the cards
  v_cards := p_set -> 'cards';
  if jsonb_typeof(v_cards) is distinct from 'array' then
    raise exception 'cards must be an array' using errcode = '22023';
  end if;
  if jsonb_array_length(v_cards) = 0 then
    raise exception 'a set needs at least one card' using errcode = '22023';
  end if;
  if jsonb_array_length(v_cards) > card_limit then
    raise exception 'a set has at most % cards', card_limit
      using errcode = '54000', detail = 'cards';
  end if;

  for v_card, v_ord in select value, ordinality from jsonb_array_elements(v_cards) with ordinality
  loop
    if jsonb_typeof(v_card) is distinct from 'object' then
      raise exception 'card % is not an object', v_ord using errcode = '22023';
    end if;
    if coalesce(jsonb_typeof(v_card -> 'id'), 'null') = 'null' then
      v_card_id := extensions.gen_random_uuid();
    elsif jsonb_typeof(v_card -> 'id') <> 'string' or (v_card ->> 'id') !~ uuid_shape then
      raise exception 'card %''s id is not a uuid', v_ord using errcode = '22023';
    else
      v_card_id := (v_card ->> 'id')::uuid;
    end if;
    if v_card_id = any (v_ids) then
      raise exception 'card %''s id is given twice', v_ord using errcode = '22023';
    end if;
    if jsonb_typeof(v_card -> 'term') is distinct from 'string'
       or jsonb_typeof(v_card -> 'definition') is distinct from 'string' then
      raise exception 'card % needs a term and a definition', v_ord using errcode = '22023';
    end if;
    v_term := public.flashcard_trim(v_card ->> 'term');
    v_definition := public.flashcard_trim(v_card ->> 'definition');
    if char_length(v_term) not between 1 and 1000 then
      raise exception 'card %''s term is 1 to 1000 characters', v_ord using errcode = '22023';
    end if;
    if char_length(v_definition) not between 1 and 2000 then
      raise exception 'card %''s definition is 1 to 2000 characters', v_ord
        using errcode = '22023';
    end if;
    v_ids := v_ids || v_card_id;
    v_terms := v_terms || v_term;
    v_defs := v_defs || v_definition;
  end loop;

  -- What the set weighs, as stored: every side trimmed, in UTF-8 bytes.
  v_bytes := octet_length(v_title) + coalesce(octet_length(v_desc), 0)
             + (select coalesce(sum(octet_length(t)), 0) from unnest(v_terms || v_defs) as t);

  -- ---------------------------------------------------------------- one save at a time
  perform pg_advisory_xact_lock(pg_catalog.hashtextextended('flashcards:' || uid::text, 0));

  -- No row lock: every write to a reader's sets holds the lock above, and a lock on the row
  -- would be taken before knowing whose it is.
  select * into v_existing from public.flashcard_sets s where s.id = v_id;
  if found and v_existing.owner_id <> uid then
    raise exception 'no such flashcard set' using errcode = 'P0002';
  end if;
  if v_base is not null then
    if v_existing.id is null then
      raise exception 'no such flashcard set' using errcode = 'P0002';
    end if;
    if v_existing.updated_at is distinct from v_base then
      -- Changed since, but would this change it? Not when it is what this save says: a retry.
      select coalesce(array_agg(f.id order by f.position), '{}'),
             coalesce(array_agg(f.term order by f.position), '{}'),
             coalesce(array_agg(f.definition order by f.position), '{}')
        into v_had_ids, v_had_terms, v_had_defs
      from public.flashcards f
      where f.set_id = v_id and f.owner_id = uid;
      if (v_existing.title, v_existing.description, v_existing.term_lang,
          v_existing.definition_lang, v_had_ids, v_had_terms, v_had_defs)
         is distinct from (v_title, v_desc, v_term_lang, v_def_lang, v_ids, v_terms, v_defs) then
        raise exception 'the set has changed since it was opened'
          using errcode = '40001', detail = 'changed';
      end if;
    end if;
  end if;

  -- A card is never moved: an id that is in some other set -- the reader's own or anyone's
  -- -- is refused rather than taken over.
  if exists (
    select 1 from public.flashcards f
    where f.id = any (v_ids) and (f.set_id <> v_id or f.owner_id <> uid)
  ) then
    raise exception 'a card belongs to another set' using errcode = '22023';
  end if;

  if v_bytes > size_limit then
    raise exception 'a set holds at most 2 MB of text' using errcode = '54000', detail = 'size';
  end if;
  -- Every card of the reader's other sets, and this set's as sent -- not as it was, so a set
  -- at the limit can still be edited, and made smaller.
  select count(*) into n from public.flashcards f where f.owner_id = uid and f.set_id <> v_id;
  if n + array_length(v_ids, 1) > total_limit then
    raise exception 'a reader keeps at most % flashcards across their sets', total_limit
      using errcode = '54000', detail = 'total';
  end if;

  if v_existing.id is null then
    if (select count(*) from public.flashcard_sets s where s.owner_id = uid) >= set_limit then
      raise exception 'a reader keeps at most % flashcard sets', set_limit
        using errcode = '54000', detail = 'sets';
    end if;
    insert into public.flashcard_sets
      (id, owner_id, title, description, term_lang, definition_lang, created_at, updated_at)
    values (v_id, uid, v_title, v_desc, v_term_lang, v_def_lang, v_now, v_now);
    v_created := true;
  else
    v_changed := (v_existing.title, v_existing.description, v_existing.term_lang,
                  v_existing.definition_lang)
                 is distinct from (v_title, v_desc, v_term_lang, v_def_lang);
  end if;

  -- Removed cards first, then the kept ones moved into place, then the new ones.
  delete from public.flashcards f
  where f.set_id = v_id and f.owner_id = uid and f.id <> all (v_ids);
  get diagnostics n = row_count;
  v_changed := v_changed or n > 0;

  update public.flashcards f
  set term = c.term, definition = c.definition, position = c.pos, updated_at = v_now
  from (
    select u.id, u.term, u.definition, (u.ord - 1)::int as pos
    from unnest(v_ids, v_terms, v_defs) with ordinality as u (id, term, definition, ord)
  ) c
  where f.id = c.id and f.set_id = v_id and f.owner_id = uid
    and (f.term, f.definition, f.position) is distinct from (c.term, c.definition, c.pos);
  get diagnostics n = row_count;
  v_changed := v_changed or n > 0;

  insert into public.flashcards (id, set_id, owner_id, position, term, definition,
                                 created_at, updated_at)
  select u.id, v_id, uid, (u.ord - 1)::int, u.term, u.definition, v_now, v_now
  from unnest(v_ids, v_terms, v_defs) with ordinality as u (id, term, definition, ord)
  where not exists (select 1 from public.flashcards f where f.id = u.id);
  get diagnostics n = row_count;
  v_changed := v_changed or n > 0;

  if not v_created and v_changed then
    update public.flashcard_sets
    set title = v_title, description = v_desc, term_lang = v_term_lang,
        definition_lang = v_def_lang, updated_at = v_now
    where id = v_id;
  end if;

  return jsonb_build_object(
    'id', v_id,
    'updatedAt', (select s.updated_at from public.flashcard_sets s where s.id = v_id),
    'cards', (
      select jsonb_agg(jsonb_build_object('id', u.id, 'position', u.ord - 1) order by u.ord)
      from unnest(v_ids) with ordinality as u (id, ord)
    )
  );
end
$fn$;

revoke all on function public.save_flashcard_set(jsonb)
  from public, anon, authenticated, service_role;
grant execute on function public.save_flashcard_set(jsonb) to authenticated;

comment on function public.save_flashcard_set(jsonb) is
  'Create or replace the reader''s flashcard set by its client id; keeps the ids of cards it names. See 20260926100000.';

-- ------------------------------------------------------------------ deleting a set

/*
 * Delete the reader's set and its cards. True when it went; false for a set that does not
 * exist, was already deleted, or is somebody else's -- one answer for all three, so an id
 * says nothing about whose it is. 28000 with no reader. Under the save's lock, so a delete
 * and a save of the same reader's sets never interleave.
 */
create function public.delete_flashcard_set(p_id uuid)
returns boolean
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  uid uuid := (select auth.uid());
  n   int;
begin
  if uid is null then
    raise exception 'deleting a flashcard set requires a signed-in reader' using errcode = '28000';
  end if;
  perform pg_advisory_xact_lock(pg_catalog.hashtextextended('flashcards:' || uid::text, 0));
  delete from public.flashcard_sets s where s.id = p_id and s.owner_id = uid;
  get diagnostics n = row_count;
  return n > 0;
end
$fn$;

revoke all on function public.delete_flashcard_set(uuid)
  from public, anon, authenticated, service_role;
grant execute on function public.delete_flashcard_set(uuid) to authenticated;

comment on function public.delete_flashcard_set(uuid) is
  'Delete the reader''s flashcard set with its cards. False for a set that is not theirs or not there. See 20260926100000.';
