/**
 * Match: up to six cards laid out as twelve tiles, their terms and definitions shuffled
 * together. Choose a tile, then another: a card's term and its definition clear together;
 * anything else is not a pair, which is said, and nothing stays chosen. The clock starts
 * with the first choice and stops when the last pair clears.
 *
 * Every tile is a button, so the game is played from the keyboard as well as by pointer --
 * there is nothing to drag. A chosen tile says so in `aria-pressed` and in an outline and a
 * word; a pair that is not one is said in words and outlined, not shaken. What happens is
 * announced in a polite live region. The best time is kept in this browser only.
 */
import { useEffect, useState } from 'react';
import {
  beatsBest,
  elapsedTenths,
  formatTenths,
  matchDone,
  readBestTime,
  selectTile,
  startMatch,
  type FlashcardSet,
  type MatchState,
} from '../lib/flashcards.js';
import { mutationId } from '../lib/submission.js';
import { bestTimeKey, readStored, useFocusAfter, writeStored } from './FlashcardParts.js';

const DONE_ID = 'flashcards-match-done';
const tileDomId = (tileId: string) => `flashcards-tile-${tileId}`;

export function FlashcardMatch({
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
  const [game, setGame] = useState<MatchState | null>(() => startMatch(set.cards, mutationId()));
  const [now, setNow] = useState(0);
  const [best, setBest] = useState<number | null>(() =>
    readBestTime(readStored(bestTimeKey(userId, set.id))),
  );
  const [newBest, setNewBest] = useState(false);

  const running = game !== null && game.startedAt !== null && !matchDone(game);
  // The clock redraws ten times a second while it runs, and not at all otherwise.
  useEffect(() => {
    if (!running) return;
    const timer = window.setInterval(() => setNow(performance.now()), 100);
    return () => window.clearInterval(timer);
  }, [running]);

  if (!game) {
    return (
      <section className="stack measure flashcards" aria-labelledby={headingId}>
        <div className="flashcards__bar">
          <button type="button" className="btn btn--plain meta" onClick={onLeave}>
            ← Back to the set
          </button>
        </div>
        <h2 id={headingId} tabIndex={-1} className="flashcards__heading">
          Match
        </h2>
        <p>
          Match needs at least two cards whose terms and definitions all read differently, so that
          the right tile cannot be mistaken for another.
        </p>
      </section>
    );
  }

  /*
   * `at` is the press's own time stamp, on the page's performance clock -- the one the
   * redraw above reads -- so the time is when the tile was pressed, not when this ran.
   */
  const choose = (tileId: string, at: number) => {
    const next = selectTile(game, tileId, at);
    if (next === game) return;
    setGame(next);
    setNow(at);
    if (matchDone(next)) {
      const tenths = elapsedTenths(next, at);
      const better = beatsBest(tenths, best);
      setNewBest(better);
      if (better) {
        setBest(tenths);
        writeStored(bestTimeKey(userId, set.id), String(tenths));
      }
      focusAfter(DONE_ID);
    } else if (next.last?.kind === 'pair') {
      // The tile pressed is gone; the first tile still on the board takes focus.
      const remaining = next.tiles.find((t) => !next.cleared.includes(t.cardId));
      if (remaining) focusAfter(tileDomId(remaining.id));
    }
  };

  const again = () => {
    const next = startMatch(set.cards, mutationId());
    setGame(next);
    setNewBest(false);
    setNow(0);
    if (next?.tiles[0]) focusAfter(tileDomId(next.tiles[0].id));
  };

  const byId = new Map(game.tiles.map((t) => [t.id, t]));
  const last = game.last;
  const said =
    last === null
      ? ''
      : last.kind === 'selected'
        ? `Selected “${byId.get(last.tileId)?.text ?? ''}”. Now choose its match.`
        : last.kind === 'deselected'
          ? 'Nothing selected.'
          : last.kind === 'pair'
            ? matchDone(game)
              ? 'Pair cleared. All matched.'
              : `Pair cleared. ${game.tiles.length / 2 - game.cleared.length} to go.`
            : `Not a pair: “${byId.get(last.tileIds[0])?.text ?? ''}” and “${byId.get(last.tileIds[1])?.text ?? ''}”.`;
  const missed: readonly string[] = last?.kind === 'miss' ? last.tileIds : [];
  const tenths = elapsedTenths(game, game.finishedAt ?? (now || game.startedAt || 0));

  return (
    <section className="stack measure flashcards" aria-labelledby={headingId}>
      <div className="flashcards__bar">
        <button type="button" className="btn btn--plain meta" onClick={onLeave}>
          ← Back to the set
        </button>
        {/* The ticking figure is not announced; the finished time is, below. */}
        <span className="flashcards__timer" aria-hidden="true">
          {formatTenths(tenths)}
        </span>
      </div>
      <p className="meta">{set.title}</p>
      <h2 id={headingId} tabIndex={-1} className="flashcards__heading">
        Match
      </h2>
      <p className="form-note">
        Choose a term, then its definition — or the other way round. The clock starts with your
        first choice.{best !== null && ` Your best: ${formatTenths(best)}.`}
      </p>
      <p role="status" className={last?.kind === 'miss' ? 'remember__error' : 'form-note'}>
        {said}
      </p>

      {matchDone(game) ? (
        <div className="stack flashcards__end">
          <h3 id={DONE_ID} tabIndex={-1} className="flashcards__subheading">
            Your time {formatTenths(tenths)}
          </h3>
          <p>
            {newBest
              ? 'A new best for this set.'
              : best !== null
                ? `Your best is ${formatTenths(best)}.`
                : ''}
          </p>
          <div className="flashcards__actions">
            <button type="button" className="btn btn--primary" onClick={again}>
              Play again
            </button>
            <button type="button" className="btn" onClick={onLeave}>
              Back to the set
            </button>
          </div>
        </div>
      ) : (
        <ul className="flashcards__tiles" aria-label="Tiles">
          {game.tiles.map((tile) =>
            game.cleared.includes(tile.cardId) ? (
              // Its place is kept, so the tiles around it do not move under the pointer.
              <li key={tile.id} className="flashcards__tile-gap" aria-hidden="true" />
            ) : (
              <li key={tile.id}>
                <button
                  id={tileDomId(tile.id)}
                  type="button"
                  className="flashcards__tile"
                  aria-pressed={game.selected === tile.id}
                  data-missed={missed.includes(tile.id) ? 'true' : undefined}
                  onClick={(e) => choose(tile.id, e.timeStamp)}
                >
                  {tile.text}
                  {game.selected === tile.id && (
                    <span className="flashcards__mark"> · selected</span>
                  )}
                </button>
              </li>
            ),
          )}
        </ul>
      )}
    </section>
  );
}
