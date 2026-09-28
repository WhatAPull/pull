# Flashcards

A reader's own sets of terms and definitions — typed, pasted from Quizlet or a spreadsheet,
or opened from an Anki text export — and four ways to study one in a sitting. Free, private
and offline: what other apps sell as their core, this one treats as a list of rows and some
arithmetic in the browser.

The schema is `supabase/migrations/20260926100000_flashcards.sql`. Its behaviour is asserted
in `supabase/tests/flashcards.sql`, as the `authenticated` role under RLS. The rules the
screens follow are pure functions in `apps/web/src/lib/flashcards.ts` (studying),
`apps/web/src/lib/flashcards-import.ts` (text in and out) and their tests; the calls are in
`apps/web/src/lib/flashcards-api.ts`.

**Spaced review across sets is next (PR 13)**: a memory per card and a queue of what is due,
across every set a reader has. Nothing in this page records how a reader did. The one thing
this page does for it is keep a card's id stable across every edit of its set, so a memory
has something to be keyed on.

## The shape

```
flashcard_sets ─── flashcards     a set, and its cards in order
```

- **A set** (`flashcard_sets`) is a title (1–200 characters), an optional description (up
  to 2,000), and optionally the language each side is written in (`term_lang`,
  `definition_lang`: a tag such as `es` or `pt-BR`). The languages are read by one thing
  only: choosing a voice on the device for Listen.
- **A card** (`flashcards`) is a term (1–1,000 characters) and a definition (1–2,000), with
  its `position` in the set. Its id is kept across edits: changing the term, the definition
  or the order never makes a new card. `unique (owner_id, id)` is what a per-card memory's
  foreign key will reference, and the same index serves the account export and the count
  the total limit takes.
- **Blank means one thing.** Every text is stored trimmed of what JavaScript's `.trim()`
  takes off — the Unicode spaces, the line breaks, tab, and U+FEFF, as
  `study_space_class()` spells them — by `flashcard_trim`, and the tables' checks use the
  same function. A title of one no-break space is blank to the editor and to the database
  alike. `flashcard_trim` has a standard body, so Postgres records that it calls
  `study_space_class()` and refuses to drop that function from under the checks; redefining
  it would change what they accept, which its comment says. Lengths are characters (code
  points) on both sides: the editor counts them, not JavaScript's UTF-16 units, and a box
  stops typing only at twice its limit, so it never cuts a text the database would take.
- **Private, and nothing else.** One policy each, `for select to authenticated using
(owner_id = (select auth.uid()))`. anon can read neither table, and no role has a write
  grant on either: the two functions below are the only way in, because the limits are
  properties of a reader's whole collection, which a row policy cannot see. A set is never
  published and never joins the catalogue (`docs/content-policy.md`).
- **Limits**, against abuse rather than as a tier: 500 sets a reader; 2,000 cards and 2 MB
  of text a set (its title, description and every side, trimmed, in UTF-8 bytes); and
  20,000 cards across all of a reader's sets. The last two are what make the first two safe
  to multiply: without them one account could store 11.5 GB of four-byte characters in a
  scripted afternoon, and with them it is at most 20,000 cards of 12 KB.
- Both tables are in the account export (`account-api.ts`), and go with the account: a set
  cascades from `auth.users`, and its cards from the set.

## Saving and deleting

`save_flashcard_set(p_set jsonb)` makes the reader's set be what it is sent:

```
{ id?, baseUpdatedAt?, title, description?, termLang?, definitionLang?,
  cards: [{ id?, term, definition }] }
→ { id, updatedAt, cards: [{ id, position }] }
```

- **An upsert by the client's id.** A set that does not exist is created under the id sent,
  so a save retried after its response was lost finds the set it made. The web mints every
  id — the set's when the New set screen opens, a card's when its row is made — so a retry
  is exact.
- **Cards keep their ids.** A card whose id is in this set keeps it, with its term,
  definition and position updated. A card whose id exists nowhere is inserted under it; one
  without an id is given one. Cards of the set the payload leaves out are deleted.
  Positions are the array's order, 0 to n−1.
- **A card is never moved.** An id that belongs to another set — the reader's own or anyone
  else's — is malformed input, since a card's future memory would move with it.
- **`updated_at` moves only when something changed** — a field, a card's words or place, a
  card added or taken out — so opening and saving a set untouched does not reorder the
  reader's list. A card's own `updated_at` moves when it does.
- **Two screens do not save over each other unseen.** `baseUpdatedAt` is the `updatedAt`
  of the set the editor began from, exactly as the API gave it (to the microsecond; never
  round-tripped through a `Date`). A save from a set that has changed since — saved in
  another tab or on another device — is refused as `40001 changed` when it would change the
  set again, and a save to a set deleted since as `P0002`. Without it a tab left open on old
  cards saved them back, deleting every card another tab had added, and a stale tab could put
  back a set deleted elsewhere. **A retry is not a conflict**: a save that landed and lost its
  answer, sent again as it was, names a base its own first attempt made stale, and was refused
  as changed — the editor then told the reader the set had been changed somewhere else, which
  it had not. So a stale base is refused only when the save would change the set's fields or
  its cards (their ids, words and order, as stored); one that would change nothing is made as
  nothing, and answers with the time the set is at. On a refusal the editor asks:
  **Load the latest, and let mine go**, or **Save mine over it** — the same save sent without
  `baseUpdatedAt`, which is the reader's word, and for a deleted set puts it back with what
  they saved (**Put it back, as it is here**) or leaves it deleted.
- One save at a time per reader (`pg_advisory_xact_lock` on `flashcards:<uid>`), taken before
  anything is counted, so two tabs cannot race any limit. The set's row is not locked first,
  since that would lock another reader's row before its owner is known. The reader's own
  `auth.users` row is read key-share locked, as the study doors read it: an account being
  deleted waits for a save to finish, and a save that arrives during the deletion waits for it
  and is refused `28000` -- unlocked, it failed on its own foreign key, or deadlocked the
  deletion. A file of SQL is one session and cannot race itself, so
  `scripts/test-flashcards-lock.mjs`, in `pnpm db:test`, runs sessions side by side: the
  second of two saves is seen waiting on the first, and is refused at the total once the first
  commits; and a save beside its account's deletion is seen waiting, and is no reader.

`delete_flashcard_set(p_id uuid)` deletes the reader's set and its cards, under the same
lock, and answers true. A set that does not exist, was already deleted, or is somebody
else's all answer false — one answer, so an id says nothing about whose it is. With no
reader in the request it is refused `28000`.

Neither function is executable by anyone but `authenticated`: not `anon`, and not
`service_role`, since nothing server-side writes a reader's sets.

### Refusals

| SQLSTATE | DETAIL    | Why                                                                                                                                                                                                                            |
| -------- | --------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `28000`  |           | No reader in the request, or a token whose account no longer exists -- or was deleted while the save waited for it                                                                                                             |
| `42501`  | `guest`   | A guest session, read from `auth.users.is_anonymous` rather than the token's claim. A guest's rows are swept a day after last use                                                                                              |
| `22023`  |           | Malformed: not an object; an id that is not a uuid; a base that is not a time; a title, description, language, term or definition out of range; cards not an array or empty; a card id given twice; a card id from another set |
| `40001`  | `changed` | `baseUpdatedAt` is not the set's `updated_at` — it changed since the editor opened it — and this save would change it: a field, or a card's id, words or place                                                                 |
| `54000`  | `sets`    | The reader has 500 sets and this would be another                                                                                                                                                                              |
| `54000`  | `cards`   | More than 2,000 cards                                                                                                                                                                                                          |
| `54000`  | `size`    | More than 2 MB of text in the set, trimmed, in UTF-8 bytes                                                                                                                                                                     |
| `54000`  | `total`   | More than 20,000 cards across the reader's sets, counting this set as sent rather than as it was — so a set at the limit can still be saved, and made smaller                                                                  |
| `P0002`  |           | The id is another reader's set, or — with `baseUpdatedAt` — no set at all. It says only that the id is taken or free — out of 2^122 — and nothing of that set is read                                                          |

PostgREST answers `40001`, `54000` and `P0002` with HTTP 500 and the SQLSTATE and DETAIL in
the body, as it answers every such refusal in this repository (`docs/study-courses.md` says
the same of `P0002`); the web reads the body, never the status.

The web says each in words (`saveRefusal` in `lib/flashcards.ts`), and checks the same
rules in the editor first (`validateDraft`), so the database's refusals are its second line
rather than its first.

## Reading

Plain selects under RLS, and **paged**: the API answers at most 100 rows a request
(`max_rows` in `supabase/config.toml`), and that holds inside an embed too — measured, a
set of 150 cards embedded as `flashcards(*)` came back with 100. So:

- **The list** is `flashcard_sets` with `flashcards(count)` — an embedded count works through
  the composite foreign key — read 100 at a time **by id**, each page after the last id
  read, and sorted by `updated_at` in the browser. It was paged by `updated_at`, which a
  save moves: a set saved while the later pages were on their way jumped to the first page,
  already read, and was left out. The sets are counted before the first page and again after
  the last, and the list is complete — no set made or deleted while it was read — only when
  both counts are its length, which only a complete list may be trusted to say when it comes
  to pruning this device's copies (below). One count, the first, missed a set made after the
  first page with an id before the cursor: neither read nor counted. Two cannot tell a set
  made behind the pages from another deleted in the same moment, since both counts still
  agree; that window is the length of a read, and what it costs is this device's copy of the
  new set, its round and its best time, not the set, which the next opening reads back. A
  count after the last page that fails leaves the list shown and called incomplete: every
  page was read, and only what may be pruned is unknown.
- **A set** is its row, then its cards by `position` in parallel pages of 100, then its
  `updated_at` again. A set that changed while being read — its time moved, or its card count
  disagrees — is read again from the start, up to three times.

## Making a set

- **New set** (tab state on `/flashcards`): a title, an optional description, a language
  for each side (a short list, and Other… for any tag), and rows of term and definition.
  Rows are added, removed and moved up or down with buttons — nothing needs a drag. A row
  with both boxes empty is an unused row and is left out; a row with one side typed is said
  by number ("Card 3 needs a definition") rather than dropped.
- **Edit** (tab state on `/flashcards/:id`) is the same editor over the saved set, with
  **Add from text** to append cards from the importer below. After a save the set is read
  back from the account, so what is studied and kept offline is what the account holds.
- **Leaving with changes not saved asks once**, as a course correction does: the first press
  of Cancel or the way back says so beside it, and the second leaves.
- **Any other way out keeps them.** The draft is kept in this tab's `sessionStorage`
  (`wap:flashcards:draft:<reader>:<set or new>`) while it differs from the set — written a
  moment after typing stops, and at once when focus leaves the editor — and the editor,
  opened again, starts from it and says "Your unsaved changes were kept." Closing or
  reloading the tab asks first (`beforeunload`). The draft goes when it is saved or let go,
  when the set is deleted on this device, and when the reader signs out or deletes their
  account. There is no guard on the app's own navigation: the draft is what makes one
  unnecessary.
- **A key draws no row.** The card boxes are the browser's own (`defaultValue`), each row is
  memoised with stable handlers, and the list is drawn from a deferred copy of the cards, so
  typing into a set of 1,200 cards costs a few milliseconds of React a key rather than
  drawing 2,400 boxes.
- **A row's buttons name its card, not its place**, since the place a row is drawn with is a
  draw behind: Remove card 970 and, within that draw, Remove card 975 took card 976. Remove,
  Up and Down find the card where it is when the press lands, a press on a card already gone
  does nothing, and what is said ("Card 974 removed.") is the card's place as it was then —
  said again when the same words come twice.
- **Held while it saves.** Every box and button of the editor is held (a disabled fieldset,
  recoloured rather than faded) until the save answers, and focus in them moves to Save,
  which says "Saving…" before it is focused; the editor's bar says so too, in a line always
  drawn and shown only then, so a long title that wraps it moves nothing. What was typed in
  between used to reach neither the set — the save carries the draft as it was when Save was
  pressed — nor the kept draft, which the editor lets go once a save succeeds. The ways out
  and the conflict's choices wait too: Cancel during a save said the changes were not saved,
  and then the save landed and took the reader out of whatever they had gone on to. Pressing
  "Save mine over it" moves focus to Save as well. The importer holds itself rather than
  sitting in the fieldset, whose disabled radios a browser draws too faint to tell the chosen
  one: its boxes are read-only, its radios ignore a change, and its Add waits. Import holds
  its title, its box, its separators and its way out the same way, so a failure is said where
  it happened. A new set's save opens the set if the reader is still on the screen they
  pressed Save on — the screen, not the set's id, since a kept draft goes on under the id its
  first screen minted. "Saved." is shown with the overview and said once focus is on the
  set's title, not with the move, which read the heading over it.
- Saving needs a connection; offline, Save says why instead of failing.

## Suggested from your reading

The list offers a set made from what the reader has read: the Pulls they have met
(`knowledge_states`), most due for review first, each as a card from its headline to its body
(`suggested_flashcards()`, `20260928100000`). It is a join and nothing else: no model, no new
text, and the text is our own analysis of the work, not the work (laws 2 and 4).

- **Invoker rights.** The function reads as the reader, so the policies on `knowledge_states`
  and `pulls` are the whole of its privacy. `supabase/tests/flashcards.sql` asserts that one
  reader never sees another's, and that the function stays SECURITY INVOKER.
- **At most thirty cards,** and offered only from three. They are trimmed and cut to the card
  limits in the browser (`suggestedCards`), because `flashcard_trim` is not a reader's to call;
  the save trims again as it always does.
- **An offer, then an ordinary set.** "Add as a set" saves the cards through
  `save_flashcard_set` under an id fixed when the suggestion was read, so a retried add makes
  one set. From then on the set is the reader's own, like any other, and nothing about how they
  study it is recorded. Studying it does not move the Delta.
- **Online only.** Offline, or if it cannot be read, the offer is simply not made.

## Importing

**Import a set** on `/flashcards`, and **Add from text** in the editor, take pasted text or a
`.txt`, `.csv` or `.tsv` file, read in the browser and never uploaded.

- **Separators** are Quizlet's own choices — between term and definition a **tab**, a
  **comma** or something **custom**; between cards a **new line**, a **semicolon** or
  something custom — plus a **dash** (`term - definition`, with its spaces), because that
  is how people type a list by hand. The defaults are a tab and a new line, which is
  Quizlet's export: it pastes straight in.
- Each card is split at its **first** separator, so a definition keeps any of its own
  (`hacer, to do, to make` is `hacer` and `to do, to make`) — except a tab, which nobody types
  into a definition: after a tab a third field is a column (below). Both sides are trimmed.
- **A comma and new lines is CSV**, and read as CSV: a field in double quotes may hold
  commas, line breaks and `""`. A quote opens a quoted field only at the start of a field,
  as `parseCsvRecords` in `lib/ingestion.ts` reads it (a separate parser here, because this
  one has to say which line each card began on). A quote that never closes is read as a
  character, so one stray quote costs one card its punctuation rather than swallowing the
  rest of the file.
- **Past two columns.** Empty fields at the end of a row are a spreadsheet's empty columns
  and are dropped (`dog,perro,,` is `perro`). More fields than two are joined back into the
  definition only when none of them was quoted and the separator is typed text — a comma, a
  dash or a custom one: `hacer, to do, to make`, split at the first separator as Quizlet
  splits it. A quoted field, or one after a tab, is a column its writer meant, so a third one
  is left out, and the preview says how many lines had columns left out.
- **Anki's text export**: its header lines — Anki's own keys only (`#separator:tab`,
  `#html:true`, `#tags column:3` and so on), and only in the block the file begins with —
  are skipped; a card may begin with `#`, or look like `#define: a macro`, anywhere. The
  columns its header names as Anki's own — guid, note type, deck and tags — are taken out
  before the term and definition are read. Its fields are read quote-aware whatever its
  separator, since Anki quotes a field holding a separator, a quote or a line break. When the
  header says the fields are HTML, a `<br>` becomes a line break and other tags go. A file's
  separators are guessed from its name and Anki's `#separator:` line; the reader can change
  them.
- A spreadsheet's header row (`Term, Definition`, `Front, Back`) on the first line is
  skipped, and the preview says so — which also means a set whose first card is literally
  `Term` / `Definition` loses it on a round trip, visibly.
- **Bounded.** Text over 8 MB, pasted or opened, is not read (a set holds 2 MB); reading
  stops at 20,000 lines — ten for every card a set holds — and says so; and the preview draws
  the first 200 cards and 200 problems, with the count of the rest. Reading is linear: a quote
  opening a field once copied the record so far (one line of `"",` forty thousand times took
  seven seconds), and an HTML tag was looked for to the end of its field. The box has no
  `dir="auto"`, which had the browser weigh the whole paste — fourteen seconds for a megabyte,
  and a paste of eight never came back to say it was too long; its direction is its first
  letter's, looked for in its first 400 characters (`leadingDirection`).
- **Encodings.** A file is read as UTF-8, or as UTF-16 when it begins with UTF-16's mark —
  what Excel's "Unicode Text" writes. Null characters, which no set can hold (Postgres text
  cannot), are taken out of whatever is read, and the preview says how many: a file full of
  them is usually UTF-16 without its mark.
- **Add waits for the preview.** The text is read a draw behind the typing, and until that
  draw comes Add is held, so it never takes the cards of the text before a paste.
- **Nothing is dropped silently.** A blank line is nothing; every other line either becomes a
  card or is listed under the preview with its line number and why — no separator, no term,
  no definition, a side too long. The preview lists the cards before anything is saved, and
  enforces the 2,000-card limit there: past the room left in the set, the rest are counted
  and not taken.

## Downloading

**Download as text** writes `<title>.txt`: a card a line, a tab between term and definition,
UTF-8 — what Quizlet's import, Anki's Import File and Import a set all read with their
defaults. A tab or line break inside a side becomes a space, so the file cannot split a
card. The text is otherwise as typed: the formula defusing `lib/export-formats.ts` applies
to its CSV is not applied, because this file is offered as `.txt` for a flashcard app
rather than a spreadsheet, and a stray apostrophe on every `+1` and `=` in a reader's own
set would be a corruption, not a protection. Download works offline.

## Studying

All four modes are tab state on `/flashcards/:id` — a mode is something done in a set, not
an address — and all four run in the browser. Every shuffle is seeded (`seededShuffle` in
`lib/activities.ts`) by a seed made when the mode is entered, joined with the card's id
where the order is per card, so nothing reorders under the reader between renders; a new
sitting (Shuffle, Retake, Play again) is a new seed. A typed answer is graded by
`gradeCloze` — exact, or close by its slip rule, with marks such as `+` compared — the rule
the rest of the app grades typed recall with, against the card's own answer; another card's
answer that is right for the prompt (below) is right typed as it is. Every mode has
**Answer with: Term / Definition**; the other side is the prompt. Esc, or **Back to the
set**, leaves a mode, and focus moves to the new heading on every screen change — except that
Esc does not leave a Test with answers not yet submitted, or a Learn with anything answered
and not all learnt: it was one key between a keyboard reader and a whole sitting thrown
away. It says so instead, to a screen reader — from a radio too, where focus sits after most
answers — and the words go once there is nothing left to lose. **Back to the set**, which
has to be pressed, still leaves them.

**Distractors** are the set's own other cards' answers on the side being answered: each
once, and never one a reader would take for the right answer — two answers with the same
`normaliseAnswer` letters and `semanticMarks` are one answer, and **the answer of another
card with the same prompt is a right answer too** ("bank": a river's edge, and a lender), so
it is never a wrong option or a false statement, and is accepted when chosen or typed —
typed by its key (`answerKey`: the same letters and marks), a lookup, while the slip rule is
for the card's own answer alone. Held to every answer of its prompt by the slip rule, a
prompt 1,997 cards share made marking a Test of 2,000 take 77 seconds; it takes tens of
milliseconds. So a set of four or more offers four choices, a set of two or three offers two
or three, and a card with nothing to choose between is asked in writing.

**Keyed once.** Each card's answer and prompt are keyed once per set and side, kept against
the cards array itself (a `WeakMap`), and three distractors are drawn from a seeded order of
the set's answers (`seededDraws`, `seededShuffle`'s order read one item at a time) rather
than by shuffling the whole set for each question. Opening Learn on 2,000 cards took 46
seconds and a Test of all of them 32; both now take tens of milliseconds, and a question
drawn on each key typed is a lookup.

### Flashcards

One card at a time: the prompt side, then **Show answer** puts the other side below a
hairline rule, in the page's flow. There is no flip — `PullCard.tsx` records why the flip
went: its back face was sized by its front and scrolled long text inside itself. Previous
and Next move; Shuffle orders the round again from its first card, keeping what was
sorted; "3 of 40" says where the reader is. **Space** or **Enter** shows the answer and
**←** / **→** move, except while typing in a field or on a button, which already has them.

After the answer, **Still learning** or **Know it** sorts the card and moves on. The round
ends past its last card with the count, **Study the N still learning** (a round of just
those) and **Start over**. A card passed with Next rather than sorted counts as still
learning. The round in progress is kept in this browser's `localStorage`, keyed by reader
and set, and read back against the set as it is now — a deleted card drops out and the
place moves back with it — so a reload resumes it.

**Listen** reads a side aloud through the player, as a local-only interlude
(`lib/player.ts`): only a voice installed on the device, in the language the set gives that
side, and never stored with the queue. Without such a voice the button is not offered, so
a reader's own text is never sent to a speech service and a Spanish word is never read by
an English voice.

### Learn

Rounds of up to seven cards from those not yet mastered, in an order the seed gives. A
card is asked as **multiple choice** until it is answered right, then **written** until it
is answered right again, and is then **mastered**. A wrong answer at either stage sends it
back to multiple choice. The next round is the first seven cards not mastered: the ones
still being learnt keep their place, and each one mastered makes room for the next card of
the set. After a wrong written answer the right one is shown with **I was right**, which
counts it — the reader's own judgement, which is fine here because nothing is recorded.
Progress is "Mastered 12 of 40" on the hairline `Meter`. A card with nothing to choose
between — a set of one, or cards whose only other answers are right ones too — is asked in
writing from the start and after a miss. The end says
"You've learnt all N" and offers **Learn again**. Learn over the ones a test missed, every one
since deleted elsewhere, has nothing to ask, and says so with the way back — rather than
rounds of nothing, each over as it began. Learn answers with the term by default:
a written answer is graded exact-or-close, which is fair for a word and harsh for a
sentence.

### Test

The reader chooses the number of questions (1 to the set's size, 20 by default), the kinds
(true/false, multiple choice, written; at least one) and the side to answer with. The seed
picks the cards, the kinds are dealt among them in turn so each gets its share, and the
questions are gathered into a section per kind on one page. A **true/false** pairs the
prompt with its own answer or another card's, by the seed, about half and half. A card
dealt multiple choice or true/false with no other answer to offer is asked in writing.

**Submit** grades everything at once: "15 / 20", every question marked right or wrong in
words — "Wrong: you chose …", "you wrote …" — with the answer beside it, an unanswered
question counted wrong. A choice or a typed answer is right when it is right for the prompt:
the card's own answer, or another same-prompt card's — typed as it is. **Retake**
is a new seed; **Learn the ones you missed** opens Learn over just those cards.

### Match

Up to six cards, as twelve tiles — their terms and definitions — in a grid the seed orders.
Two cards whose tiles would read the same (`to be` and `To be.`) are never laid out
together, since the right tile and the wrong one would look alike. The set's page offers
Match when some two cards have four tiles that all read differently (`canMatch`, one pass
over the set), and the game always finds them: a seeded pick that leaves fewer than two
starts again from such a pair. The page once asked one seeded pick and the game made
another, so a set offered Match opened on "needs two cards" a third of the time. Choose a tile, then another: a card's term and its
definition clear together, and anything else is **not a pair**, said in words and marked by
a dashed border — no shake — with nothing left chosen. Choosing a tile again lets it go.

Every tile is a `<button>` with `aria-pressed`, so the game is played from the keyboard;
what happens ("Selected …", "Pair cleared", "Not a pair") is announced in a polite live
region, and a cleared tile keeps its place empty so nothing moves under the pointer. The
clock counts tenths from the first choice and stops at the last pair — "Your time 23.4 s" —
measured from each press's own time stamp. The best time for the set is kept in this
browser's `localStorage` only. **Play again** is a new seed.

## Offline

Every set a reader opens is kept in IndexedDB (`flashcardSets`, keyed `userId:setId` with a
`by-user` index; schema version 3, whose upgrade creates that store and touches nothing
else). Without a connection, `/flashcards` lists the sets on the device and a set opens from
its copy, and all four modes and Download work. When the browser says it is offline the
device is read first, at once, rather than after supabase-js has retried its way to failing
(seven seconds of "Loading…"). Making, importing, editing and deleting say they need a
connection. A copy read offline is read from the account again when the connection
returns, and a mode open on it starts afresh if the set changed meanwhile.

**What leaves the device, and when**, per device:

- A set deleted here takes its copy and every key of its with it — its round, its best
  Match time, and its draft in this tab. A draft in another tab is that tab's, and stays
  there until it is let go, or saved — when the editor, finding the set gone, asks whether to
  put it back.
- A set deleted on another device goes from this one the next time a complete list is read
  here: its copy and its round and best time, but not a draft, which is the reader's own
  unsaved typing and stays in the tab until saved or let go.
- A round is kept in `localStorage` while it runs and let go once it ends.
- Signing out clears the reader's copies and every `wap:flashcards:*:<reader>:*` key in
  `localStorage` and `sessionStorage`, as it clears the cached feed and the practice pack
  (`App.tsx`); deleting the account does the same before the page is left (`Account.tsx`),
  on the device it is deleted on.

No offline write is queued: saving is online only.

## The routes

`/flashcards` and `/flashcards/:id` are signed-in destinations, with both halves of the rule
`CLAUDE.md` describes: a `DESTINATIONS` entry marked `signedIn`, and routes rendered only for
a non-guest session, with the guest answer ("This one needs an account") for a guest who
arrives by address. `routeParam` tells the two apart — the bare prefix is no id, and a
deeper path is nobody's — and the page title is the set's own once it has loaded.
