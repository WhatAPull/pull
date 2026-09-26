/**
 * Flashcards: one card at a time. The prompt side first, then "Show answer" puts the other
 * side below a hairline rule, in the page's own flow -- not on the back of a card that
 * turns over. `PullCard.tsx` records why the flip went: a back face sized by its front
 * scrolled long text inside itself, so more to read meant less room to read it.
 *
 * The reader sorts each card as known or still learning, and the round ends with the
 * count and a round of just the ones still to learn. A round in progress is kept in this
 * browser, so a reload -- or a phone that dropped the tab -- comes back to the same card.
 *
 * Keys: Space or Enter shows the answer, ← and → move. Not while typing in a field, and
 * not Space or Enter on a button, which already has them.
 */
import { useEffect, useState } from 'react';
import {
  answerOf,
  promptOf,
  restoreRound,
  roundOver,
  shuffleRound,
  sortCard,
  startCardsRound,
  stepRound,
  stillLearning,
  type AnswerSide,
  type CardsRound,
  type FlashcardSet,
} from '../lib/flashcards.js';
import { mutationId } from '../lib/submission.js';
import {
  AnswerWithChoice,
  ListenButton,
  SIDE_LABEL,
  cardCount,
  readStored,
  roundKey,
  typingIn,
  useFocusAfter,
  useListen,
  writeStored,
} from './FlashcardParts.js';

const PROMPT_ID = 'flashcards-round-prompt';
const ANSWER_ID = 'flashcards-round-answer';
const END_ID = 'flashcards-round-end';

interface Kept {
  round: CardsRound;
  answerWith: AnswerSide;
}

/** The round kept for this reader and set, read against the set as it is now. */
function keptRound(userId: string, set: FlashcardSet): Kept | null {
  const raw = readStored(roundKey(userId, set.id));
  if (raw === null) return null;
  try {
    const parsed: unknown = JSON.parse(raw);
    const round = restoreRound(
      parsed,
      set.cards.map((c) => c.id),
    );
    if (!round) return null;
    const side = (parsed as { answerWith?: unknown }).answerWith;
    return { round, answerWith: side === 'term' ? 'term' : 'definition' };
  } catch {
    return null;
  }
}

export function FlashcardRound({
  set,
  userId,
  headingId,
  onLeave,
}: {
  set: FlashcardSet;
  userId: string;
  headingId: string;
  onLeave: () => void;
}) {
  const focusAfter = useFocusAfter();
  const listen = useListen(set);
  const [kept] = useState(() => keptRound(userId, set));
  const [round, setRound] = useState<CardsRound>(
    () =>
      kept?.round ??
      startCardsRound(
        set.cards.map((c) => c.id),
        null,
      ),
  );
  // The term first, and the definition as the answer: a card's front, as it is written.
  const [answerWith, setAnswerWith] = useState<AnswerSide>(kept?.answerWith ?? 'definition');
  const [revealed, setRevealed] = useState(false);

  const byId = new Map(set.cards.map((c) => [c.id, c]));
  const cardId = round.order[round.index];
  const card = cardId === undefined ? undefined : byId.get(cardId);
  const over = roundOver(round);
  const learning = stillLearning(round);

  useEffect(() => {
    writeStored(roundKey(userId, set.id), JSON.stringify({ ...round, answerWith }));
  }, [round, answerWith, userId, set.id]);

  const show = (next: CardsRound) => {
    setRound(next);
    setRevealed(false);
    focusAfter(roundOver(next) ? END_ID : PROMPT_ID);
  };
  const reveal = () => {
    if (!card || revealed) return;
    setRevealed(true);
    focusAfter(ANSWER_ID);
  };

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.defaultPrevented || e.altKey || e.ctrlKey || e.metaKey || typingIn(e.target)) return;
      const onControl =
        e.target instanceof HTMLButtonElement || e.target instanceof HTMLAnchorElement;
      if ((e.key === ' ' || e.key === 'Enter') && !onControl && card && !revealed) {
        e.preventDefault();
        setRevealed(true);
        focusAfter(ANSWER_ID);
      } else if (e.key === 'ArrowRight' && !over) {
        e.preventDefault();
        setRound((r) => stepRound(r, 1));
        setRevealed(false);
        focusAfter(round.index + 1 >= round.order.length ? END_ID : PROMPT_ID);
      } else if (e.key === 'ArrowLeft' && round.index > 0) {
        e.preventDefault();
        setRound((r) => stepRound(r, -1));
        setRevealed(false);
        focusAfter(PROMPT_ID);
      }
    };
    document.addEventListener('keydown', onKey);
    return () => document.removeEventListener('keydown', onKey);
  }, [card, revealed, over, round.index, round.order.length, focusAfter]);

  const other: AnswerSide = answerWith === 'definition' ? 'term' : 'definition';

  return (
    <section className="stack measure flashcards" aria-labelledby={headingId}>
      <div className="flashcards__bar">
        <button type="button" className="btn btn--plain meta" onClick={onLeave}>
          ← Back to the set
        </button>
        <span className="flashcards__count" aria-live="polite">
          {over
            ? `Round over · ${cardCount(round.order.length)}`
            : `${round.index + 1} of ${round.order.length}`}
        </span>
      </div>
      <p className="meta">{set.title}</p>
      <h2 id={headingId} tabIndex={-1} className="flashcards__heading">
        Flashcards
      </h2>
      <AnswerWithChoice
        value={answerWith}
        onChange={(side) => {
          setAnswerWith(side);
          setRevealed(false);
        }}
      />

      {over ? (
        <div className="stack flashcards__end">
          <h3 id={END_ID} tabIndex={-1} className="flashcards__subheading">
            {learning.length === 0
              ? `You know all ${cardCount(round.order.length)} in this round.`
              : `You know ${round.known.length} of ${round.order.length}. ${learning.length} still learning.`}
          </h3>
          {learning.length > 0 && (
            <p className="form-note">
              A card you went past without sorting counts as still learning.
            </p>
          )}
          <div className="flashcards__actions">
            {learning.length > 0 && (
              <button
                type="button"
                className="btn btn--primary"
                onClick={() => show(startCardsRound(learning, null))}
              >
                Study the {learning.length} still learning
              </button>
            )}
            <button
              type="button"
              className={learning.length > 0 ? 'btn' : 'btn btn--primary'}
              onClick={() =>
                show(
                  startCardsRound(
                    set.cards.map((c) => c.id),
                    null,
                  ),
                )
              }
            >
              Start over
            </button>
          </div>
        </div>
      ) : (
        card && (
          <>
            <article className="flashcards__card" aria-label={`Card ${round.index + 1}`}>
              <p className="meta flashcards__side">{SIDE_LABEL[other]}</p>
              <p id={PROMPT_ID} tabIndex={-1} className="flashcards__face">
                {promptOf(card, answerWith)}
              </p>
              <ListenButton
                text={promptOf(card, answerWith)}
                side={other}
                cardKey={card.id}
                listen={listen}
              />
              {revealed ? (
                <div className="flashcards__answer">
                  <p className="meta flashcards__side">{SIDE_LABEL[answerWith]}</p>
                  <p id={ANSWER_ID} tabIndex={-1} className="flashcards__face">
                    {answerOf(card, answerWith)}
                  </p>
                  <ListenButton
                    text={answerOf(card, answerWith)}
                    side={answerWith}
                    cardKey={card.id}
                    listen={listen}
                  />
                </div>
              ) : (
                <p>
                  <button type="button" className="btn btn--primary" onClick={reveal}>
                    Show answer
                  </button>
                </p>
              )}
            </article>
            {revealed && (
              <div className="flashcards__actions" role="group" aria-label="How did you do?">
                <button
                  type="button"
                  className="btn"
                  onClick={() => show(sortCard(round, 'learning'))}
                >
                  Still learning
                </button>
                <button
                  type="button"
                  className="btn btn--primary"
                  onClick={() => show(sortCard(round, 'known'))}
                >
                  Know it
                </button>
              </div>
            )}
            <div className="flashcards__actions">
              <button
                type="button"
                className="btn btn--plain"
                aria-disabled={round.index === 0}
                onClick={() => {
                  if (round.index > 0) show(stepRound(round, -1));
                }}
              >
                ← Previous
              </button>
              <button
                type="button"
                className="btn btn--plain"
                onClick={() => show(stepRound(round, 1))}
              >
                Next →
              </button>
              <button
                type="button"
                className="btn btn--plain"
                onClick={() => show(shuffleRound(round, mutationId()))}
              >
                Shuffle
              </button>
            </div>
            <p className="form-note">
              Space shows the answer; ← and → move between cards.
              {round.known.length > 0 && ` You know ${round.known.length} so far.`}
            </p>
          </>
        )
      )}
    </section>
  );
}
