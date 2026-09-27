/**
 * Test: choose how many questions and of which kinds, answer them all on one page, and
 * submit once. The score comes back with every question marked right or wrong in words
 * and the right answer beside each wrong one; then retake it -- new questions, new order --
 * or learn the cards that were missed.
 *
 * True/false pairs a prompt with its own answer or another card's, about half and half.
 * Multiple choice offers the answer and up to three of the set's other answers. Written is
 * graded exact-or-close. `lib/flashcards.ts` builds and grades it; nothing is recorded.
 */
import { memo, useCallback, useEffect, useId, useState } from 'react';
import {
  TEST_KINDS,
  buildTest,
  defaultTestCount,
  gradeTest,
  type AnswerSide,
  type FlashcardSet,
  type TestKind,
  type TestQuestion,
  type TestResponse,
  type TestResult,
} from '../lib/flashcards.js';
import { mutationId } from '../lib/submission.js';
import { AnswerWithChoice, SIDE_LABEL, useFocusAfter } from './FlashcardParts.js';

const SETUP_ID = 'flashcards-test-setup';
const SCORE_ID = 'flashcards-test-score';
const FIRST_ID = 'flashcards-test-first';

const KIND_LABEL: Record<TestKind, string> = {
  true_false: 'True or false',
  choice: 'Multiple choice',
  written: 'Written',
};

/**
 * One question, drawn on its own. A key typed in a written answer changed the whole page's
 * responses and drew every question -- 32 to 80 ms a key at 2,000 questions, and 200 on a slow
 * phone. Memoised, with `respond` stable, a key draws the one question it was typed into.
 */
const TestQuestionItem = memo(function TestQuestionItem({
  q,
  i,
  response,
  mark,
  done,
  idPrefix,
  promptSide,
  answerWith,
  onRespond,
}: {
  q: TestQuestion;
  i: number;
  response: TestResponse;
  mark: boolean | null;
  done: boolean;
  idPrefix: string;
  promptSide: AnswerSide;
  answerWith: AnswerSide;
  onRespond: (index: number, value: TestResponse) => void;
}) {
  const first = i === 0;
  return (
    <li className="flashcards__question">
      <fieldset disabled={done}>
        <legend
          id={first ? FIRST_ID : undefined}
          tabIndex={first ? -1 : undefined}
          className="flashcards__prompt"
        >
          <span className="flashcards__qnum">{i + 1}.</span>{' '}
          <span className="meta">{SIDE_LABEL[promptSide]}</span> <span dir="auto">{q.prompt}</span>
          {q.kind === 'true_false' && (
            <span className="flashcards__shown">
              <span className="meta">{SIDE_LABEL[answerWith]}</span>{' '}
              <span dir="auto">{q.shown}</span>
            </span>
          )}
        </legend>
        {q.kind === 'true_false' && (
          <div className="flashcards__choice">
            {([true, false] as const).map((v) => (
              <label key={String(v)} className="flashcards__radio">
                <input
                  type="radio"
                  name={`${idPrefix}-q${i}`}
                  checked={response === v}
                  onChange={() => onRespond(i, v)}
                />{' '}
                {v ? 'True' : 'False'}
              </label>
            ))}
          </div>
        )}
        {q.kind === 'choice' && (
          <div className="flashcards__choice flashcards__choice--stacked">
            {q.options.map((option) => (
              <label key={option} className="flashcards__radio">
                <input
                  type="radio"
                  name={`${idPrefix}-q${i}`}
                  checked={response === option}
                  onChange={() => onRespond(i, option)}
                />{' '}
                <span dir="auto">{option}</span>
              </label>
            ))}
          </div>
        )}
        {q.kind === 'written' && (
          <div className="field">
            <label className="field__label" htmlFor={`${idPrefix}-q${i}`}>
              The {answerWith}
            </label>
            <input
              id={`${idPrefix}-q${i}`}
              className="field__input"
              dir="auto"
              autoComplete="off"
              autoCapitalize="off"
              spellCheck={false}
              maxLength={2000}
              value={typeof response === 'string' ? response : ''}
              onChange={(e) => onRespond(i, e.target.value)}
            />
          </div>
        )}
      </fieldset>
      {mark !== null && (
        <p
          className={
            mark ? 'flashcards__verdict' : 'flashcards__verdict flashcards__verdict--wrong'
          }
        >
          {mark
            ? 'Right.'
            : response === null || response === ''
              ? `Not answered. The answer is ${q.answer}.`
              : q.kind === 'true_false'
                ? `Wrong: you chose ${response ? 'True' : 'False'}, and it is ${q.truth ? 'true' : 'false'}. The answer is ${q.answer}.`
                : q.kind === 'choice'
                  ? `Wrong: you chose “${String(response)}”. The answer is ${q.answer}.`
                  : `Wrong: you wrote “${String(response)}”. The answer is ${q.answer}.`}
        </p>
      )}
    </li>
  );
});

interface Sitting {
  questions: TestQuestion[];
  responses: TestResponse[];
  result: TestResult | null;
}

export function FlashcardTest({
  set,
  headingId,
  onLeave,
  onWork,
  onLearnMissed,
}: {
  set: FlashcardSet;
  headingId: string;
  onLeave: () => void;
  /** Whether leaving now would throw answers away: a sitting answered and not submitted. */
  onWork?: (holds: boolean) => void;
  onLearnMissed: (cardIds: string[]) => void;
}) {
  const id = useId();
  const focusAfter = useFocusAfter();
  const total = set.cards.length;
  const [count, setCount] = useState(String(defaultTestCount(total)));
  const [kinds, setKinds] = useState<TestKind[]>([...TEST_KINDS]);
  const [answerWith, setAnswerWith] = useState<AnswerSide>('term');
  const [problem, setProblem] = useState<string | null>(null);
  const [sitting, setSitting] = useState<Sitting | null>(null);

  const promptSide: AnswerSide = answerWith === 'term' ? 'definition' : 'term';

  const holds =
    sitting !== null &&
    sitting.result === null &&
    sitting.responses.some((r) => r !== null && r !== '');
  useEffect(() => onWork?.(holds), [holds, onWork]);
  useEffect(() => () => onWork?.(false), [onWork]);

  const start = () => {
    const n = Number(count);
    if (!Number.isInteger(n) || n < 1 || n > total) {
      setProblem(`Choose between 1 and ${total} questions.`);
      return;
    }
    if (kinds.length === 0) {
      setProblem('Choose at least one kind of question.');
      return;
    }
    setProblem(null);
    const questions = buildTest(set.cards, { count: n, kinds, answerWith }, mutationId());
    setSitting({ questions, responses: questions.map(() => null), result: null });
    focusAfter(FIRST_ID);
  };

  const respond = useCallback(
    (index: number, value: TestResponse) =>
      setSitting((s) =>
        s && !s.result
          ? { ...s, responses: s.responses.map((r, i) => (i === index ? value : r)) }
          : s,
      ),
    [],
  );

  const submit = () => {
    if (!sitting || sitting.result) return;
    setSitting({ ...sitting, result: gradeTest(sitting.questions, sitting.responses) });
    focusAfter(SCORE_ID);
    window.scrollTo(0, 0);
  };

  const bar = (
    <div className="flashcards__bar">
      <button type="button" className="btn btn--plain meta" onClick={onLeave}>
        ← Back to the set
      </button>
    </div>
  );

  if (!sitting) {
    return (
      <section className="stack measure flashcards" aria-labelledby={headingId}>
        {bar}
        <p className="meta" dir="auto">
          {set.title}
        </p>
        <h1 id={headingId} tabIndex={-1} className="flashcards__heading">
          Test
        </h1>
        <p>A page of questions on this set, marked all at once when you submit.</p>
        {/* `start` says a count out of range in words, beside the control; the browser's own
            bubble said it first, in its own words, and away from where the reader looks. */}
        <form
          id={SETUP_ID}
          className="stack"
          noValidate
          onSubmit={(e) => {
            e.preventDefault();
            start();
          }}
        >
          <div className="field">
            <label className="field__label" htmlFor={`${id}-count`}>
              Questions (1 to {total})
            </label>
            <input
              id={`${id}-count`}
              className="field__input flashcards__number"
              type="number"
              inputMode="numeric"
              min={1}
              max={total}
              value={count}
              onChange={(e) => setCount(e.target.value)}
            />
          </div>
          <fieldset className="flashcards__choice">
            <legend className="field__label">Kinds of question</legend>
            {TEST_KINDS.map((kind) => (
              <label key={kind} className="flashcards__radio">
                <input
                  type="checkbox"
                  checked={kinds.includes(kind)}
                  onChange={(e) =>
                    setKinds((k) =>
                      e.target.checked
                        ? TEST_KINDS.filter((x) => x === kind || k.includes(x))
                        : k.filter((x) => x !== kind),
                    )
                  }
                />{' '}
                {KIND_LABEL[kind]}
              </label>
            ))}
          </fieldset>
          <AnswerWithChoice value={answerWith} onChange={setAnswerWith} />
          {problem && (
            <p className="remember__error" role="alert">
              {problem}
            </p>
          )}
          <p>
            <button type="submit" className="btn btn--primary">
              Start the test
            </button>
          </p>
        </form>
      </section>
    );
  }

  const { questions, responses, result } = sitting;
  const answeredCount = responses.filter((r) => r !== null && r !== '').length;

  return (
    <section className="stack measure flashcards" aria-labelledby={headingId}>
      {bar}
      <p className="meta" dir="auto">
        {set.title}
      </p>
      <h1 id={headingId} tabIndex={-1} className="flashcards__heading">
        Test
      </h1>
      {result && (
        <div className="stack flashcards__end">
          <h2 id={SCORE_ID} tabIndex={-1} className="flashcards__score">
            {result.score} / {result.total}
          </h2>
          <p>
            {result.score === result.total
              ? 'Every answer right.'
              : `${result.total - result.score} to look at again — each is marked below, with its answer.`}
          </p>
          <div className="flashcards__actions">
            <button
              type="button"
              className="btn btn--primary"
              onClick={() => {
                const n = questions.length;
                const again = buildTest(set.cards, { count: n, kinds, answerWith }, mutationId());
                setSitting({ questions: again, responses: again.map(() => null), result: null });
                focusAfter(FIRST_ID);
              }}
            >
              Retake
            </button>
            {result.missed.length > 0 && (
              <button type="button" className="btn" onClick={() => onLearnMissed(result.missed)}>
                Learn the {result.missed.length} you missed
              </button>
            )}
            <button
              type="button"
              className="btn btn--plain"
              onClick={() => {
                setSitting(null);
                focusAfter(headingId);
              }}
            >
              Change the test
            </button>
          </div>
        </div>
      )}
      {TEST_KINDS.map((kind) => {
        const inSection = questions.map((q, i) => ({ q, i })).filter(({ q }) => q.kind === kind);
        if (inSection.length === 0) return null;
        return (
          <section
            key={kind}
            className="stack flashcards__section"
            aria-labelledby={`${id}-${kind}`}
          >
            <h2 id={`${id}-${kind}`} className="flashcards__subheading">
              {KIND_LABEL[kind]}
            </h2>
            {/* Numbered through the page: the sections come in the order the questions do. */}
            <ol className="flashcards__questions" start={(inSection[0]?.i ?? 0) + 1}>
              {inSection.map(({ q, i }) => (
                <TestQuestionItem
                  key={`${q.cardId}-${i}`}
                  q={q}
                  i={i}
                  response={responses[i] ?? null}
                  mark={result ? (result.correct[i] ?? null) : null}
                  done={result !== null}
                  idPrefix={id}
                  promptSide={promptSide}
                  answerWith={answerWith}
                  onRespond={respond}
                />
              ))}
            </ol>
          </section>
        );
      })}
      {!result && (
        <div className="stack">
          <p className="form-note" aria-live="polite">
            {answeredCount} of {questions.length} answered. Anything left blank is marked wrong.
          </p>
          <p>
            <button type="button" className="btn btn--primary" onClick={submit}>
              Submit
            </button>
          </p>
        </div>
      )}
    </section>
  );
}
