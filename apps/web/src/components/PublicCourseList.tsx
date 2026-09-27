/**
 * The public courses a reader may add: prepared by the project from works in the public
 * domain or licensed to it, checked by a person, and copied into the reader's own courses
 * when added (`enrol_public_course`). Nothing is sent to a model and nothing is spent by
 * adding one: it was prepared once, for everyone.
 */
import { useEffect, useRef, useState } from 'react';
import { isOfflineFailure } from '../lib/offline.js';
import { sqlState } from '../lib/rpc-error.js';
import {
  asSentence,
  enrolRefusal,
  lessonCountLabel,
  publicCourseSource,
  publishedLabel,
  type Enrolment,
  type PublicCourse,
  type PublicOutlineUnit,
} from '../lib/study-course.js';
import {
  enrolPublicCourse,
  fetchPublicCourseOutline,
  fetchPublicCourses,
} from '../lib/study-course-api.js';

/** What adding a course came to, said in its card. */
export type CardNote = { kind: 'added' | 'error'; text: string };

/**
 * What adding a course came to: a copy (made, or found) -- which `courseId` names, unless the
 * answer could not be read, when the reader's own list is what will show it; a course no
 * longer offered; or a failure to say.
 */
export type EnrolOutcome =
  | { kind: 'added'; courseId: string | null; text: string }
  | { kind: 'withdrawn' }
  | { kind: 'error'; text: string };

export function enrolOutcome(
  settled: { answer: Enrolment | null } | { error: unknown },
): EnrolOutcome {
  if ('error' in settled) {
    const e = settled.error;
    // Withdrawn since the list loaded, or its work's rights came into question.
    if (sqlState(e) === 'P0002') return { kind: 'withdrawn' };
    return {
      kind: 'error',
      text: isOfflineFailure(e)
        ? 'That may not have reached your account — you look offline. Try again when you reconnect.'
        : (enrolRefusal(sqlState(e)) ?? asSentence(e instanceof Error ? e.message : String(e))),
    };
  }
  // Answered without naming the copy: the answer is the copy made, so it is said as made. The
  // reader's list is asked for again, and should show it -- should, since that read can fail.
  if (!settled.answer) {
    return {
      kind: 'added',
      courseId: null,
      text: 'Added to your courses. It should now be among your courses above.',
    };
  }
  return {
    kind: 'added',
    courseId: settled.answer.courseId,
    text: settled.answer.replayed ? 'Already in your courses.' : 'Added to your courses.',
  };
}

/**
 * Adding courses one at a time: a press while one is on its way does nothing, and answers
 * null. Held at once, not on the next render -- a second press in the same frame reads state
 * that has not caught up.
 */
export function oneEnrolmentAtATime(
  enrol: (publicCourseId: string) => Promise<Enrolment | null>,
): (publicCourseId: string) => Promise<EnrolOutcome> | null {
  let busy = false;
  return (publicCourseId) => {
    if (busy) return null;
    busy = true;
    return enrol(publicCourseId)
      .then(
        (answer) => enrolOutcome({ answer }),
        (error: unknown) => enrolOutcome({ error }),
      )
      .finally(() => {
        busy = false;
      });
  };
}

/**
 * A course's outline, as the catalogue answered for it: its units, or null for a course no
 * longer offered -- withdrawn, or its work's rights in question -- which has none to show, and
 * is not the same thing to say as a course with no lessons in it.
 */
export function OutlineBody({ units }: { units: PublicOutlineUnit[] | null }) {
  if (!units) return <p>This course is no longer offered.</p>;
  if (units.length === 0) return <p>This course has no lessons to show now.</p>;
  return (
    <ol className="course__units">
      {units.map((unit) => (
        <li key={unit.unitNo} className="course__unit">
          <h4 className="course__unit-title">{unit.unitTitle}</h4>
          <ol className="course__lessons">
            {unit.lessons.map((lesson, i) => (
              <li key={i} className="course__lesson">
                <span>{lesson.title}</span>
                <span className="course__lesson-state">{lesson.minutes} min</span>
              </li>
            ))}
          </ol>
        </li>
      ))}
    </ol>
  );
}

/** The lesson outline, loaded the first time the reader opens it. */
function OutlineDetails({ slug, titleId }: { slug: string; titleId: string }) {
  // Once answered: the catalogue's answer, held as it came.
  const [outline, setOutline] = useState<{ units: PublicOutlineUnit[] | null } | null>(null);
  const [failed, setFailed] = useState<string | null>(null);
  const [asked, setAsked] = useState(false);
  const loading = useRef<AbortController | null>(null);

  // Left, the request goes with the page.
  useEffect(() => () => loading.current?.abort(), []);

  const load = () => {
    if (outline || loading.current) return;
    const controller = new AbortController();
    loading.current = controller;
    setAsked(true);
    setFailed(null);
    fetchPublicCourseOutline(slug, controller.signal)
      .then((units) => {
        if (!controller.signal.aborted) setOutline({ units });
      })
      .catch((e: unknown) => {
        if (controller.signal.aborted) return;
        setFailed(
          isOfflineFailure(e)
            ? 'The outline needs a connection. Close this and try again when you reconnect.'
            : 'The outline could not be loaded just now. Close this and try again.',
        );
      })
      .finally(() => {
        if (loading.current === controller) loading.current = null;
      });
  };

  return (
    <details
      className="course__sources"
      onToggle={(e) => {
        if ((e.currentTarget as HTMLDetailsElement).open) load();
      }}
    >
      <summary aria-describedby={titleId}>Outline</summary>
      {outline ? (
        <OutlineBody units={outline.units} />
      ) : failed ? (
        <p>{failed}</p>
      ) : asked ? (
        <p className="meta" role="status">
          Loading the outline…
        </p>
      ) : null}
    </details>
  );
}

export function PublicCourseCard({
  course,
  copy,
  busy,
  working,
  note,
  onAdd,
  onOpen,
}: {
  course: PublicCourse;
  /** The reader's copy of it, if they have added it. */
  copy: string | undefined;
  /** A course is being added: every Add waits. */
  busy: boolean;
  /** This one is. */
  working: boolean;
  note: CardNote | null;
  onAdd: (course: PublicCourse) => void;
  onOpen: (courseId: string) => void;
}) {
  const titleId = `public-course-${course.id}`;
  const openButton = useRef<HTMLButtonElement>(null);
  const published = publishedLabel(course.publishedAt);

  // Added just now: the Add button the reader pressed is gone, so focus goes to what took its
  // place, and the note beside it says what happened.
  useEffect(() => {
    if (note?.kind === 'added') openButton.current?.focus();
  }, [note]);

  return (
    <li className="courses__item public-course">
      <h3 id={titleId} className="courses__title">
        {course.title}
      </h3>
      <p className="meta">
        {publicCourseSource(course)} · {lessonCountLabel(course.lessonCount)}
        {published ? ` · ${published}` : ''}
      </p>
      {course.goal && <p className="meta">Goal: {course.goal}</p>}
      {course.overview && <p>{course.overview}</p>}
      {course.objectives.length > 0 && (
        <div>
          <p className="meta">By the end you should be able to</p>
          <ul className="course__objectives">
            {course.objectives.map((o, i) => (
              <li key={i}>{o}</li>
            ))}
          </ul>
        </div>
      )}
      <OutlineDetails slug={course.slug} titleId={titleId} />
      <p>
        {copy ? (
          <button
            ref={openButton}
            type="button"
            className="btn btn--plain"
            aria-describedby={titleId}
            onClick={() => onOpen(copy)}
          >
            Open your copy
          </button>
        ) : (
          <button
            type="button"
            className="btn"
            aria-describedby={titleId}
            aria-disabled={busy}
            onClick={() => onAdd(course)}
          >
            {working ? 'Adding…' : 'Add to my courses'}
          </button>
        )}
      </p>
      {/* Always drawn: a live region added together with its text is not reliably announced. */}
      <p className={note?.kind === 'added' ? 'meta' : 'sr-only'} role="status">
        {note?.kind === 'added' ? note.text : ''}
      </p>
      {note?.kind === 'error' && (
        <p className="remember__error" role="alert">
          {note.text}
        </p>
      )}
    </li>
  );
}

export function PublicCourseList({
  enrolled,
  onEnrolled,
  onNavigate,
}: {
  /** The reader's copy of each public course they have added, by the public course's id. */
  enrolled: ReadonlyMap<string, string>;
  /** A copy was made or found: the reader's own list should show it. */
  onEnrolled: () => void;
  onNavigate: (to: string) => void;
}) {
  const [list, setList] = useState<PublicCourse[] | null>(null);
  const [working, setWorking] = useState<string | null>(null);
  const [notes, setNotes] = useState<ReadonlyMap<string, CardNote>>(new Map());
  // Copies made here, until the reader's own list has caught up with them.
  const [added, setAdded] = useState<ReadonlyMap<string, string>>(new Map());
  const [withdrawn, setWithdrawn] = useState<string | null>(null);
  const heading = useRef<HTMLHeadingElement>(null);
  // Made once, on the first render: the one that holds a press while another is on its way.
  const [enrol] = useState(() => oneEnrolmentAtATime(enrolPublicCourse));

  useEffect(() => {
    const controller = new AbortController();
    fetchPublicCourses(controller.signal)
      .then((items) => {
        if (!controller.signal.aborted) setList(items);
      })
      .catch((e: unknown) => {
        // The catalogue is an offer, not the reader's own courses: without it the page still
        // lists theirs, so a failure to load it is left out rather than shown as an error.
        if (!controller.signal.aborted) console.error('Public courses request failed', e);
      });
    return () => controller.abort();
  }, []);

  if (!list || (list.length === 0 && withdrawn === null)) return null;

  const note = (id: string, value: CardNote | null) =>
    setNotes((n) => {
      const next = new Map(n);
      if (value) next.set(id, value);
      else next.delete(id);
      return next;
    });

  const add = async (course: PublicCourse) => {
    const adding = enrol(course.id);
    if (!adding) return;
    setWorking(course.id);
    note(course.id, null);
    setWithdrawn(null);
    const outcome = await adding;
    setWorking(null);
    switch (outcome.kind) {
      case 'added': {
        const { courseId } = outcome;
        if (courseId) setAdded((a) => new Map(a).set(course.id, courseId));
        note(course.id, { kind: 'added', text: outcome.text });
        onEnrolled();
        return;
      }
      case 'withdrawn':
        // Not offered now, so not shown.
        setList((l) => (l ? l.filter((c) => c.id !== course.id) : l));
        setWithdrawn(`“${course.title}” is no longer offered, so it is off this list.`);
        heading.current?.focus();
        return;
      case 'error':
        note(course.id, { kind: 'error', text: outcome.text });
    }
  };

  return (
    <section className="stack public-courses" aria-labelledby="public-courses-title">
      <h2 id="public-courses-title" ref={heading} tabIndex={-1} className="course__subheading">
        Public courses
      </h2>
      <p>
        Prepared by What a Pull from works in the public domain or licensed to us, and checked by a
        person. Adding one copies it into your courses, private to you from then on. Nothing is sent
        to a model to do it, and it does not count against the courses you can prepare.
      </p>
      <p className={withdrawn ? '' : 'sr-only'} role="status">
        {withdrawn ?? ''}
      </p>
      {list.length > 0 && (
        <ul className="courses__list">
          {list.map((c) => (
            <PublicCourseCard
              key={c.id}
              course={c}
              copy={added.get(c.id) ?? enrolled.get(c.id)}
              busy={working !== null}
              working={working === c.id}
              note={notes.get(c.id) ?? null}
              onAdd={(course) => void add(course)}
              onOpen={(courseId) => onNavigate(`/course/${encodeURIComponent(courseId)}`)}
            />
          ))}
        </ul>
      )}
    </section>
  );
}
