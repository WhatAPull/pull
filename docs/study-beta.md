# The study beta

Study courses ([`study-courses.md`](./study-courses.md)) have been open only to readers on
an allowlist. This page covers opening them to every reader with an account: the bar a
release has to clear, the one switch that opens and closes them, what is measured while
they are open, and where an operator reads it.

The schema is `supabase/migrations/20260925220000_study_beta.sql`, asserted in
`supabase/tests/study_beta.sql`. Nothing here calls a model (law 2), and opening the beta
loosens none of the bounds law 2 names: the global daily ceiling, each reader's share of
study spend, and the per-reader job counts bound a day, open or not. It adds one: study
courses, every reader's together, are held to `study_daily_cap_cents()` -- 100 cents, half
the day -- at the door and at each reservation, so an open beta cannot leave the catalogue's
generation nothing. The door refuses once less than `study_min_job_cents()` (31 cents, a
course's reservation at its output ceilings) of the 100 remains, counting what is billed and
what is held for calls in flight: the ceiling bounds what study courses spend in a day, not
how many are made -- as many as their billed cost allows, which is usually more than three,
while one long course can bill up to its reader's share. Opening widens who may ask, not what
a day can spend.

## The release gate

The bar is [`eval/study-quality.md`](./eval/study-quality.md)'s: a human-reviewed fixture
of at least 24 source versions with visible questions and 300 visible questions, every
visible question reviewed twice and adjudicated, no material error in a visible answer
key, every visible question grounded and answerable, at most 3% ambiguous questions,
adversarial items present, each reviewed twice and none reaching a learner, every fixture
category covered, a ledger entry for every provider attempt, and one pipeline for the whole
run: the prompt, schema and model that extracted its claims (`study_claims`), and those that
assembled its courses (`study_generations.assembly_provenance`). An edit to either prompt is
a new pipeline.

1. Run the fixture through the pipeline and export it from the database it ran against --
   `DATABASE_URL` names it, and without one the export reads the local stack:
   `DATABASE_URL=... node scripts/study-eval-export.mjs --manifest m.json --reviews r.json --jobs ... > run.json`.
   Exporting the same run again writes the same file, so its digest can be checked later.
2. Evaluate it: `node scripts/study-eval.mjs run.json > report.json`.
3. Record it, as the database owner (the SQL editor, or psql with the owner's password),
   pasting the report between the dollar quotes, which a quote inside it cannot close:

   ```sql
   insert into public.study_release_gates (recorded_by, fixture_digest, report, note)
   values ('<operator>', '<sha256 of run.json>', $report$<report.json>$report$::jsonb,
           '<what was run>')
   returning id, passed, ran_at;
   ```

The insert answers with the gate's id, which opening takes, whether it passed, and when its
run was made. `passed` is computed on insert by `study_gate_passes`, from the report's gates **and** the
counts behind them -- each a whole number, not below zero -- never taken from the writer: a
report whose gates say ready while its counts fall short does not pass. The run's date
(`ranAt`, the last preparation in it, in UTC as the export writes it:
`2026-09-20T10:00:00.000000Z`) and pipeline come from the report, which the export takes
from the generations and claims themselves; a gate is as fresh as its run, not its
recording. A word Postgres reads as a time (`now`, `epoch`), an infinity, or a time without
its zone is refused. A gate is final once recorded, and a run's report is recorded
once: the same run evaluated again after a fix to the evaluator is a new report, recorded
beside the first and as old as the run. The run export and the reviewed material stay
outside the public repository; the digest ties the record to them.

What the schema checks is the report. That a person reviewed the run is the operator's
word, recorded with their name: the schema cannot see a review happen, and does not say it
can. What it can do is keep the word from the service role, whose key every Edge Function
holds: the gates, the switch and its log are written by the database owner, `postgres`, and
no one else. On the hosted project that is everyone with SQL access to it -- the dashboard's
SQL editor, the Management API and the Supabase MCP server all run as `postgres`, as does
psql with the owner's password -- so `study_beta_log.db_user` reads `postgres` for every one
of them. It tells the owner's writes from another role's, not one person from another; who
it was is the name they gave.

## The switch

`study_beta_settings` is one row. `study_generation_admitted(reader)` -- the allowlist, or
the row saying open -- is what both doors ask: `study_generation_available()`, which the
builder reads, and `study_enqueue_course`, which refuses with 42501 `beta` otherwise. A
guest is never admitted.

```sql
select public.open_study_beta('<gate id>', '<operator>');            -- open
select public.open_study_beta('<gate id>', '<operator>', '<reason>'); -- open, uncovered mix
select public.close_study_beta('<operator>');                         -- close
```

Opening is refused with 55000 when the gate did not pass (`gate_failed`) or its run is more
than thirty days old (`gate_stale`) -- a trigger holds the row to the same rule -- and when
the allowlisted beta so far leaves a kind of source or goal uncovered (`unrepresentative`),
unless the operator gives a reason of at least twenty characters, which is logged. An open
beta admits no one past the allowlist once its gate's run is sixty days old: it lapses
rather than stay open on a pipeline reviewed two months before. Every change is logged in
`study_beta_log`, which is only ever appended to, with the database role that made it.
Only the owner calls open and close.

Closing is always allowed. It stops new courses at the door; a course already queued for a
reader it no longer admits still finishes, within that reader's share and the study
ceiling, and `ops.study_beta_status` counts them. A change to the prompts, the schemas or the
models, of extraction or of assembly, is a new pipeline: record a new gate before opening on
it; the status view counts preparations since opening assembled, or with a claim extracted,
by a pipeline that is not the gate's.

### A representative beta

Before opening, the allowlisted beta should have prepared courses from every kind of source
and for every kind of goal -- at least three courses from at least two readers in each:

| Kind   | Values                                                                                                           |
| ------ | ---------------------------------------------------------------------------------------------------------------- |
| Source | `typed` (paste, text, markdown), `pdf`, `docx`, `scanned` (image or PDF OCR), `highlights`                       |
| Goal   | `explain`, `discuss`, `remember`, `assess` -- the builder's four suggestions -- and `own`, in the reader's words |

`study_beta_unrepresented()` lists what is short, and `ops.study_beta_mix` shows the counts.
Admit readers who cover what is missing rather than opening past it.

## What is measured

Everything is computed from rows the product already keeps, plus one stamp: an answer
records whether the study Delta counted every claim its question tests as known just before
it was given (`study_answer_events.claims_known_before`, through `study_claim_known`: the
study Delta's rule for one claim, which the suite holds to `study_claim_knowledge`'s answer
for every claim). The proof rule never reads it.

Learning is measured over deterministic answers to model-written questions; a self-graded
answer or the reader's own question proves nothing either way.

- **Seven-day unhinted recall** -- an answer given at least seven days after the reader's
  last answer to the same question (any version, however graded) was right, unhinted and
  graded by the rule: recalled when it is right and unhinted again.
- **False mastery** -- an unhinted answer to a question whose every claim was known just
  before it: false when it is wrong. This is the study Delta's false-suppression rate
  ([`study-adaptation.md`](./study-adaptation.md)), measured rather than argued.

Every rate is reported with its numerator and denominator.

## The dashboards

Schema `ops` holds aggregate views, readable by the service role and not exposed through the
API. No row in them names a reader.

| View                          | What it says                                                                                                                                                                                                                                                                                    |
| ----------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `ops.study_beta_status`       | Open or not; on which gate, its pipeline and its run's age; whether admission has lapsed; preparations since opening off the gate's pipeline; courses queued for readers no longer admitted; readers allowlisted; what the mix leaves uncovered; today's study and other spend against the caps |
| `ops.study_daily`             | By UTC day: courses made, preparation jobs by outcome, median and p95 minutes, spend in cents                                                                                                                                                                                                   |
| `ops.study_validation_weekly` | By week prepared: preparations held back or awaiting, and claims, lessons and questions passed                                                                                                                                                                                                  |
| `ops.study_learning_weekly`   | By week answered: seven-day recall and false mastery, with their counts                                                                                                                                                                                                                         |
| `ops.study_trust_weekly`      | By week: lessons shown, read and skipped, reports by target, restores, corrections, withdrawals                                                                                                                                                                                                 |
| `ops.study_beta_mix`          | Courses with a current generation, by kind of source and goal, with distinct readers                                                                                                                                                                                                            |

`node scripts/study-beta-report.mjs [--days 14] [--weeks 8]` prints them as Markdown, with
`DATABASE_URL` pointing at the database. It reads in one read-only transaction, in UTC --
said by the statement itself, since a connection pooler need not pass on the connection's
options -- and ignores the operator's `~/.psqlrc`. What the mix leaves uncovered it prints
only while the beta is closed. The hosted database needs TLS: the script asks for it,
and takes `sslmode` and `sslrootcert` from the URL -- `?sslmode=verify-full&sslrootcert=...`
with Supabase's CA verifies the server, which `require` alone does not.
