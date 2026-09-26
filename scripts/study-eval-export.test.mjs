import assert from 'node:assert/strict';
import { test } from 'node:test';
import { buildStudyEvalRun } from './study-eval-export.mjs';
import { evaluateStudyRun } from './study-eval.mjs';

const manifest = {
  sources: [
    { id: 'note', versionIds: ['v1'], rights: 'self-authored', categories: ['notes', 'qualified'] },
    { id: 'memos', versionIds: ['v2', 'v3'], rights: 'self-authored', categories: ['conflicting'] },
  ],
};
const generations = [
  { generationId: 'g1', jobId: 'j1', versionIds: ['v1'] },
  { generationId: 'g2', jobId: 'j2', versionIds: ['v3', 'v2'] },
];
const items = [
  { id: 'i1', generationId: 'g1', status: 'validated', decided: 'validated' },
  { id: 'i2', generationId: 'g1', status: 'rejected' },
  { id: 'i3', generationId: 'g2', status: 'validated', decided: 'validated' },
  { id: 'i4', generationId: 'g2', status: 'quarantined', decided: 'quarantined' },
  // Shown to learners, then reported: the validator let it through, so it counts.
  { id: 'i5', generationId: 'g2', status: 'suspended', decided: 'validated' },
  // Shown, then withdrawn with no replacement: still what the validator passed.
  { id: 'i6', generationId: 'g2', status: 'retired', decided: 'validated' },
  { id: 'i7', generationId: 'g2', status: 'draft' },
  // A reader's own correction is not the model's output.
  { id: 'i8', generationId: 'g2', status: 'validated', decided: undefined, authoredBy: 'reader' },
];
const calls = [
  { id: 'c1', jobId: 'j1' },
  { id: 'c2', jobId: 'j1' },
  { id: 'c3', jobId: 'j2' },
];
const ledger = [
  { id: 1, jobId: 'j1', step: 'study_extract', providerCallId: 'c1', costCents: '0' },
  { id: 2, jobId: 'j1', step: 'study_extract', providerCallId: 'c2', costCents: '0.25' },
  { id: 3, jobId: 'j2', step: 'study_assemble', providerCallId: 'c3', costCents: '0.5' },
];

test('maps courses to fixture sources by their exact version set, in any order', () => {
  const run = buildStudyEvalRun({ manifest, generations, items, calls, ledger });
  assert.deepEqual(
    run.items.map((i) => [i.id, i.sourceId, i.status]),
    [
      ['i1', 'note', 'visible'],
      ['i2', 'note', 'quarantined'],
      ['i3', 'memos', 'visible'],
      ['i4', 'memos', 'quarantined'],
      ['i5', 'memos', 'visible'],
      ['i6', 'memos', 'visible'],
    ],
  );
  assert.deepEqual(
    run.attempts.map((a) => a.id),
    ['c1', 'c2', 'c3'],
  );
  assert.deepEqual(run.providerAttemptIds, ['c1', 'c2', 'c3']);
  assert.equal(run.ledger[1].costCents, 0.25);
});

test('says which pipelines made the run, once each, and when its last course was saved', () => {
  const a = { promptHash: 'a'.repeat(64), schemaHash: 'b'.repeat(64), model: 'm' };
  const e = { ...a, model: 'e' };
  const run = buildStudyEvalRun({
    manifest,
    generations: [
      {
        ...generations[0],
        provenance: a,
        extraction: [e],
        assembledAt: '2026-09-20T10:00:00.000000Z',
      },
      {
        ...generations[1],
        provenance: { ...a },
        extraction: [{ ...e }],
        assembledAt: '2026-09-21T09:00:00.000000Z',
      },
    ],
    items,
    calls,
    ledger,
  });
  // Both stages: what extracted the claims as well as what assembled the course.
  assert.deepEqual(run.pipelines, [{ extract: e, assemble: a }]);
  assert.equal(run.ranAt, '2026-09-21T09:00:00.000000Z');
  assert.equal(evaluateStudyRun(run).gates.singlePipeline, true);
  const two = buildStudyEvalRun({
    manifest,
    generations: [
      { ...generations[0], provenance: a, extraction: [e] },
      { ...generations[1], provenance: { ...a, model: 'n' }, extraction: [e] },
    ],
    items,
    calls,
    ledger,
  });
  assert.equal(two.pipelines.length, 2);
  assert.equal(two.ranAt, null);
  // An extraction prompt changed between two courses assembled alike is a second pipeline;
  // so is one course whose claims were extracted two ways.
  for (const split of [
    [
      { ...generations[0], provenance: a, extraction: [e] },
      { ...generations[1], provenance: a, extraction: [{ ...e, promptHash: 'c'.repeat(64) }] },
    ],
    [{ ...generations[0], provenance: a, extraction: [e, { ...e, model: 'f' }] }],
  ]) {
    const again = buildStudyEvalRun({ manifest, generations: split, items, calls, ledger });
    assert.equal(again.pipelines.length, 2);
    assert.equal(evaluateStudyRun(again).gates.singlePipeline, false);
  }
  // A course with no claims recorded says nothing of its extraction, and passes no gate.
  const unnamed = buildStudyEvalRun({
    manifest,
    generations: [{ ...generations[0], provenance: a, extraction: [] }],
    items,
    calls,
    ledger,
  });
  assert.deepEqual(unnamed.pipelines, [
    { extract: { promptHash: null, schemaHash: null, model: null }, assemble: a },
  ]);
  assert.equal(evaluateStudyRun(unnamed).gates.singlePipeline, false);
});

test('the evaluator certifies the ledger when journal and ledger agree', () => {
  const run = buildStudyEvalRun({ manifest, generations, items, calls, ledger });
  assert.equal(evaluateStudyRun(run).gates.ledgerComplete, true);
});

test('a journalled attempt the ledger missed fails the gate', () => {
  const run = buildStudyEvalRun({
    manifest,
    generations,
    items,
    calls: [...calls, { id: 'c4', jobId: 'j2' }],
    ledger,
  });
  assert.equal(evaluateStudyRun(run).gates.ledgerComplete, false);
});

test('a step-level fallback ledger row cannot pass as an attempt the journal saw', () => {
  const run = buildStudyEvalRun({
    manifest,
    generations,
    items,
    calls,
    ledger: [
      ...ledger,
      { id: 9, jobId: 'j2', step: 'study_assemble', providerCallId: null, costCents: 1 },
    ],
  });
  assert.ok(run.attempts.some((a) => a.id === 'ledger-9'));
  assert.equal(evaluateStudyRun(run).gates.ledgerComplete, false);
});

test('attaches human reviews by item id, and leaves the rest unreviewed', () => {
  const verdict = { grounded: true, answerable: true, ambiguous: false, materialError: false };
  const run = buildStudyEvalRun({
    manifest,
    generations,
    items,
    calls,
    ledger,
    reviews: {
      i1: {
        adversarial: false,
        reviewers: [
          { reviewerId: 'r1', ...verdict },
          { reviewerId: 'r2', ...verdict },
        ],
        adjudicated: verdict,
      },
    },
  });
  assert.equal(run.items[0].reviewers.length, 2);
  assert.deepEqual(run.items[2].reviewers, []);
  const report = evaluateStudyRun(run);
  assert.equal(report.counts.doubleReviewedVisible, 1);
  assert.equal(report.gates.answersSupported, false);
});

test('refuses a course that matches no fixture source', () => {
  assert.throws(
    () =>
      buildStudyEvalRun({
        manifest,
        generations: [{ generationId: 'g9', jobId: 'j9', versionIds: ['v9'] }],
        items: [],
        calls: [],
        ledger: [],
      }),
    /matches no manifest source/,
  );
});
