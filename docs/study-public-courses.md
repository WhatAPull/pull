# Public study courses

A reader's study course ([`study-courses.md`](./study-courses.md)) is private: made from
their own material, for them. A public course is made once by the project, from a work it
may publish from, and anyone with an account can add it to their courses. This page covers
how one is published, what it may quote, how a reader adds it, and how it is withdrawn.

The schema is `supabase/migrations/20260925230000_public_study_courses.sql`, asserted in
`supabase/tests/public_courses.sql`. CLAUDE.md, law 2, states why this is not the Studio's
private result made public.

## Publishing

1. A curator -- an operator's own account, admitted to study courses -- saves the work's text
   as a study source and prepares a course from it through the ordinary door: consented,
   budgeted, ledgered, validated.
2. A person reviews the course: its claims against the work, its lessons and its questions.
   Corrections go through the ordinary correction path, and are checked the same way.
3. As the service role:

   ```sql
   select public.publish_study_course(
     '<generation id>', '<works.id>', '<slug>', '<reviewer>', '<what was checked>');
   ```

It is refused unless:

| Refusal             | Rule                                                                                                                  |
| ------------------- | --------------------------------------------------------------------------------------------------------------------- |
| 42501 `rights`      | The work's `rights_status` is `public_domain` or `licensed` -- never `user_owned`, `review_required` or anything else |
| 55000 `unvalidated` | The course's text is validated and validation passed a lesson in it                                                   |
| 22023 `quotes`      | Every quotation is at most 300 characters, and together at most a tenth of the source and 20,000 characters           |
| 22023               | A slug of 3 to 80 lower-case letters, digits and single hyphens, and a named reviewer                                 |

What is published is a snapshot: the validated claims, lessons and questions, and the
**excerpts** -- each quoted span once, in the source's order -- which the evidence is re-pointed
into. The source itself is never published (law 4). A `moderation_decisions` row records who
published it and why. A published course never changes; a new version is a new course.

## The catalogue

`list_public_study_courses()` and `get_public_study_course(slug)` return what a reader needs to
choose one -- title, goal, overview, objectives, the lesson outline, counts, and the work's
title and rights -- for anyone, signed in or not, and only for a course not withdrawn whose
work is still public domain or licensed. The table itself is service-role only: its snapshot
carries the answer keys. `/courses` lists them under "Public courses".

## Adding one

`enrol_public_course(public course)` copies the snapshot into the reader's own study tables:
a course (`study_courses.public_course_id`), its generation (no job, no consent -- nothing is
sent anywhere), the excerpts as a source of format `public_course`, and the claims, lessons
and questions, validated and logged as `enrolled`. From then on it is the reader's course like
any other -- progress, answers, proof of recall, the study Delta, reports and corrections all
work on their copy -- except that it is not prepared again (55000 `public`), and its excerpts
are not listed in Studio.

- One copy per reader: adding it again answers with the copy they have.
- Twenty new copies a day (54000); nothing counts against the reader's preparation allowance.
- 28000 for a guest; P0002 for a course withdrawn, or whose work's rights came into question.
- Deleting the course keeps the excerpts, and adding it again uses them.

## Withdrawing

```sql
select public.withdraw_public_study_course('<id>', '<who>', '<why>', <remove copies>);
```

Withdrawing stops new copies. With `remove copies` true -- for a rights complaint, where the
copies are what is complained of -- every reader's copy and its excerpts are deleted too. A
work whose `rights_status` leaves `public_domain` and `licensed` takes its courses out of the
catalogue at once, without anyone withdrawing them.
