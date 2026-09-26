import { createElement } from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { describe, expect, it, vi } from 'vitest';
import { shapePublicCourses, type PublicCourse } from '../lib/study-course.js';

// The cards are markup; the network is the list's, and is not what is under test here.
vi.mock('../lib/study-course-api.js', () => ({
  enrolPublicCourse: vi.fn(),
  fetchPublicCourseOutline: vi.fn(),
  fetchPublicCourses: vi.fn(),
}));

const { OutlineBody, PublicCourseCard, enrolOutcome, oneEnrolmentAtATime } =
  await import('./PublicCourseList.js');
const { rpcError, TRANSPORT_ERROR } = await import('../lib/rpc-error.js');

const noop = () => undefined;
const [course, single] = shapePublicCourses([
  {
    id: 'p1',
    slug: 'immediate-versus-delayed',
    title: 'Immediate versus delayed',
    goal: 'Explain the argument',
    overview: 'What the paper says about timing.',
    objectives: ['Explain the contrast.'],
    lesson_count: 2,
    work_id: 'w1',
    work_title: 'Test-enhanced learning',
    rights_status: 'public_domain',
    published_at: '2026-09-26T04:41:00Z',
  },
  {
    id: 'p2',
    slug: 'meditations',
    title: 'Meditations',
    goal: '',
    overview: null,
    objectives: [],
    lesson_count: 1,
    work_id: 'w2',
    work_title: 'Meditations',
    rights_status: 'licensed',
    published_at: '2026-09-20T10:00:00Z',
  },
]) as [PublicCourse, PublicCourse];

function card(overrides: Partial<Parameters<typeof PublicCourseCard>[0]> = {}): string {
  return renderToStaticMarkup(
    createElement(PublicCourseCard, {
      course,
      copy: undefined,
      busy: false,
      working: false,
      note: null,
      onAdd: noop,
      onOpen: noop,
      ...overrides,
    }),
  );
}

describe('PublicCourseCard', () => {
  it('says where the course comes from, what it is for and what it teaches', () => {
    const html = card();
    expect(html).toMatch(
      /A course on Test-enhanced learning · public domain · 2 lessons · Published [^<]*2026/,
    );
    expect(html).toContain('Goal: Explain the argument');
    expect(html).toContain('What the paper says about timing.');
    expect(html).toContain('<li>Explain the contrast.</li>');
    expect(html).toContain('<summary aria-describedby="public-course-p1">Outline</summary>');
    // Where it comes from wraps like any line: it is not the index row's one-line status.
    expect(html).not.toContain('courses__status');
    expect(card({ course: single })).toContain('A course on Meditations · licensed · 1 lesson');
  });

  it('names the course a button acts on by its heading', () => {
    const html = card();
    expect(html).toContain('<h3 id="public-course-p1" class="courses__title">');
    expect(html).toMatch(/<button[^>]*aria-describedby="public-course-p1"[^>]*>Add to my courses/);
    expect(card({ copy: 'c9' })).toMatch(
      /<button[^>]*aria-describedby="public-course-p1"[^>]*>Open your copy/,
    );
  });

  it('holds its button while any course is being added, and says which one is', () => {
    expect(card({ busy: true })).toContain('aria-disabled="true"');
    expect(card({ busy: true, working: true })).toContain('Adding…');
    expect(card()).toContain('aria-disabled="false"');
  });

  it('says what adding it came to, inside the card', () => {
    const added = card({ copy: 'c9', note: { kind: 'added', text: 'Added to your courses.' } });
    expect(added).toMatch(/<p class="meta" role="status">Added to your courses\.<\/p>/);
    const refused = card({
      note: { kind: 'error', text: 'Your session has ended. Sign in again, then add it.' },
    });
    expect(refused).toMatch(
      /role="alert">Your session has ended\. Sign in again, then add it\.<\/p><\/li>$/,
    );
    // The live region is there before anything is said in it.
    expect(card()).toContain('<p class="sr-only" role="status"></p>');
  });
});

describe('OutlineBody', () => {
  const outline = (units: Parameters<typeof OutlineBody>[0]['units']) =>
    renderToStaticMarkup(createElement(OutlineBody, { units }));

  it('shows the units and their lessons, in order', () => {
    const html = outline([
      {
        unitNo: 1,
        unitTitle: 'Timing',
        lessons: [
          { unitNo: 1, unitTitle: 'Timing', title: 'Lesson one', minutes: 3 },
          { unitNo: 1, unitTitle: 'Timing', title: 'Lesson two', minutes: 4 },
        ],
      },
    ]);
    expect(html).toMatch(
      /<h4 class="course__unit-title">Timing<\/h4>.*<span>Lesson one<\/span><span class="course__lesson-state">3 min<\/span>.*<span>Lesson two<\/span>/,
    );
  });

  it('says a course no longer offered is, and is not taken for one with no lessons', () => {
    // No course came back: withdrawn, or its work's rights in question.
    expect(outline(null)).toBe('<p>This course is no longer offered.</p>');
    expect(outline([])).toBe('<p>This course has no lessons to show now.</p>');
  });
});

describe('adding a public course', () => {
  it('says a copy made, and one the reader had, and hands back the copy', () => {
    expect(enrolOutcome({ answer: { courseId: 'c1', replayed: false } })).toEqual({
      kind: 'added',
      courseId: 'c1',
      text: 'Added to your courses.',
    });
    expect(enrolOutcome({ answer: { courseId: 'c1', replayed: true } })).toMatchObject({
      kind: 'added',
      text: 'Already in your courses.',
    });
  });

  it('reads an answer naming no copy as a copy made, said as a status and not a failure', () => {
    // The reader's list is read again to show it, and that read may fail: "should".
    expect(enrolOutcome({ answer: null })).toEqual({
      kind: 'added',
      courseId: null,
      text: 'Added to your courses. It should now be among your courses above.',
    });
  });

  it('takes a course withdrawn since the list loaded off the list, and says every other refusal', () => {
    const refused = (code: string, message = 'refused') => ({
      error: rpcError({ code, message, details: null, hint: null }),
    });
    expect(enrolOutcome(refused('P0002'))).toEqual({ kind: 'withdrawn' });
    expect(enrolOutcome(refused('54000'))).toEqual({
      kind: 'error',
      text: 'That is as many public courses as can be added in a day. More at 00:00 UTC.',
    });
    expect(enrolOutcome(refused('XX000', 'something went wrong'))).toEqual({
      kind: 'error',
      text: 'Something went wrong',
    });
    // Offline, the request may have landed: it is not said to have failed.
    const lost = new Error('TypeError: Failed to fetch');
    lost.name = TRANSPORT_ERROR;
    expect(enrolOutcome({ error: lost })).toEqual({
      kind: 'error',
      text: 'That may not have reached your account — you look offline. Try again when you reconnect.',
    });
  });

  it('adds one course at a time: a press while one is on its way does nothing', async () => {
    let finish: (answer: { courseId: string; replayed: boolean }) => void = () => undefined;
    const enrol = vi.fn(
      () =>
        new Promise<{ courseId: string; replayed: boolean }>((resolve) => {
          finish = resolve;
        }),
    );
    const add = oneEnrolmentAtATime(enrol);
    const first = add('p1');
    // Pressed again in the same frame, and another course's button too.
    expect(add('p1')).toBeNull();
    expect(add('p2')).toBeNull();
    expect(enrol).toHaveBeenCalledTimes(1);
    finish({ courseId: 'c1', replayed: false });
    expect(await first).toMatchObject({ kind: 'added', courseId: 'c1' });
    // Settled, the next press is heard -- and so after a refusal.
    const refusing = oneEnrolmentAtATime(() => Promise.reject(new Error('no')));
    expect(await refusing('p1')).toMatchObject({ kind: 'error' });
    expect(refusing('p1')).not.toBeNull();
    const second = add('p2');
    expect(second).not.toBeNull();
    finish({ courseId: 'c2', replayed: true });
    expect(await second).toMatchObject({ kind: 'added', text: 'Already in your courses.' });
  });
});
