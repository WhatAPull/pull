import { createElement } from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { describe, expect, it, vi } from 'vitest';
import { shapePublicCourses } from '../lib/study-course.js';

// The cards are markup; the network is the list's, and is not what is under test here.
vi.mock('../lib/study-course-api.js', () => ({
  enrolPublicCourse: vi.fn(),
  fetchPublicCourses: vi.fn(),
}));

const { enrolRefusal, PublicCourseCards } = await import('./PublicCourseList.js');

const noop = () => undefined;
const courses = shapePublicCourses([
  {
    id: 'p1',
    slug: 'immediate-versus-delayed',
    title: 'Immediate versus delayed',
    goal: 'Explain the argument',
    overview: 'What the paper says about timing.',
    objectives: ['Explain the contrast.'],
    lesson_count: 2,
    question_count: 1,
    work_title: 'Test-enhanced learning',
    rights_status: 'public_domain',
  },
  {
    id: 'p2',
    slug: 'meditations',
    title: 'Meditations',
    goal: 'Remember the key findings',
    overview: null,
    objectives: [],
    lesson_count: 1,
    question_count: 0,
    work_title: 'Meditations',
    rights_status: 'licensed',
  },
]);

describe('PublicCourseCards', () => {
  it('says where each course comes from, and offers to add or open it', () => {
    const html = renderToStaticMarkup(
      createElement(PublicCourseCards, {
        courses,
        enrolled: new Map([['p2', 'c9']]),
        working: null,
        onAdd: noop,
        onOpen: noop,
      }),
    );
    expect(html).toContain('From Test-enhanced learning · public domain · 2 lessons');
    expect(html).toContain('From Meditations · licensed · 1 lesson');
    expect(html.match(/Add to my courses/g)).toHaveLength(1);
    expect(html).toContain('Open your copy');
  });

  it('holds every button while one course is being added', () => {
    const html = renderToStaticMarkup(
      createElement(PublicCourseCards, {
        courses,
        enrolled: new Map(),
        working: 'p1',
        onAdd: noop,
        onOpen: noop,
      }),
    );
    expect(html).toContain('Adding…');
    expect(html.match(/aria-disabled="true"/g)).toHaveLength(2);
  });
});

describe('enrolRefusal', () => {
  it('says each refusal in words, and leaves the rest to the server', () => {
    expect(enrolRefusal('P0002')).toMatch(/no longer offered/);
    expect(enrolRefusal('54000')).toMatch(/00:00 UTC/);
    expect(enrolRefusal('28000')).toMatch(/account/);
    expect(enrolRefusal('XX000')).toBeNull();
  });
});
