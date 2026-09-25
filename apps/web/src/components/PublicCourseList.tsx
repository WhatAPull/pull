/**
 * The public courses a reader may add: prepared by the project from works in the public
 * domain or licensed to it, checked by a person, and copied into the reader's own courses
 * when added (`enrol_public_course`). Nothing is sent to a model and nothing is spent by
 * adding one: it was prepared once, for everyone.
 */
import { useEffect, useState } from 'react';
import { isOfflineFailure } from '../lib/offline.js';
import { sqlState } from '../lib/rpc-error.js';
import { publicCourseSource, type PublicCourse } from '../lib/study-course.js';
import { enrolPublicCourse, fetchPublicCourses } from '../lib/study-course-api.js';

/** What to say when adding a course was refused. */
export function enrolRefusal(code: string | undefined): string | null {
  switch (code) {
    case 'P0002':
      return 'That course is no longer offered.';
    case '54000':
      return 'That is as many public courses as can be added today. More at 00:00 UTC.';
    case '28000':
      return 'Adding a course needs an account, not a guest session.';
    default:
      return null;
  }
}

export function PublicCourseCards({
  courses,
  enrolled,
  working,
  onAdd,
  onOpen,
}: {
  courses: readonly PublicCourse[];
  /** The reader's copy of each public course they have added, by the public course's id. */
  enrolled: ReadonlyMap<string, string>;
  working: string | null;
  onAdd: (course: PublicCourse) => void;
  onOpen: (courseId: string) => void;
}) {
  return (
    <ul className="courses__list">
      {courses.map((c) => {
        const copy = enrolled.get(c.id);
        return (
          <li key={c.id} className="courses__item">
            <span className="courses__title">{c.title}</span>
            <span className="courses__status">
              {publicCourseSource(c)} ·{' '}
              {c.lessonCount === 1 ? '1 lesson' : `${c.lessonCount} lessons`}
            </span>
            {c.overview && <p>{c.overview}</p>}
            <p>
              {copy ? (
                <button type="button" className="btn btn--plain" onClick={() => onOpen(copy)}>
                  Open your copy
                </button>
              ) : (
                <button
                  type="button"
                  className="btn"
                  aria-disabled={working !== null}
                  onClick={() => onAdd(c)}
                >
                  {working === c.id ? 'Adding…' : 'Add to my courses'}
                </button>
              )}
            </p>
          </li>
        );
      })}
    </ul>
  );
}

export function PublicCourseList({
  enrolled,
  onNavigate,
}: {
  enrolled: ReadonlyMap<string, string>;
  onNavigate: (to: string) => void;
}) {
  const [list, setList] = useState<PublicCourse[] | null>(null);
  const [working, setWorking] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

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

  if (!list || list.length === 0) return null;

  const open = (courseId: string) => onNavigate(`/course/${encodeURIComponent(courseId)}`);

  const add = async (course: PublicCourse) => {
    if (working) return;
    setWorking(course.id);
    setError(null);
    try {
      open(await enrolPublicCourse(course.id));
    } catch (e: unknown) {
      setError(
        isOfflineFailure(e)
          ? 'That has not reached your account — you look offline.'
          : (enrolRefusal(sqlState(e)) ?? (e instanceof Error ? e.message : String(e))),
      );
      setWorking(null);
    }
  };

  return (
    <section className="stack" aria-labelledby="public-courses-title">
      <h2 id="public-courses-title" className="course__subheading">
        Public courses
      </h2>
      <p>
        Prepared by What a Pull from works in the public domain or licensed to us, and checked by a
        person. Adding one copies it into your courses, private to you from then on; nothing is sent
        anywhere to do it.
      </p>
      <PublicCourseCards
        courses={list}
        enrolled={enrolled}
        working={working}
        onAdd={(c) => void add(c)}
        onOpen={open}
      />
      {error && (
        <p className="remember__error" role="alert">
          {error}
        </p>
      )}
    </section>
  );
}
