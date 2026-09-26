# Public study courses

A reader's study course ([`study-courses.md`](./study-courses.md)) is private: made from
their own material, for them. A public course is made once by the project, from a work it
may publish from, and anyone with an account can add it to their courses. This page covers
how one is published, what it may quote, how a reader adds it, and how it is withdrawn.

The schema is `supabase/migrations/20260925230000_public_study_courses.sql`, asserted in
`supabase/tests/public_courses.sql`. CLAUDE.md, law 2, states why this is not the Studio's
private result made public.

## Publishing

1. **Name a curator.** An operator's own account, admitted to study courses, and added by the
   service role:

   ```sql
   insert into public.study_curators (user_id, added_by) values ('<auth.users.id>', '<who>');
   ```

   Only a curator's course is ever published. A reader's course cannot be, whatever else is
   true of it.

2. **Register the text.** The curator saves the work's text as a study source. Before the
   course is prepared, the service role registers that saved version as the work's text:

   ```sql
   insert into public.study_curated_sources (source_version_id, work_id, registered_by)
   values ('<study_source_versions.id>', '<works.id>', '<who>');
   ```

   Every source the course is prepared from must be registered to the work it is published
   from, so a course is published only from the text that was cleared, never from anything
   else the curator happened to save.

3. **Prepare and review.** The curator prepares a course from it through the ordinary door:
   consented, budgeted, ledgered, validated. A person reviews it: its claims against the
   work, its lessons and its questions. What is wrong is reported, and held back with what
   rests on it; what needs rewording is corrected through the ordinary correction path, and
   checked the same way.

4. **Publish**, as the service role:

   ```sql
   select public.publish_study_course(
     '<generation id>', '<works.id>', '<slug>', '<reviewer>', '<what was checked>');
   ```

It is refused, in this order, with:

| Refusal              | Unless                                                                                                                                                                                                                                                                   |
| -------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| 22023                | The slug is 3 to 80 lower-case letters, digits and single hyphens, and a reviewer is named                                                                                                                                                                               |
| P0002                | The generation exists                                                                                                                                                                                                                                                    |
| 55000 `public`       | It is not a reader's copy of a public course                                                                                                                                                                                                                             |
| 42501 `curator`      | Its owner is a curator                                                                                                                                                                                                                                                   |
| 55000 `unvalidated`  | Its text is validated, validation passed a lesson in it, and a lesson of it is validated now                                                                                                                                                                             |
| 55000 `superseded`   | It is its course's current generation                                                                                                                                                                                                                                    |
| 55000 `published`    | It was not published before                                                                                                                                                                                                                                              |
| P0002                | The work exists                                                                                                                                                                                                                                                          |
| 42501 `rights`       | The work's `rights_status` is `public_domain` or `licensed` -- never `user_owned`, `review_required` or anything else                                                                                                                                                    |
| 42501 `unregistered` | Every source of the generation is registered to that work                                                                                                                                                                                                                |
| 22023 `too_large`    | It has at most 400 validated claims and 300 validated questions                                                                                                                                                                                                          |
| 22023 `quotes`       | Every quotation is at most 300 characters -- spans that overlap or lie within 200 characters of each other are one quotation, gap and all -- and together at most a tenth of the source; and the work's courses on offer quote it at most 20,000 characters between them |
| 22023 `copied`       | The course's own words -- title, goal, overview, objectives, lessons, claims, questions, answers -- do not repeat twelve words in a row of the source from outside its quotations                                                                                        |

The work's row is locked while its rights are read and its quotations counted, so two
publications of one work cannot each count without the other.

**What is published is a snapshot**: the validated claims, the validated lessons, and the
validated questions -- except a question whose lesson is held back, or which rests on a claim
that is not published. With them go the **excerpts**: each quotation once, in the source's
order, which the evidence is re-pointed into. The source itself is never published (law 4).
Who wrote each lesson and question goes with it; a `moderation_decisions` row records who
published it and why. A published course never changes: the row refuses every update but
its withdrawal, the service role can only read it, and it cannot be truncated. A new version
is a new course.

**What the schema cannot check.** It measures quotations against the text the service role
registered, so a tenth of that text is a tenth of the work only if the registered text is the
work. And a lesson that paraphrases a passage closely enough to replace it repeats no twelve
words of it. Both are what the review in step 3 is for; the caps are what no review can
exceed.

## The catalogue

`list_public_study_courses()` and `get_public_study_course(slug)` return what a reader needs to
choose one -- title, goal, overview, objectives, the lesson outline, counts, when it was
published, and the work's id, title and rights -- to a signed-in reader, and only for a course
not withdrawn whose work is still public domain or licensed. A visitor is refused (42501);
the app offers public courses on `/courses`, which it shows only to a signed-in reader.

The table itself is service-role only. Not for its answer keys -- a reader who adds a course
has its questions and answers in their copy -- but so that its excerpts, the work's own words,
reach a reader who added the course and nobody else: no visitor, no scraper of the API, and
nobody at all once the course is withdrawn or its work's rights come into question. The
reviewer's name and note stay the project's record.

## Adding one

`enrol_public_course(public course)` copies the snapshot into the reader's own study tables:
a course (`study_courses.public_course_id`), its generation (no job, no consent -- nothing is
sent anywhere), the excerpts as a source of format `public_course`, and the claims, lessons
and questions, validated and logged as `enrolled`. From then on it is the reader's course like
any other -- progress, answers, proof of recall, the study Delta, reports and corrections all
work on their copy -- except that it is not prepared again (55000 `public`), nothing is
prepared from its excerpts (55000 `public`), nothing is saved into them (55000 `public`), and
they are not listed in Studio nor counted against the reader's 100 versions or 1,000 saves.

A lesson or question the curator corrected is `authored_by = 'project'` in the copy: not the
reader's own words, so the app never presents it as theirs, and -- reviewed by a person, and
not written by the reader -- an answer to it proves recall as an answer to the model's does.

- One copy per reader: adding it again answers with the copy they have, and is not counted.
- Twenty enrolments a day (54000), counted from `study_public_enrolments` since 00:00 UTC: a
  copy deleted and added again is two. Nothing counts against the reader's preparation
  allowance.
- 28000 for a guest; P0002 for a course withdrawn, or whose work's rights came into question.
- Deleting the course keeps the excerpts, and adding it again uses them.
- The reader's copy says where it came from -- the work, and its rights while they hold
  (`public_study_course_origin`, readable only by a reader with a copy).
- The study beta's dashboards ([`study-beta.md`](./study-beta.md)) leave copies out, and
  what a reader does in one: they measure courses prepared from readers' own material, and an
  enrolment would otherwise read as a course prepared and a generation validated.

## Withdrawing

```sql
select public.withdraw_public_study_course('<id>', '<who>', '<why>');
```

Withdrawing takes the course out of the catalogue and stops new copies; an enrolment in
flight finishes first, and the next is refused. It touches nobody's copy, and records a
`moderation_decisions` row each time it is called; the first withdrawal's time and reason
stand.

For a rights complaint, where the copies are what is complained of, remove them after
withdrawing:

```sql
select public.remove_public_course_copies('<id>', 100);  -- until it returns 0
```

Each call removes the copies of up to that many readers, in owner-id order, taking each
reader's study lock before any row of theirs ([`study-courses.md`](./study-courses.md), "Lock
order"), and returns how many readers it went through. With the copy go the reader's
answers, progress, memory and reports on it. The log of enrolments stays. It is refused
(55000) while the course is on offer.

A work whose `rights_status` leaves `public_domain` and `licensed` takes its courses out of
the catalogue at once, without anyone withdrawing them. Readers' copies stay, and stop naming
the work's rights.

## Deleting

A public course outlives the curator's account and the generation it was published from: it
is a snapshot. It goes only once withdrawn and with no copies left, and only as the database
owner:

1. `withdraw_public_study_course`, then `remove_public_course_copies` until it returns 0;
2. `delete from public.public_study_courses where id = '<id>'` -- its log of enrolments goes
   with it.

A work with a public course is not deleted (`on delete restrict`): delete its courses that
way first. Deleting the work then takes its registered texts in `study_curated_sources`.
