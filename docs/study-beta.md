# The study beta

Study courses ([`study-courses.md`](./study-courses.md)) have been open only to readers on
an allowlist. This page covers opening them to every reader with an account: the bar a
release has to clear, the one switch that opens and closes them, what is measured while
they are open, and where an operator reads it.

The schema is `supabase/migrations/20260925220000_study_beta.sql`, asserted in
`supabase/tests/study_beta.sql`. Nothing here calls a model (law 2), and opening the beta
changes none of the bounds law 2 names: the global daily ceiling, each reader's share of
study spend, and the per-reader job counts bound a day, open or not.

## The release gate

The bar is [`eval/study-quality.md`](./eval/study-quality.md)'s: a human-reviewed fixture
of at least 24 source versions with visible questions and 300 visible questions, every
visible question reviewed twice and adjudicated, no material error in a visible answer
key, at most 3% ambiguous questions, no adversarial item reaching a learner, every fixture
category covered, and a ledger entry for every provider attempt.

1. Run the fixture through the pipeline and export it:
   `node scripts/study-eval-export.mjs --manifest m.json --reviews r.json --jobs ... > run.json`.
2. Evaluate it: `node scripts/study-eval.mjs run.json > report.json`.
3. Record it, as the service role:

   ```sql
   insert into public.study_release_gates (recorded_by, fixture_digest, report, note)
   values ('<operator>', '<sha256 of run.json>', '<report.json>'::jsonb, '<what was run>');
   ```

`passed` is computed on insert by `study_gate_passes`, from the report's gates **and** the
counts behind them, never taken from the writer: a report whose gates say ready while its
counts fall short does not pass. A gate is final once recorded. The run export and the
reviewed material stay outside the public repository; the digest ties the record to them.

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

Opening is refused with 55000 when the gate did not pass (`gate_failed`) or is more than
thirty days old (`gate_stale`) -- a trigger holds the row to the same rule, so a direct
write cannot skip it -- and when the allowlisted beta so far leaves a kind of source or
goal uncovered (`unrepresentative`), unless the operator gives a reason of at least twenty
characters, which is logged. Closing is always allowed. Every change is logged in
`study_beta_log`. A change to the prompts, the schema or the model is a new pipeline: record
a new gate before opening on it.

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
  last answer to the same question (any version) was right and unhinted: recalled when it
  is right and unhinted again.
- **False mastery** -- an answer to a question whose every claim was known just before it:
  false when it is wrong. This is the study Delta's false-suppression rate
  ([`study-adaptation.md`](./study-adaptation.md)), measured rather than argued.

Every rate is reported with its numerator and denominator.

## The dashboards

Schema `ops` holds aggregate views, readable by the service role and not exposed through the
API. No row in them names a reader.

| View                          | What it says                                                                                                   |
| ----------------------------- | -------------------------------------------------------------------------------------------------------------- |
| `ops.study_beta_status`       | Open or not, on which gate, how many readers are allowlisted, what the mix leaves uncovered, the daily ceiling |
| `ops.study_daily`             | By UTC day: courses made, preparation jobs by outcome, median and p95 minutes, spend in cents                  |
| `ops.study_validation_weekly` | By week prepared: preparations held back or awaiting, and claims, lessons and questions passed                 |
| `ops.study_learning_weekly`   | By week answered: seven-day recall and false mastery, with their counts                                        |
| `ops.study_trust_weekly`      | By week: lessons shown, read and skipped, reports by target, restores, corrections, withdrawals                |
| `ops.study_beta_mix`          | Courses with a current generation, by kind of source and goal, with distinct readers                           |

`node scripts/study-beta-report.mjs [--days 14] [--weeks 8]` prints them as Markdown, with
`DATABASE_URL` pointing at the database (the hosted one needs TLS, which the script asks
for).
