/**
 * Learn: rounds of up to seven cards, each asked as multiple choice until it is answered
 * right, then in writing until it is answered right again -- and then it is mastered. A
 * wrong answer at either stage sends the card back to multiple choice in a later round.
 * The rules are `lib/flashcards.ts`'s; this draws them.
 *
 * A written answer is graded exact-or-close by the rule the rest of the app grades typed
 * recall with. When it says no and the reader knows better -- a synonym, an accent left
 * off -- "I was right" counts it. That is the reader's own judgement, and it is fine here:
 * nothing is recorded, so it costs nobody anything but them.
 */
import { Meter } from '@wap/ui';
import { useId, useState } from 'react';
import {
  answerLearn,
  claimRight,
  continueLearn,
  learnCorrect,
  learnDone,
  learnProgress,
  learnQuestion,
  learnRoundOver,
  nextLearnRound,
  startLearn,
  type AnswerSide,
  type FlashcardSet,
  type LearnState,
} from '../lib/flashcards.js';
import { mutationId } from '../lib/submission.js';
import {
  AnswerWithChoice,
  ListenButton,
  SIDE_LABEL,
  cardCount,
  useFocusAfter,
  useListen,
} from './FlashcardParts.js';

const PROMPT_ID = 'flashcards-learn-prompt';
const VERDICT_ID = 'flashcards-learn-verdict';
const BREAK_ID = 'flashcards-learn-break';

export function FlashcardLearn({
  set,
  cardIds,
  headingId,
  onLeave,
}: {
  set: FlashcardSet;
  /** The cards to learn: all of the set, or the ones a test missed. */
  cardIds: readonly string[];
  headingId: string;
  onLeave: () => void;
}) {
  const id = useId();
  const focusAfter = useFocusAfter();
  const listen = useListen(set);
  // Answered with the term by default: a written answer is graded exact-or-close, which is
  // fair for a word or two and harsh for a definition a sentence long.
  const [state, setState] = useState<LearnState>(() =>
    startLearn(set.cards, cardIds, 'term', mutationId()),
  );
  const [typed, setTyped] = useState('');
  const [problem, setProblem] = useState<string | null>(null);

  const question = learnQuestion(state, set.cards);
  const { mastered, total } = learnProgress(state);
  // Nothing to learn: the cards a test missed, all deleted since -- on another screen, and
  // the set read again. Rounds of none would each end at once and offer the next, for ever.
  const empty = total === 0;
  const done = learnDone(state);
  const between = !empty && !done && learnRoundOver(state);
  const answered = state.answered;
  const promptSide: AnswerSide = state.answerWith === 'term' ? 'definition' : 'term';

  const restart = (answerWith: AnswerSide) => {
    setState(startLearn(set.cards, cardIds, answerWith, mutationId()));
    setTyped('');
    setProblem(null);
    focusAfter(PROMPT_ID);
  };

  const choose = (option: string) => {
    if (!question || answered) return;
    setState(answerLearn(state, learnCorrect(question, option), option));
    focusAfter(VERDICT_ID);
  };

  const submitWritten = (gaveUp: boolean) => {
    if (!question || answered) return;
    if (!gaveUp && typed.trim() === '') {
      setProblem('Type an answer first — a guess counts.');
      return;
    }
    setProblem(null);
    const response = gaveUp ? '' : typed.trim();
    // Right when close to the card's answer, or to another card's with the same prompt.
    setState(answerLearn(state, !gaveUp && learnCorrect(question, typed), response));
    focusAfter(VERDICT_ID);
  };

  const goOn = () => {
    const next = continueLearn(state);
    setState(next);
    setTyped('');
    setProblem(null);
    focusAfter(learnRoundOver(next) ? BREAK_ID : PROMPT_ID);
  };

  return (
    <section className="stack measure flashcards" aria-labelledby={headingId}>
      <div className="flashcards__bar">
        <button type="button" className="btn btn--plain meta" onClick={onLeave}>
          ← Back to the set
        </button>
        {!empty && (
          <span className="flashcards__count">
            Round {state.roundNo} · Mastered {mastered} of {total}
          </span>
        )}
      </div>
      <p className="meta" dir="auto">
        {set.title}
      </p>
      <h1 id={headingId} tabIndex={-1} className="flashcards__heading">
        Learn
      </h1>
      {!empty && (
        <>
          <Meter value={mastered / total} label={`Mastered ${mastered} of ${total}`} />
          <AnswerWithChoice
            value={state.answerWith}
            onChange={restart}
            note="Changing this starts again."
          />
        </>
      )}

      {empty ? (
        <div className="stack flashcards__end">
          <h2 id={BREAK_ID} tabIndex={-1} className="flashcards__subheading">
            There are no cards to learn here.
          </h2>
          <p>
            The cards you were to learn are no longer in the set: it was changed somewhere else
            since you began.
          </p>
          <div className="flashcards__actions">
            <button type="button" className="btn btn--primary" onClick={onLeave}>
              Back to the set
            </button>
          </div>
        </div>
      ) : done ? (
        <div className="stack flashcards__end">
          <h2 id={BREAK_ID} tabIndex={-1} className="flashcards__subheading">
            You’ve learnt all {cardCount(total)}.
          </h2>
          <p>Each was right in multiple choice and then right in writing.</p>
          <div className="flashcards__actions">
            <button
              type="button"
              className="btn btn--primary"
              onClick={() => restart(state.answerWith)}
            >
              Learn again
            </button>
            <button type="button" className="btn" onClick={onLeave}>
              Back to the set
            </button>
          </div>
        </div>
      ) : between ? (
        <div className="stack flashcards__end">
          <h2 id={BREAK_ID} tabIndex={-1} className="flashcards__subheading">
            Round {state.roundNo} done. Mastered {mastered} of {total}.
          </h2>
          <p>The next round keeps the cards you are still learning and brings in new ones.</p>
          <p>
            <button
              type="button"
              className="btn btn--primary"
              onClick={() => {
                setState(nextLearnRound(state));
                focusAfter(PROMPT_ID);
              }}
            >
              Go on to round {state.roundNo + 1}
            </button>
          </p>
        </div>
      ) : (
        question && (
          <article className="stack flashcards__card" aria-labelledby={PROMPT_ID}>
            <p className="meta flashcards__side">
              {SIDE_LABEL[promptSide]} ·{' '}
              {question.kind === 'choice' ? 'Choose the answer' : 'Write the answer'}
            </p>
            <p id={PROMPT_ID} tabIndex={-1} className="flashcards__face" dir="auto">
              {question.prompt}
            </p>
            <ListenButton
              text={question.prompt}
              side={promptSide}
              cardKey={question.card.id}
              listen={listen}
            />

            {question.kind === 'choice' ? (
              <ul className="flashcards__options" aria-label={`Choose the ${state.answerWith}`}>
                {question.options.map((option) => {
                  const chosen = answered?.response === option;
                  const right = answered !== null && option === question.answer;
                  return (
                    <li key={option}>
                      <button
                        type="button"
                        className="flashcards__option"
                        dir="auto"
                        data-state={right ? 'right' : chosen ? 'wrong' : undefined}
                        aria-disabled={answered !== null}
                        onClick={() => choose(option)}
                      >
                        {option}
                        {right && <span className="flashcards__mark"> — the answer</span>}
                        {chosen && !right && (
                          <span className="flashcards__mark"> — your answer</span>
                        )}
                      </button>
                    </li>
                  );
                })}
              </ul>
            ) : (
              <form
                className="stack"
                onSubmit={(e) => {
                  e.preventDefault();
                  submitWritten(false);
                }}
              >
                <div className="field">
                  <label className="field__label" htmlFor={`${id}-typed`}>
                    Type the {state.answerWith}
                  </label>
                  <input
                    id={`${id}-typed`}
                    className="field__input"
                    dir="auto"
                    value={answered ? answered.response : typed}
                    readOnly={answered !== null}
                    autoComplete="off"
                    autoCapitalize="off"
                    spellCheck={false}
                    maxLength={2000}
                    onChange={(e) => setTyped(e.target.value)}
                  />
                </div>
                {problem && (
                  <p className="remember__error" role="alert">
                    {problem}
                  </p>
                )}
                {!answered && (
                  <div className="flashcards__actions">
                    <button type="submit" className="btn btn--primary">
                      Answer
                    </button>
                    <button
                      type="button"
                      className="btn btn--plain"
                      onClick={() => submitWritten(true)}
                    >
                      Don’t know
                    </button>
                  </div>
                )}
              </form>
            )}

            {answered && (
              <div className="stack flashcards__feedback">
                <p id={VERDICT_ID} tabIndex={-1} className="flashcards__verdict" dir="auto">
                  {answered.correct
                    ? answered.overridden
                      ? 'Counted as right, on your word.'
                      : answered.asked === 'choice'
                        ? 'Right. Next time you will write it.'
                        : 'Right — mastered.'
                    : answered.response === ''
                      ? `The answer: ${question.answer}`
                      : `Not quite. The answer: ${question.answer}`}
                </p>
                {!answered.correct && answered.asked === 'written' && answered.response !== '' && (
                  <p className="form-note">You wrote: {answered.response}</p>
                )}
                <div className="flashcards__actions">
                  <button type="button" className="btn btn--primary" onClick={goOn}>
                    Continue
                  </button>
                  {!answered.correct &&
                    answered.asked === 'written' &&
                    answered.response !== '' && (
                      <button
                        type="button"
                        className="btn"
                        onClick={() => {
                          setState(claimRight(state));
                          focusAfter(VERDICT_ID);
                        }}
                      >
                        I was right
                      </button>
                    )}
                </div>
              </div>
            )}
          </article>
        )
      )}
    </section>
  );
}
