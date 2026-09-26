/**
 * `/flashcards/:id`: one of the reader's sets -- its cards, the four ways to study it, and
 * editing, downloading and deleting it. The modes and the editor are tab state on this
 * page: a set is something a reader could bookmark, a mode is something they do in it.
 *
 * Every set opened here is kept on this device, so it can be studied without a connection;
 * offline, the page reads that copy and says so, and the controls that change the set wait
 * for a connection. A set that is not the reader's -- or not anyone's -- reads "No such set",
 * one answer for both, because RLS makes them the same thing.
 */
import { useCallback, useEffect, useState } from 'react';
import { FlashcardEditor } from '../components/FlashcardEditor.js';
import { FlashcardLearn } from '../components/FlashcardLearn.js';
import { FlashcardMatch } from '../components/FlashcardMatch.js';
import {
  cardCount,
  shortDate,
  typingIn,
  useFocusAfter,
  useOnline,
} from '../components/FlashcardParts.js';
import { FlashcardRound } from '../components/FlashcardRound.js';
import { FlashcardTest } from '../components/FlashcardTest.js';
import { downloadText } from '../lib/download.js';
import { canMatch, draftOf, type FlashcardSet, type SavePayload } from '../lib/flashcards.js';
import { deleteSet, fetchSet, saveSet } from '../lib/flashcards-api.js';
import { exportFileName, toTsv } from '../lib/flashcards-import.js';
import {
  cacheFlashcardSet,
  clearFlashcardStorage,
  isOfflineFailure,
  onReconnect,
  readFlashcardSet,
  removeFlashcardSet,
} from '../lib/offline.js';

type View =
  | { kind: 'overview' }
  | { kind: 'edit' }
  | { kind: 'cards' }
  | { kind: 'learn'; cardIds: string[] }
  | { kind: 'test' }
  | { kind: 'match' };

const TITLE_ID = 'flashcard-set-title';
const MODE_TITLE_ID = 'flashcard-set-mode-title';
const EDIT_TITLE_ID = 'flashcard-set-edit-title';

const MODES: { kind: 'cards' | 'learn' | 'test' | 'match'; name: string; says: string }[] = [
  { kind: 'cards', name: 'Flashcards', says: 'One card at a time. Say which you know.' },
  {
    kind: 'learn',
    name: 'Learn',
    says: 'Multiple choice, then writing the answer, until you have every card.',
  },
  { kind: 'test', name: 'Test', says: 'A page of questions, marked all at once.' },
  { kind: 'match', name: 'Match', says: 'Pair terms with definitions against the clock.' },
];

export function FlashcardSetPage({
  userId,
  setId,
  onNavigate,
  onTitle,
}: {
  userId: string;
  setId: string;
  onNavigate: (to: string) => void;
  onTitle?: (title: string | null) => void;
}) {
  const online = useOnline();
  const focusAfter = useFocusAfter();
  const [set, setSet] = useState<FlashcardSet | null>(null);
  const [fromDevice, setFromDevice] = useState(false);
  const [settled, setSettled] = useState(false);
  const [missing, setMissing] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [attempt, setAttempt] = useState(0);
  const [view, setView] = useState<View>({ kind: 'overview' });
  const [notice, setNotice] = useState<string | null>(null);
  const [armed, setArmed] = useState(false);
  const [working, setWorking] = useState(false);
  const [actionError, setActionError] = useState<string | null>(null);
  const [deleted, setDeleted] = useState(false);
  // Opening the editor again -- on the latest version of the set -- is a new editor.
  const [editing, setEditing] = useState(0);

  useEffect(() => {
    const controller = new AbortController();
    const fromThisDevice = async () => {
      const kept = await readFlashcardSet(userId, setId);
      if (controller.signal.aborted) return;
      if (kept) {
        setSet(kept);
        setFromDevice(true);
        setError(null);
        onTitle?.(kept.title);
      } else {
        setError('You look offline, and this set has not been opened on this device before.');
      }
      setSettled(true);
    };
    /*
     * OFFLINE, THE DEVICE FIRST. A request made without a network is not refused at once:
     * supabase-js retries a read, and the page said "Loading…" for seven seconds before it
     * read the copy it had all along. The browser saying it is offline is trusted -- only
     * that way round (`useOnline`) -- and the account is read when the connection returns.
     */
    if (typeof navigator !== 'undefined' && navigator.onLine === false) {
      void fromThisDevice();
      return () => controller.abort();
    }
    fetchSet(setId, controller.signal)
      .then((found) => {
        if (controller.signal.aborted) return;
        if (!found) {
          setMissing(true);
          setSet(null);
          onTitle?.(null);
          // Gone from the account, so gone from this device too: its copy and its keys.
          void removeFlashcardSet(userId, setId);
          clearFlashcardStorage(userId, (_, keyed) => keyed === setId);
        } else {
          setSet(found);
          setMissing(false);
          onTitle?.(found.title);
          void cacheFlashcardSet(userId, found);
          // Arriving here -- from the list, or from a set just made -- the pressed control is
          // gone and focus has fallen to the page; the set's title takes it.
          if (document.activeElement === document.body) focusAfter(TITLE_ID);
        }
        setFromDevice(false);
        setError(null);
        setSettled(true);
      })
      .catch(async (e: unknown) => {
        if (controller.signal.aborted) return;
        if (isOfflineFailure(e)) {
          await fromThisDevice();
          return;
        }
        console.error('Flashcard set request failed', e);
        setError(e instanceof Error ? e.message : String(e));
        setSettled(true);
      });
    return () => controller.abort();
  }, [userId, setId, attempt, onTitle, focusAfter]);

  // A copy read from this device is read from the account again when the connection is back.
  useEffect(() => {
    if (!fromDevice) return;
    return onReconnect(() => setAttempt((n) => n + 1));
  }, [fromDevice]);

  // The title the set gave the page -- the reader's own words -- goes with the page.
  useEffect(() => () => onTitle?.(null), [onTitle]);

  const toOverview = useCallback(() => {
    setView({ kind: 'overview' });
    focusAfter(TITLE_ID);
    window.scrollTo(0, 0);
  }, [focusAfter]);

  const openMode = (next: View) => {
    setView(next);
    setNotice(null);
    setArmed(false);
    focusAfter(next.kind === 'edit' ? EDIT_TITLE_ID : MODE_TITLE_ID);
    window.scrollTo(0, 0);
  };

  // Escape leaves a study mode, as "Back to the set" does -- not the editor, where it would
  // be too easy a way to lose what was typed, and not from inside a field.
  const inMode = view.kind !== 'overview' && view.kind !== 'edit';
  useEffect(() => {
    if (!inMode) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key !== 'Escape' || e.defaultPrevented || typingIn(e.target)) return;
      e.preventDefault();
      toOverview();
    };
    document.addEventListener('keydown', onKey);
    return () => document.removeEventListener('keydown', onKey);
  }, [inMode, toOverview]);

  const back = (
    <button type="button" className="btn btn--plain meta" onClick={() => onNavigate('/flashcards')}>
      ← Flashcards
    </button>
  );

  if (!settled) {
    return (
      <p className="meta" role="status">
        Loading…
      </p>
    );
  }

  if (deleted) {
    return (
      <section className="stack measure flashcards" aria-labelledby={TITLE_ID}>
        {back}
        <h1 id={TITLE_ID} tabIndex={-1}>
          The set is deleted.
        </h1>
        <p>Its cards went with it, from your account and from this device.</p>
      </section>
    );
  }

  if (error && !set) {
    return (
      <section className="stack measure flashcards" role="alert">
        {back}
        <h1>Could not load this set.</h1>
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

  if (missing || !set) {
    return (
      <section className="stack measure flashcards">
        {back}
        <h1>No such set.</h1>
        <p>It may have been deleted, or the address may be mistyped.</p>
      </section>
    );
  }

  const leaveMode = toOverview;

  /** Everything of this set's on the device: its copy, its round, its best time, its draft. */
  const forgetHere = (id: string) => {
    void removeFlashcardSet(userId, id);
    clearFlashcardStorage(userId, (_, keyed) => keyed === id);
  };

  switch (view.kind) {
    case 'edit':
      return (
        <FlashcardEditor
          key={editing}
          userId={userId}
          initial={draftOf(set)}
          saved={set}
          heading={`Edit ${set.title}`}
          headingId={EDIT_TITLE_ID}
          online={online && !fromDevice}
          onSave={async (payload: SavePayload) => {
            const out = await saveSet(payload);
            // Read back rather than assumed, so what is studied and kept on this device is
            // what the account holds -- and if the read fails, the save still happened, so
            // the page shows what was saved rather than calling it unsaved.
            const fresh = await fetchSet(set.id).catch(() => null);
            const next: FlashcardSet = fresh ?? {
              id: payload.id,
              title: payload.title,
              description: payload.description,
              termLang: payload.termLang,
              definitionLang: payload.definitionLang,
              updatedAt: out.updatedAt,
              cards: payload.cards,
            };
            setSet(next);
            onTitle?.(next.title);
            void cacheFlashcardSet(userId, next);
            setNotice('Saved.');
            toOverview();
          }}
          onLeave={toOverview}
          leaveLabel={set.title}
          onLoadLatest={() => {
            void fetchSet(set.id)
              .then((fresh) => {
                if (!fresh) {
                  forgetHere(set.id);
                  setMissing(true);
                  setSet(null);
                  onTitle?.(null);
                  return;
                }
                setSet(fresh);
                onTitle?.(fresh.title);
                void cacheFlashcardSet(userId, fresh);
                setEditing((n) => n + 1);
                focusAfter(EDIT_TITLE_ID);
              })
              .catch((e: unknown) => {
                setView({ kind: 'overview' });
                setActionError(
                  isOfflineFailure(e)
                    ? 'The latest version could not be read — you look offline.'
                    : e instanceof Error
                      ? e.message
                      : String(e),
                );
              });
          }}
          onGone={() => {
            forgetHere(set.id);
            onNavigate('/flashcards');
          }}
        />
      );
    // Each mode is keyed on the version of the set it was opened on. A copy read offline is
    // read again when the connection returns, and a version changed elsewhere -- a card gone
    // from under the round -- starts the mode afresh on it rather than drawing a blank.
    case 'cards':
      return (
        <FlashcardRound
          key={set.updatedAt}
          set={set}
          userId={userId}
          headingId={MODE_TITLE_ID}
          onLeave={leaveMode}
        />
      );
    case 'learn':
      return (
        <FlashcardLearn
          key={`${set.updatedAt}:${view.cardIds.join(',')}`}
          set={set}
          cardIds={view.cardIds}
          headingId={MODE_TITLE_ID}
          onLeave={leaveMode}
        />
      );
    case 'test':
      return (
        <FlashcardTest
          key={set.updatedAt}
          set={set}
          headingId={MODE_TITLE_ID}
          onLeave={leaveMode}
          onLearnMissed={(cardIds) => openMode({ kind: 'learn', cardIds })}
        />
      );
    case 'match':
      return (
        <FlashcardMatch
          key={set.updatedAt}
          set={set}
          userId={userId}
          headingId={MODE_TITLE_ID}
          onLeave={leaveMode}
        />
      );
    case 'overview':
      break;
  }

  const canChange = online && !fromDevice;
  const matchable = canMatch(set.cards);

  const remove = async () => {
    if (working || !canChange) return;
    if (!armed) {
      setArmed(true);
      focusAfter('flashcard-set-delete-warning');
      return;
    }
    setWorking(true);
    setActionError(null);
    try {
      // False is a set already gone -- deleted in another tab -- which is done all the same.
      await deleteSet(set.id);
      forgetHere(set.id);
      setDeleted(true);
      onTitle?.(null);
      focusAfter(TITLE_ID);
    } catch (e: unknown) {
      setActionError(
        isOfflineFailure(e)
          ? 'That did not reach your account — you look offline.'
          : e instanceof Error
            ? e.message
            : String(e),
      );
    } finally {
      setWorking(false);
    }
  };

  return (
    <section className="stack measure flashcards" aria-labelledby={TITLE_ID}>
      <div className="flashcards__bar">{back}</div>
      <p className="meta">
        Flashcard set · {cardCount(set.cards.length)}
        {shortDate(set.updatedAt) && ` · Changed ${shortDate(set.updatedAt)}`}
      </p>
      <h1 id={TITLE_ID} tabIndex={-1} dir="auto">
        {set.title}
      </h1>
      {set.description && (
        <p className="flashcards__lede" dir="auto">
          {set.description}
        </p>
      )}
      {/* Always drawn: a live region added together with its text is not reliably announced. */}
      <p role="status" className={notice ? 'flashcards__notice' : 'sr-only'}>
        {notice}
      </p>
      {fromDevice && (
        <p className="flashcards__offline">
          You are offline, so this is the copy kept on this device. You can study it and download
          it; editing and deleting it need a connection.
        </p>
      )}

      <h2 className="flashcards__subheading">Study</h2>
      <ul className="flashcards__modes">
        {MODES.map((m) => {
          const unavailable = m.kind === 'match' && !matchable;
          return (
            <li key={m.kind} className="flashcards__mode">
              <button
                type="button"
                className="btn btn--plain flashcards__mode-name"
                aria-disabled={unavailable}
                aria-describedby={`flashcard-mode-${m.kind}`}
                onClick={() => {
                  if (unavailable) return;
                  openMode(
                    m.kind === 'learn'
                      ? { kind: 'learn', cardIds: set.cards.map((c) => c.id) }
                      : { kind: m.kind },
                  );
                }}
              >
                {m.name}
              </button>
              <span id={`flashcard-mode-${m.kind}`} className="flashcards__mode-says">
                {unavailable
                  ? 'Needs two cards whose terms and definitions all read differently.'
                  : m.says}
              </span>
            </li>
          );
        })}
      </ul>

      <h2 className="flashcards__subheading">Cards</h2>
      <ol className="flashcards__cards">
        {set.cards.map((c) => (
          <li key={c.id} className="flashcards__pair">
            <span className="flashcards__pair-term" dir="auto">
              {c.term}
            </span>
            <span className="flashcards__pair-definition" dir="auto">
              {c.definition}
            </span>
          </li>
        ))}
      </ol>

      <div className="flashcards__actions">
        <button
          type="button"
          className="btn"
          aria-disabled={!canChange}
          aria-describedby={!canChange ? 'flashcard-set-offline-note' : undefined}
          onClick={() => {
            if (canChange) openMode({ kind: 'edit' });
          }}
        >
          Edit
        </button>
        <button
          type="button"
          className="btn"
          onClick={() =>
            downloadText(exportFileName(set.title), 'text/plain;charset=utf-8', toTsv(set.cards))
          }
        >
          Download as text
        </button>
      </div>
      <p className="form-note">
        The download has a card a line, with a tab between the term and its definition — what
        Quizlet’s and Anki’s imports read, and Import a set here too.
      </p>
      {!canChange && (
        <p id="flashcard-set-offline-note" className="form-note">
          Editing and deleting need a connection.
        </p>
      )}

      {actionError && (
        <p className="remember__error" role="alert">
          {actionError}
        </p>
      )}
      {armed ? (
        <div className="stack" role="group" aria-labelledby="flashcard-set-delete-warning">
          <p id="flashcard-set-delete-warning" tabIndex={-1}>
            Deleting this set removes it and its {cardCount(set.cards.length)} from your account and
            from this device. It cannot be undone; download it first if you might want it back.
          </p>
          <div className="flashcards__actions">
            <button
              type="button"
              className="btn"
              aria-disabled={working}
              onClick={() => void remove()}
            >
              {working ? 'Deleting…' : 'Delete the set'}
            </button>
            <button
              type="button"
              className="btn btn--plain"
              onClick={() => {
                setArmed(false);
                focusAfter('flashcard-set-delete');
              }}
            >
              Keep it
            </button>
          </div>
        </div>
      ) : (
        <p>
          <button
            id="flashcard-set-delete"
            type="button"
            className="btn btn--plain"
            aria-disabled={working || !canChange}
            aria-describedby={!canChange ? 'flashcard-set-offline-note' : undefined}
            onClick={() => void remove()}
          >
            Delete this set
          </button>
        </p>
      )}
      <p className="meta">
        This set is private to you. It is never published, and nothing in it is sent to a model.
      </p>
    </section>
  );
}
