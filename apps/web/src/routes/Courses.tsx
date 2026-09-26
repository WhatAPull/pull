import { useEffect, useRef, useState } from 'react';
import { isOfflineFailure } from '../lib/offline.js';
import {
  courseProgressLabel,
  courseStatus,
  courseTitle,
  enrolledCopies,
  type CourseSummary,
} from '../lib/study-course.js';
import { COURSE_LIST_LIMIT, fetchCourses } from '../lib/study-course-api.js';
import { PublicCourseList } from '../components/PublicCourseList.js';

function statusLine(course: CourseSummary): string {
  switch (courseStatus(course)) {
    case 'preparing':
      return 'Being prepared';
    case 'failed':
      return 'Could not be prepared';
    case 'empty':
      return 'A source was deleted';
    case 'ready':
      return courseProgressLabel(course);
  }
}

/**
 * The reader's private courses -- their own, and their copies of public courses -- each one's
 * name, where it stands and a way in; then the public courses they may add.
 */
export function Courses({
  userId,
  onNavigate,
}: {
  userId: string;
  onNavigate: (to: string) => void;
}) {
  const [courses, setCourses] = useState<CourseSummary[]>([]);
  const [more, setMore] = useState(false);
  const [settled, setSettled] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [offline, setOffline] = useState(false);
  const [attempt, setAttempt] = useState(0);
  // A public course was added below: read the list again without taking the page down, so the
  // card that was pressed keeps its place and focus.
  const [refresh, setRefresh] = useState(0);
  const quiet = useRef(false);

  useEffect(() => {
    const controller = new AbortController();
    const quietly = quiet.current;
    quiet.current = false;
    fetchCourses(controller.signal)
      .then((list) => {
        if (controller.signal.aborted) return;
        setCourses(list.courses);
        setMore(list.more);
        setError(null);
        setSettled(true);
      })
      .catch((e: unknown) => {
        if (controller.signal.aborted) return;
        console.error('Courses request failed', e);
        // A quiet refresh that fails leaves the list as it was: the copy is made either way,
        // and its card offers the way in.
        if (quietly) return;
        setOffline(isOfflineFailure(e));
        setError(e instanceof Error ? e.message : String(e));
        setSettled(true);
      });
    return () => controller.abort();
  }, [userId, attempt, refresh]);

  if (!settled) {
    return (
      <p className="meta" role="status">
        Loading…
      </p>
    );
  }

  if (error) {
    return (
      <section className="stack measure" role="alert">
        <p className="meta">Courses</p>
        <h1>Could not load your courses.</h1>
        <p>{offline ? 'You appear to be offline. Courses need an active connection.' : error}</p>
        <button
          type="button"
          className="btn btn--primary"
          onClick={() => {
            setError(null);
            setSettled(false);
            setAttempt((n) => n + 1);
          }}
        >
          Try again
        </button>
      </section>
    );
  }

  return (
    <section className="stack measure">
      <p className="meta">Courses</p>
      <h1>Study your own material.</h1>
      <p>
        A course is made from sources you saved in Studio: short lessons, each tied to the passages
        of your text it rests on, in sessions of about ten minutes with a clear place to stop. You
        can also add one of the public courses below, which we prepared from works in the public
        domain or licensed to us.
      </p>
      {courses.length === 0 ? (
        <>
          <p className="meta">You have no courses yet.</p>
          <p>
            <button
              type="button"
              className="btn btn--primary"
              onClick={() => onNavigate('/studio?view=study')}
            >
              Prepare study material in Studio
            </button>
          </p>
        </>
      ) : (
        <>
          <ol className="courses__list">
            {courses.map((c) => (
              <li key={c.courseId} className="courses__item">
                <button
                  type="button"
                  className="btn btn--plain courses__title"
                  onClick={() => onNavigate(`/course/${encodeURIComponent(c.courseId)}`)}
                >
                  {courseTitle(c)}
                </button>
                <span className="courses__status">{statusLine(c)}</span>
                {c.publicCourseId && (
                  <p className="meta">
                    {c.publicCourseWorkTitle
                      ? `Public course · a course on ${c.publicCourseWorkTitle}`
                      : 'Public course'}
                  </p>
                )}
                {c.title && <p className="meta">Goal: {c.goal}</p>}
              </li>
            ))}
          </ol>
          {more && (
            <p>
              Showing your {COURSE_LIST_LIMIT} newest courses. Older ones are still in your account;
              delete courses you are done with to see them here.
            </p>
          )}
          {!more && (
            <p className="meta">
              That is every course. They are private to you: your own are made in Studio, and a
              public course you add is your copy of it.
            </p>
          )}
        </>
      )}
      <PublicCourseList
        enrolled={enrolledCopies(courses)}
        onEnrolled={() => {
          quiet.current = true;
          setRefresh((n) => n + 1);
        }}
        onNavigate={onNavigate}
      />
    </section>
  );
}
