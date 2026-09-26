/**
 * `/flashcards`: the reader's sets, and the two ways to make one -- typing it, or importing
 * it from text. Making a set and importing one are tab state on this page rather than
 * addresses, as a set's study modes are on its own: they are things done here, not places
 * someone could be sent.
 *
 * Offline, the list is the sets opened on this device, which can still be studied; making
 * and importing need a connection and say so.
 */
import { useEffect, useState } from 'react';
import { FlashcardEditor } from '../components/FlashcardEditor.js';
import { FlashcardImport } from '../components/FlashcardImport.js';
import { cardCount, shortDate, useFocusAfter, useOnline } from '../components/FlashcardParts.js';
import {
  CARD_LIMIT,
  SET_LIMIT,
  TITLE_MAX,
  TOTAL_CARD_LIMIT,
  longerThan,
  newDraft,
  saveRefusal,
  type FlashcardSetSummary,
  type SavePayload,
} from '../lib/flashcards.js';
import { fetchSets, saveSet } from '../lib/flashcards-api.js';
import {
  isOfflineFailure,
  onReconnect,
  pruneFlashcardSets,
  readFlashcardSets,
} from '../lib/offline.js';
import { sqlDetail, sqlState } from '../lib/rpc-error.js';
import { mutationId } from '../lib/submission.js';

type View = 'list' | 'new' | 'import';

const LIST_TITLE = 'flashcards-title';
const NEW_TITLE = 'flashcards-new-title';
const IMPORT_TITLE = 'flashcards-import-title';

export function Flashcards({
  userId,
  onNavigate,
}: {
  userId: string;
  onNavigate: (to: string) => void;
}) {
  const online = useOnline();
  const focusAfter = useFocusAfter();
  const [view, setView] = useState<View>('list');
  const [sets, setSets] = useState<FlashcardSetSummary[]>([]);
  const [fromDevice, setFromDevice] = useState(false);
  const [settled, setSettled] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [attempt, setAttempt] = useState(0);
  // The id a new set is made under, minted when the screen opens, so a save retried after
  // a lost response makes the same set rather than a second one.
  const [newId, setNewId] = useState(mutationId);
  const [importTitle, setImportTitle] = useState('');
  const [importError, setImportError] = useState<string | null>(null);
  const [importing, setImporting] = useState(false);

  useEffect(() => {
    const controller = new AbortController();
    const fromThisDevice = async () => {
      const kept = await readFlashcardSets(userId);
      if (controller.signal.aborted) return;
      setSets(kept);
      setFromDevice(true);
      setError(null);
      setSettled(true);
    };
    // Offline, what is on the device at once, rather than after supabase-js has retried its
    // way to failing; the account is read again when the connection returns.
    if (typeof navigator !== 'undefined' && navigator.onLine === false) {
      void fromThisDevice();
      return () => controller.abort();
    }
    fetchSets(controller.signal)
      .then(({ sets: list, complete }) => {
        if (controller.signal.aborted) return;
        setSets(list);
        setFromDevice(false);
        setError(null);
        setSettled(true);
        // A set the whole list does not have is gone from the account -- deleted on another
        // device -- and its copy goes from this one.
        if (complete) void pruneFlashcardSets(userId, new Set(list.map((s) => s.id)));
      })
      .catch(async (e: unknown) => {
        if (controller.signal.aborted) return;
        if (isOfflineFailure(e)) {
          await fromThisDevice();
          return;
        }
        console.error('Flashcard sets request failed', e);
        setError(e instanceof Error ? e.message : String(e));
        setSettled(true);
      });
    return () => controller.abort();
  }, [userId, attempt]);

  // A list read from this device is read from the account again when the connection is back.
  useEffect(() => {
    if (!fromDevice) return;
    return onReconnect(() => setAttempt((n) => n + 1));
  }, [fromDevice]);

  const open = (next: View) => {
    setView(next);
    setImportError(null);
    if (next !== 'list') setNewId(mutationId());
    focusAfter(next === 'new' ? NEW_TITLE : next === 'import' ? IMPORT_TITLE : LIST_TITLE);
    window.scrollTo(0, 0);
  };

  const full = !fromDevice && sets.length >= SET_LIMIT;
  // The cards across every set, against the account's limit: known here, from the list.
  const totalCards = sets.reduce((n, s) => n + s.cardCount, 0);
  const cardRoom = TOTAL_CARD_LIMIT - totalCards;
  const fullOfCards = !fromDevice && cardRoom <= 0;
  const cannotMake = !online || fromDevice || full || fullOfCards;
  const cannotMakeReason = full
    ? `You have ${SET_LIMIT} sets, which is as many as an account keeps. Delete one you are done with to make another.`
    : fullOfCards
      ? `You have ${TOTAL_CARD_LIMIT.toLocaleString('en')} cards across your sets, which is as many as an account keeps. Delete cards or sets you are done with to make room.`
      : 'Making or importing a set needs a connection.';

  const saved = async (payload: SavePayload) => {
    const out = await saveSet(payload);
    onNavigate(`/flashcards/${encodeURIComponent(out.id)}`);
  };

  if (view === 'new') {
    return (
      <FlashcardEditor
        key={newId}
        userId={userId}
        initial={newDraft(newId, mutationId)}
        saved={null}
        heading="A new set"
        headingId={NEW_TITLE}
        online={online}
        onSave={saved}
        onLeave={() => open('list')}
        leaveLabel="Flashcards"
      />
    );
  }

  if (view === 'import') {
    const take = async (cards: { term: string; definition: string }[]) => {
      const title = importTitle.trim();
      if (!title || longerThan(title, TITLE_MAX)) {
        setImportError(
          title ? `A title is at most ${TITLE_MAX} characters.` : 'Give the set a title first.',
        );
        focusAfter('flashcards-import-name');
        return;
      }
      setImporting(true);
      setImportError(null);
      try {
        await saved({
          id: newId,
          title,
          description: null,
          termLang: null,
          definitionLang: null,
          cards: cards.map((c) => ({ id: mutationId(), ...c })),
        });
      } catch (e: unknown) {
        setImportError(
          isOfflineFailure(e)
            ? 'That did not reach your account — you look offline. Nothing is lost: try again once you are connected.'
            : (saveRefusal(sqlState(e), sqlDetail(e), e instanceof Error ? e.message : '') ??
                (e instanceof Error ? e.message : 'The set could not be saved.')),
        );
      } finally {
        setImporting(false);
      }
    };
    return (
      <section className="stack measure flashcards" aria-labelledby={IMPORT_TITLE}>
        <div className="flashcards__bar">
          <button type="button" className="btn btn--plain meta" onClick={() => open('list')}>
            ← Flashcards
          </button>
        </div>
        <h1 id={IMPORT_TITLE} tabIndex={-1}>
          Import a set
        </h1>
        <p>
          Paste a list, or open a file, and check the preview: every card is listed, and so is every
          line that did not make one. From Quizlet, use its Export and paste what it gives you as it
          is.
        </p>
        <div className="field">
          <label className="field__label" htmlFor="flashcards-import-name">
            Title of the new set
          </label>
          <input
            id="flashcards-import-name"
            className="field__input"
            dir="auto"
            value={importTitle}
            // Units, of which an emoji is two: twice the limit, and the limit said in characters.
            maxLength={TITLE_MAX * 2}
            onChange={(e) => setImportTitle(e.target.value)}
          />
        </div>
        <FlashcardImport
          limit={Math.max(0, Math.min(CARD_LIMIT, cardRoom))}
          takeLabel={(n) => (n === 0 ? 'Create the set' : `Create the set with ${cardCount(n)}`)}
          onTake={(cards) => void take(cards)}
          busy={importing}
          disabled={!online}
          disabledReason="Saving a set needs a connection."
        />
        {importError && (
          <p className="remember__error" role="alert">
            {importError}
          </p>
        )}
      </section>
    );
  }

  if (!settled) {
    return (
      <p className="meta" role="status">
        Loading…
      </p>
    );
  }

  if (error) {
    return (
      <section className="stack measure flashcards" role="alert">
        <p className="meta">Flashcards</p>
        <h1>Could not load your flashcards.</h1>
        <p>{error}</p>
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
    <section className="stack measure flashcards" aria-labelledby={LIST_TITLE}>
      <p className="meta">Flashcards</p>
      <h1 id={LIST_TITLE} tabIndex={-1}>
        Your own cards, studied four ways.
      </h1>
      <p>
        A set is a list of terms and their definitions that you write, paste from Quizlet or a
        spreadsheet, or open from an Anki export. Go through it card by card, learn it until you can
        write every answer, test yourself, or match the pairs against the clock. Your sets are
        private, free, and a set you have opened works offline.
      </p>
      <div className="flashcards__actions">
        <button
          type="button"
          className="btn btn--primary"
          aria-disabled={cannotMake}
          aria-describedby={cannotMake ? 'flashcards-make-note' : undefined}
          onClick={() => {
            if (!cannotMake) open('new');
          }}
        >
          New set
        </button>
        <button
          type="button"
          className="btn"
          aria-disabled={cannotMake}
          aria-describedby={cannotMake ? 'flashcards-make-note' : undefined}
          onClick={() => {
            if (!cannotMake) open('import');
          }}
        >
          Import a set
        </button>
      </div>
      {cannotMake && !fromDevice && (
        <p id="flashcards-make-note" className="form-note">
          {cannotMakeReason}
        </p>
      )}
      {fromDevice && (
        <p id="flashcards-make-note" className="flashcards__offline" role="status">
          You are offline. These are the sets opened on this device, and you can study any of them.
          Making, importing, editing or deleting a set needs a connection.
        </p>
      )}

      {sets.length === 0 ? (
        <div className="stack flashcards__empty">
          <h2 className="flashcards__subheading">
            {fromDevice ? 'No sets on this device yet.' : 'You have no sets yet.'}
          </h2>
          <p>
            {fromDevice
              ? 'A set is kept here once you open it with a connection.'
              : 'Start one with New set, or bring in a list you already have with Import a set — a Quizlet export pastes straight in.'}
          </p>
        </div>
      ) : (
        <ol className="flashcards__list">
          {sets.map((s) => (
            <li key={s.id} className="flashcards__item">
              <button
                type="button"
                className="btn btn--plain flashcards__title"
                dir="auto"
                onClick={() => onNavigate(`/flashcards/${encodeURIComponent(s.id)}`)}
              >
                {s.title}
              </button>
              <span className="flashcards__status">
                {cardCount(s.cardCount)}
                {shortDate(s.updatedAt) && ` · Changed ${shortDate(s.updatedAt)}`}
              </span>
              {s.description && (
                <p className="flashcards__description-line" dir="auto">
                  {s.description}
                </p>
              )}
            </li>
          ))}
        </ol>
      )}
      <p className="meta">
        Private to you. Nothing here is published or sent to a model
        {sets.length > 0 && !fromDevice
          ? ` · ${sets.length} of ${SET_LIMIT} sets · ${totalCards.toLocaleString('en')} of ${TOTAL_CARD_LIMIT.toLocaleString('en')} cards`
          : ''}
        .
      </p>
    </section>
  );
}
