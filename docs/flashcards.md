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
  or the order never makes a new card.
- **Private, and nothing else.** One policy each, `for select to authenticated using
(owner_id = (select auth.uid()))`. anon can read neither table, and no role has a write
  grant on either: the two functions below are the only way in, because the limits are
  properties of a reader's whole collection, which a row policy cannot see. A set is never
  published and never joins the catalogue (`docs/content-policy.md`).
- **Limits**, against abuse rather than as a tier: 500 sets a reader, 2,000 cards a set.
- Both tables are in the account export (`account-api.ts`), and go with the account: a set
  cascades from `auth.users`, and its cards from the set.

## Saving and deleting

`save_flashcard_set(p_set jsonb)` makes the reader's set be what it is sent:

```
{ id?, title, description?, termLang?, definitionLang?, cards: [{ id?, term, definition }] }
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
- **`updated_at` moves only when something changed**, so opening and saving a set untouched
  does not reorder the reader's list. A card's own `updated_at` moves when it does.
- A save after the set was deleted elsewhere puts it back, with what was saved: the reader
  pressed Save over the content on their screen.
- One save at a time per reader (`pg_advisory_xact_lock` on `flashcards:<uid>`), so two
  tabs cannot race the set limit.

`delete_flashcard_set(p_id uuid)` deletes the reader's set and its cards, under the same
lock, and answers true. A set that does not exist, was already deleted, or is somebody
else's all answer false — one answer, so an id says nothing about whose it is.

### Refusals

| SQLSTATE | DETAIL  | Why                                                                                                                                                                                                 |
| -------- | ------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `28000`  |         | No reader in the request                                                                                                                                                                            |
| `42501`  | `guest` | A guest session, read from `auth.users.is_anonymous` rather than the token's claim. A guest's rows are swept a day after last use                                                                   |
| `22023`  |         | Malformed: not an object; an id that is not a uuid; a title, description, language, term or definition out of range; cards not an array or empty; a card id given twice; a card id from another set |
| `54000`  | `sets`  | The reader has 500 sets and this would be another                                                                                                                                                   |
| `54000`  | `cards` | More than 2,000 cards                                                                                                                                                                               |
| `P0002`  |         | The id is another reader's set. It says only that the id is taken — out of 2^122 — and nothing of that set is read                                                                                  |

The web says each in words (`saveRefusal` in `lib/flashcards.ts`), and checks the same
rules in the editor first (`validateDraft`), so the database's refusals are its second line
rather than its first.

## Reading

Plain selects under RLS, and **paged**: the API answers at most 100 rows a request
(`max_rows` in `supabase/config.toml`), and that holds inside an embed too — measured, a
set of 150 cards embedded as `flashcards(*)` came back with 100. So:

- **The list** is `flashcard_sets` with `flashcards(count)` — an embedded count works through
  the composite foreign key — ordered by `updated_at` desc, read 100 at a time with the
  first page's exact count saying how many more pages there are.
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
- Saving needs a connection; offline, Save says why instead of failing.

## Importing

**Import a set** on `/flashcards`, and **Add from text** in the editor, take pasted text or a
`.txt`, `.csv` or `.tsv` file, read in the browser and never uploaded.

- **Separators** are Quizlet's own choices — between term and definition a **tab**, a
  **comma** or something **custom**; between cards a **new line**, a **semicolon** or
  something custom — plus a **dash** (`term - definition`, with its spaces), because that
  is how people type a list by hand. The defaults are a tab and a new line, which is
  Quizlet's export: it pastes straight in.
- Each card is split at its **first** separator, so a definition keeps any of its own
  (`hacer, to do, to make` is `hacer` and `to do, to make`). Both sides are trimmed.
- **A comma and new lines is CSV**, and read as CSV: a field in double quotes may hold
  commas, line breaks and `""`. A quote opens a quoted field only at the start of a field,
  as `parseCsvRecords` in `lib/ingestion.ts` reads it (a separate parser here, because this
  one has to say which line each card began on). A quote that never closes is read as a
  character, so one stray quote costs one card its punctuation rather than swallowing the
  rest of the file.
- **Anki's text export**: its header lines — `#`, a name and a colon, as in
  `#separator:tab`, `#html:true` or `#deck column:2` — are skipped, and only those: a card
  may begin with `#`. When the header says the fields are HTML, a `<br>` becomes a line break and other tags
  go. A file's separators are guessed from its name and Anki's `#separator:` line; the
  reader can change them.
- A spreadsheet's header row (`Term, Definition`, `Front, Back`) on the first line is
  skipped.
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
the rest of the app grades typed recall with. Every mode has **Answer with: Term /
Definition**; the other side is the prompt. Esc, or **Back to the set**, leaves a mode, and
focus moves to the new heading on every screen change.

**Distractors** are the set's own other cards' answers on the side being answered: each
once, and never one a reader would take for the right answer — two answers with the same
`normaliseAnswer` letters and `semanticMarks` are one answer. So a set of four or more
offers four choices, a set of two or three offers two or three, and a card with nothing to
choose between is asked in writing.

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
between (a set of one) is asked in writing from the start and after a miss. The end says
"You've learnt all N" and offers **Learn again**. Learn answers with the term by default:
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
words with the answer beside a wrong one, an unanswered question counted wrong. **Retake**
is a new seed; **Learn the ones you missed** opens Learn over just those cards.

### Match

Up to six cards, as twelve tiles — their terms and definitions — in a grid the seed orders.
Two cards whose tiles would read the same (`to be` and `To be.`) are never laid out
together, since the right tile and the wrong one would look alike; a set with fewer than two
such cards says Match needs more. Choose a tile, then another: a card's term and its
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
its copy, and all four modes and Download work. Making, importing, editing and deleting say
they need a connection. A copy read offline is read from the account again when the
connection returns.

A deleted set leaves the device with it, as does a set the account no longer has. Signing
out clears the reader's copies, as it clears the cached feed and the practice pack
(`App.tsx`), and deleting the account clears them before the page is left (`Account.tsx`).
No offline write is queued: saving is online only.

## The routes

`/flashcards` and `/flashcards/:id` are signed-in destinations, with both halves of the rule
`CLAUDE.md` describes: a `DESTINATIONS` entry marked `signedIn`, and routes rendered only for
a non-guest session, with the guest answer ("This one needs an account") for a guest who
arrives by address. `routeParam` tells the two apart — the bare prefix is no id, and a
deeper path is nobody's — and the page title is the set's own once it has loaded.
