-- Flashcards suggested from your reading.
--
-- The ideas a reader has met, most due for review first, as terms and definitions: each
-- Pull's headline and its body, text already written once for the catalogue. The /flashcards
-- screen offers them as a set the reader can add, which copies them into a set of their own
-- through `save_flashcard_set` like any other. Nothing is written here, nothing is recorded
-- about how the reader studies them, and no model is involved (law 2): it is a join.
--
-- SECURITY INVOKER, on purpose. `knowledge_states` answers a reader only their own rows and
-- `pulls` only those whose summary they may read (20260829124730), so the function sees
-- exactly what the reader could select themselves, and has no policy of its own to get
-- wrong. The `user_id` filter is what it asks for, not what protects it.
--
-- At most thirty: a set to study in one sitting, well inside the API's hundred rows. Ordered
-- by `next_due_at` so the ideas the Delta says are fading or overdue come first; the id breaks
-- ties so the same reading suggests the same set.

create function public.suggested_flashcards()
returns table (pull_id uuid, term text, definition text)
language sql
stable
security invoker
set search_path = ''
as $fn$
  select p.id, p.headline, p.body
  from public.knowledge_states k
  join public.pulls p on p.id = k.pull_id
  where k.user_id = (select auth.uid())
  order by k.next_due_at, p.id
  limit 30;
$fn$;

comment on function public.suggested_flashcards() is
  'The reader''s met Pulls, most due for review first, as flashcard terms (headline) and '
  'definitions (body). Invoker rights: RLS on knowledge_states and pulls is the whole of its '
  'privacy. Read-only; see 20260928100000.';

revoke all on function public.suggested_flashcards() from public, anon, authenticated, service_role;
grant execute on function public.suggested_flashcards() to authenticated;
