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
import { useCallback, useEffect, useRef, useState } from 'react';
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
/** What Escape says when it does not leave a mode holding answers. */
const ESCAPE_HELD =
  'Escape does not leave while you have answers here. Back to the set leaves without them.';
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
  // What the page says: `notice` to a screen reader, through `said` below, and `shown` to
  // the eye -- the same words, at different moments (see the save).
  const [notice, setNotice] = useState<string | null>(null);
  const [shown, setShown] = useState<string | null>(null);
  const [armed, setArmed] = useState(false);
  const [working, setWorking] = useState(false);
  const [actionError, setActionError] = useState<string | null>(null);
  const [deleted, setDeleted] = useState(false);
  // Opening the editor again -- on the latest version of the set -- is a new editor.
  const [editing, setEditing] = useState(0);
  /*
   * Whether this page is still the reader's. A save or a read of the latest version resolves
   * after its awaits, and the page may be gone by then -- the reader signed out, which cleared
   * this device of their sets. Writing the set back to this device then put it under an id
   * nobody is signed in as. The load below checks its own abort signal; these check this.
   */
  const live = useRef(true);
  useEffect(() => {
    live.current = true;
    return () => {
      live.current = false;
    };
  }, []);
  // Which screen is showing, for an answer that lands after its screen may have changed.
  const viewKind = useRef<View['kind']>(view.kind);
  useEffect(() => {
    viewKind.current = view.kind;
  }, [view.kind]);
  /*
   * Whether the mode open now holds work that leaving would throw away: a Test with answers
   * not yet submitted, a Learn with anything answered. Escape does not leave those -- it was
   * the one key between a keyboard reader and the loss of a whole sitting -- and "Back to the
   * set", which has to be pressed, still does. Each mode says so as it changes.
   */
  const work = useRef(false);
  const setWork = useCallback((holds: boolean) => {
    work.current = holds;
    // What Escape said while there was work goes with it -- submitted, say -- rather than
    // staying where a screen reader browsing the page would find it.
    if (!holds) setNotice((now) => (now?.startsWith(ESCAPE_HELD) ? null : now));
  }, []);

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
    setNotice(null);
    focusAfter(TITLE_ID);
    window.scrollTo(0, 0);
  }, [focusAfter]);

  const openMode = (next: View) => {
    setView(next);
    setNotice(null);
    setShown(null);
    setArmed(false);
    focusAfter(next.kind === 'edit' ? EDIT_TITLE_ID : MODE_TITLE_ID);
    window.scrollTo(0, 0);
  };

  // Escape leaves a study mode, as "Back to the set" does -- not the editor, where it would
  // be too easy a way to lose what was typed, not from inside a field, and not from a mode
  // holding work (`work`).
  const inMode = view.kind !== 'overview' && view.kind !== 'edit';
  useEffect(() => {
    if (!inMode) return;
    const onKey = (e: KeyboardEvent) => {
      // A radio is a choice, not typing: focus sits on one after most answers in a Test.
      const choosing =
        e.target instanceof HTMLInputElement &&
        (e.target.type === 'radio' || e.target.type === 'checkbox');
      if (e.key !== 'Escape' || e.defaultPrevented || (typingIn(e.target) && !choosing)) return;
      if (work.current) {
        // Said, since a key that does nothing is otherwise a key that looks broken. The same
        // words twice are told apart by a no-break space, which is not read.
        setNotice((now) => (now === ESCAPE_HELD ? `${ESCAPE_HELD}\u00a0` : ESCAPE_HELD));
        return;
      }
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

  /*
   * "Saved." is said as the editor gives way to the overview, and a live region drawn with its
   * text already in it is not reliably announced -- the overview's own was. So the region is
   * the same element in every view -- the editor, the overview and the modes, where it says
   * why Escape stayed -- last in each, where React keeps it across the switch; the
   * overview's visible line says it to the eye only.
   */
  const said = (
    <p role="status" className="sr-only">
      {notice}
    </p>
  );

  switch (view.kind) {
    case 'edit':
      return (
        <>
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
              if (!live.current) return;
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
              // The editor holds its ways out while it saves, so this is the editor still --
              // and if it is not, the reader is not taken from where they went.
              if (viewKind.current !== 'edit') return;
              // Shown with the overview, so nothing drops a line a frame later; said once focus
              // is on the title, since written with the focus move it was read over.
              setView({ kind: 'overview' });
              setShown('Saved.');
              focusAfter(TITLE_ID, () => {
                if (live.current) setNotice('Saved.');
              });
              window.scrollTo(0, 0);
            }}
            onLeave={toOverview}
            leaveLabel={set.title}
            onLoadLatest={() => {
              void fetchSet(set.id)
                .then((fresh) => {
                  if (!live.current) return;
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
                  if (!live.current) return;
                  setView({ kind: 'overview' });
                  // The pressed control went with the editor; the page's title takes focus.
                  focusAfter(TITLE_ID);
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
          {said}
        </>
      );
    // Each mode is keyed on the version of the set it was opened on. A copy read offline is
    // read again when the connection returns, and a version changed elsewhere -- a card gone
    // from under the round -- starts the mode afresh on it rather than drawing a blank.
    case 'cards':
      return (
        <>
          <FlashcardRound
            key={set.updatedAt}
            set={set}
            userId={userId}
            headingId={MODE_TITLE_ID}
            onLeave={leaveMode}
          />
          {said}
        </>
      );
    case 'learn':
      return (
        <>
          <FlashcardLearn
            key={`${set.updatedAt}:${view.cardIds.join(',')}`}
            set={set}
            cardIds={view.cardIds}
            headingId={MODE_TITLE_ID}
            onLeave={leaveMode}
            onWork={setWork}
          />
          {said}
        </>
      );
    case 'test':
      return (
        <>
          <FlashcardTest
            key={set.updatedAt}
            set={set}
            headingId={MODE_TITLE_ID}
            onLeave={leaveMode}
            onWork={setWork}
            onLearnMissed={(cardIds) => openMode({ kind: 'learn', cardIds })}
          />
          {said}
        </>
      );
    case 'match':
      return (
        <>
          <FlashcardMatch
            key={set.updatedAt}
            set={set}
            userId={userId}
            headingId={MODE_TITLE_ID}
            onLeave={leaveMode}
          />
          {said}
        </>
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
    <>
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
        {/* Said by the region after this section, which outlives the editor (`said`). */}
        {shown && (
          <p className="flashcards__notice" aria-hidden="true">
            {shown}
          </p>
        )}
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
              Deleting this set removes it and its {cardCount(set.cards.length)} from your account
              and from this device. It cannot be undone; download it first if you might want it
              back.
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
      {said}
    </>
  );
}
