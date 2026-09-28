/**
 * `/flashcards`: the reader's sets, and the two ways to make one -- typing it, or importing
 * it from text. Making a set and importing one are tab state on this page rather than
 * addresses, as a set's study modes are on its own: they are things done here, not places
 * someone could be sent.
 *
 * Offline, the list is the sets opened on this device, which can still be studied; making
 * and importing need a connection and say so.
 */
import { useEffect, useRef, useState } from 'react';
import { FlashcardEditor } from '../components/FlashcardEditor.js';
import { FlashcardImport } from '../components/FlashcardImport.js';
import { cardCount, shortDate, useFocusAfter, useOnline } from '../components/FlashcardParts.js';
import {
  CARD_LIMIT,
  SET_LIMIT,
  SUGGESTION_MIN,
  TITLE_MAX,
  TOTAL_CARD_LIMIT,
  longerThan,
  newDraft,
  saveRefusal,
  type FlashcardSetSummary,
  type SavePayload,
  type SuggestedCard,
} from '../lib/flashcards.js';
import { fetchSets, fetchSuggestion, saveSet } from '../lib/flashcards-api.js';
import {
  isOfflineFailure,
  onReconnect,
  pruneFlashcardSets,
  readFlashcardSets,
} from '../lib/offline.js';
import { sqlDetail, sqlState } from '../lib/rpc-error.js';
import { recordId } from '../lib/submission.js';

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
  const [newId, setNewId] = useState(recordId);
  const [importTitle, setImportTitle] = useState('');
  const [importError, setImportError] = useState<string | null>(null);
  // The screen whose import is on its way, by its id: the state is the page's, and a screen
  // opened after is not the one saving.
  const [importingId, setImportingId] = useState<string | null>(null);
  // Cards suggested from the reader's reading, and the id the set is made under: both fixed
  // once read, so an add retried after a lost answer makes the same set with the same cards.
  const [suggestion, setSuggestion] = useState<{ id: string; cards: SuggestedCard[] } | null>(null);
  const [adding, setAdding] = useState(false);
  const [suggestionError, setSuggestionError] = useState<string | null>(null);
  const importing = importingId !== null && importingId === newId;
  // The new set's id while its screen -- New set or Import -- is the one showing, and null on
  // the list or once this page has gone: a save answers only the screen it was made from.
  const showing = useRef<string | null>(null);
  const mounted = useRef(true);
  useEffect(() => {
    showing.current = view === 'list' ? null : newId;
  }, [view, newId]);
  useEffect(() => {
    mounted.current = true;
    return () => {
      mounted.current = false;
      showing.current = null;
    };
  }, []);

  useEffect(() => {
    const controller = new AbortController();
    /*
     * Arriving here from a set that is gone -- "Leave it deleted", a set deleted elsewhere --
     * the pressed control went with its screen and focus fell to the page. The list's heading
     * takes it once the list is drawn, as a set's title does on its own page.
     */
    const arrived = () => {
      if (document.activeElement === document.body) focusAfter(LIST_TITLE);
    };
    const fromThisDevice = async () => {
      const kept = await readFlashcardSets(userId);
      if (controller.signal.aborted) return;
      setSets(kept);
      setFromDevice(true);
      setError(null);
      setSettled(true);
      arrived();
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
        arrived();
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
  }, [userId, attempt, focusAfter]);

  // The suggestion is read beside the list, online. It is an offer, not the page: if it
  // cannot be read, it is simply not made. Once offered it is kept, ids and all, across a
  // reconnect or a reread: an add whose answer was lost is retried as the same set, not made
  // a second time under new ids. Only a suggestion too small to offer is replaced.
  useEffect(() => {
    if (!online || fromDevice) return;
    const controller = new AbortController();
    fetchSuggestion(recordId, controller.signal)
      .then((cards) => {
        if (controller.signal.aborted) return;
        setSuggestion((kept) =>
          kept && kept.cards.length >= SUGGESTION_MIN ? kept : { id: recordId(), cards },
        );
      })
      .catch((e: unknown) => {
        if (!controller.signal.aborted) console.warn('Suggested flashcards request failed', e);
      });
    return () => controller.abort();
  }, [userId, attempt, online, fromDevice]);

  // A list read from this device is read from the account again when the connection is back.
  useEffect(() => {
    if (!fromDevice) return;
    return onReconnect(() => setAttempt((n) => n + 1));
  }, [fromDevice]);

  const open = (next: View) => {
    setView(next);
    setImportError(null);
    if (next !== 'list') setNewId(recordId());
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

  // What the suggestion adds: as many of its cards as the account has room for.
  const suggested = suggestion ? suggestion.cards.slice(0, Math.max(0, cardRoom)) : [];
  const offerSuggestion = !cannotMake && suggested.length >= SUGGESTION_MIN;

  const addSuggestion = async () => {
    if (!suggestion || adding || !offerSuggestion) return;
    setAdding(true);
    setSuggestionError(null);
    try {
      const out = await saveSet({
        id: suggestion.id,
        title: `From your reading, ${shortDate(new Date().toISOString())}`,
        description:
          'Ideas you have read, most due for review first: each Pull’s headline and what it says.',
        termLang: null,
        definitionLang: null,
        cards: suggested,
      });
      // Opens the set only from the list it was added on. New set and Import wait while an add
      // is on its way; were the list gone, it is read again instead of pulling the reader off.
      if (!mounted.current) return;
      if (showing.current === null) onNavigate(`/flashcards/${encodeURIComponent(out.id)}`);
      else setAttempt((n) => n + 1);
    } catch (e: unknown) {
      if (!mounted.current) return;
      setSuggestionError(
        isOfflineFailure(e)
          ? 'That did not reach your account — you look offline. Try again once you are connected.'
          : (saveRefusal(sqlState(e), sqlDetail(e), e instanceof Error ? e.message : '') ??
              (e instanceof Error ? e.message : 'The set could not be made.')),
      );
    } finally {
      if (mounted.current) setAdding(false);
    }
  };

  /*
   * A save opens the set it made -- if the reader is still on the screen they pressed Save on.
   * The screen, not the set's id: a new set's kept draft goes on under the id its first
   * screen minted, which no later screen has. Every way off these screens is held while a
   * save is on its way, so the other branch is a defence: were the screen gone, the reader
   * is not pulled back to the set, and the list reads it in.
   */
  const saved = async (payload: SavePayload) => {
    const from = showing.current;
    const out = await saveSet(payload);
    if (from !== null && showing.current === from) {
      onNavigate(`/flashcards/${encodeURIComponent(out.id)}`);
    } else if (mounted.current) {
      setAttempt((n) => n + 1);
    }
  };

  if (view === 'new') {
    return (
      <FlashcardEditor
        key={newId}
        userId={userId}
        initial={newDraft(newId, recordId)}
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
      const screen = newId;
      setImportingId(screen);
      setImportError(null);
      try {
        await saved({
          id: newId,
          title,
          description: null,
          termLang: null,
          definitionLang: null,
          cards: cards.map((c) => ({ id: recordId(), ...c })),
        });
      } catch (e: unknown) {
        setImportError(
          isOfflineFailure(e)
            ? 'That did not reach your account — you look offline. Nothing is lost: try again once you are connected.'
            : (saveRefusal(sqlState(e), sqlDetail(e), e instanceof Error ? e.message : '') ??
                (e instanceof Error ? e.message : 'The set could not be saved.')),
        );
      } finally {
        setImportingId((now) => (now === screen ? null : now));
      }
    };
    return (
      <section className="stack measure flashcards" aria-labelledby={IMPORT_TITLE}>
        <div className="flashcards__bar">
          <button
            type="button"
            className="btn btn--plain meta"
            // Held while the set is made, as the editor's ways out are: a failure is said here.
            aria-disabled={importing}
            onClick={() => {
              if (!importing) open('list');
            }}
          >
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
            // Held while the set is made under it, as the editor's boxes are.
            readOnly={importing}
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
          aria-disabled={cannotMake || adding}
          aria-describedby={cannotMake ? 'flashcards-make-note' : undefined}
          onClick={() => {
            if (!cannotMake && !adding) open('new');
          }}
        >
          New set
        </button>
        <button
          type="button"
          className="btn"
          aria-disabled={cannotMake || adding}
          aria-describedby={cannotMake ? 'flashcards-make-note' : undefined}
          onClick={() => {
            if (!cannotMake && !adding) open('import');
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

      {offerSuggestion && (
        <section className="stack flashcards__suggestion" aria-labelledby="flashcards-suggestion">
          <h2 id="flashcards-suggestion" className="flashcards__subheading">
            Suggested from your reading
          </h2>
          <p>
            {cardCount(suggested.length)} from the ideas you have read, the ones most due for review
            first: each Pull’s headline, and what it says. Adding them makes a set of your own, like
            any other.
          </p>
          <div className="flashcards__actions">
            <button
              type="button"
              className="btn"
              aria-disabled={adding}
              onClick={() => void addSuggestion()}
            >
              {adding ? 'Adding…' : 'Add as a set'}
            </button>
          </div>
          {suggestionError && (
            <p className="form-note" role="alert">
              {suggestionError}
            </p>
          )}
        </section>
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
