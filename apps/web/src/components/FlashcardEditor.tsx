/**
 * Making or changing a set: its title, a description, the languages its sides are in, and
 * its cards as rows of term and definition -- added, removed and moved with buttons, so
 * nothing needs a drag. Cards can also be added from pasted text or a file.
 *
 * Saving needs a connection; the button says so rather than failing. A save that is refused
 * is said in words, from the refusal's SQLSTATE and DETAIL. Leaving with changes not saved
 * by the editor's own ways out asks once, as a course correction does: the first press says
 * so beside the control, the second leaves.
 *
 * AND ANY OTHER WAY OUT KEEPS THEM. The masthead, the browser's Back and a closed tab all
 * left this screen without asking, and what was typed went with it. So the draft is kept in
 * this tab's `sessionStorage` while it differs from the set -- written a moment after typing
 * stops, and at once when focus leaves the form -- and the editor, opened again, starts from
 * it and says so. Closing or reloading the tab asks first (`beforeunload`). The draft goes
 * when it is saved or let go, when the set is deleted, and when the reader signs out.
 *
 * TWO SCREENS DO NOT SAVE OVER EACH OTHER. A save names the version of the set the editor
 * began from, and one that has changed since -- saved in another tab -- or been deleted is
 * refused. The reader then chooses: the latest version, or theirs over it.
 */
import {
  memo,
  useCallback,
  useDeferredValue,
  useEffect,
  useId,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
} from 'react';
import {
  CARD_LIMIT,
  DEFINITION_MAX,
  DESCRIPTION_MAX,
  TERM_MAX,
  TITLE_MAX,
  draftKey,
  draftUnsaved,
  moveDraftCard,
  readKeptDraft,
  saveConflict,
  saveRefusal,
  validateDraft,
  type DraftCard,
  type FlashcardSet,
  type SavePayload,
  type SetDraft,
} from '../lib/flashcards.js';
import { isOfflineFailure } from '../lib/offline.js';
import { sqlDetail, sqlState } from '../lib/rpc-error.js';
import { mutationId } from '../lib/submission.js';
import { FlashcardImport } from './FlashcardImport.js';
import { cardCount, readStored, useFocusAfter, writeStored } from './FlashcardParts.js';

/**
 * Languages a reader is likely to study, by the tag a voice is chosen with. "Other" takes
 * any tag, since a list of every language is a worse control than a box for the rest.
 */
const LANGUAGES: readonly [string, string][] = [
  ['en', 'English'],
  ['es', 'Spanish'],
  ['fr', 'French'],
  ['de', 'German'],
  ['it', 'Italian'],
  ['pt', 'Portuguese'],
  ['nl', 'Dutch'],
  ['ru', 'Russian'],
  ['ar', 'Arabic'],
  ['hi', 'Hindi'],
  ['zh', 'Chinese'],
  ['ja', 'Japanese'],
  ['ko', 'Korean'],
  ['la', 'Latin'],
];

/** How long typing has to pause before the draft is written to the tab's storage. */
const KEEP_AFTER_MS = 400;

/**
 * `maxLength` counts UTF-16 units and the limits are characters, of which an emoji is two
 * units. So each box stops at twice its limit: never short of a text the database takes, and
 * still a stop for a paste of a whole book. `validateDraft` says the limit in characters.
 */
const units = (characters: number) => characters * 2;

function LanguageChoice({
  label,
  value,
  onChange,
}: {
  label: string;
  value: string;
  onChange: (tag: string) => void;
}) {
  const id = useId();
  const known = LANGUAGES.some(([tag]) => tag === value);
  // "Other" is a choice of its own, kept while its box is empty rather than falling back.
  const [other, setOther] = useState(value !== '' && !known);
  const selected = other ? 'other' : value;
  return (
    <div className="field flashcards__lang">
      <label className="field__label" htmlFor={`${id}-select`}>
        {label}
      </label>
      <select
        id={`${id}-select`}
        className="field__input"
        value={selected}
        onChange={(e) => {
          const v = e.target.value;
          setOther(v === 'other');
          onChange(v === 'other' ? '' : v);
        }}
      >
        <option value="">Not set</option>
        {LANGUAGES.map(([tag, name]) => (
          <option key={tag} value={tag}>
            {name}
          </option>
        ))}
        <option value="other">Other…</option>
      </select>
      {other && (
        <input
          className="field__input flashcards__custom"
          aria-label={`${label}: a language code, such as “sv” or “pt-BR”`}
          placeholder="e.g. sv or pt-BR"
          value={value}
          maxLength={35}
          // Enter here finishes a code, not the set: it does not save the form around it.
          onKeyDown={(e) => {
            if (e.key === 'Enter') e.preventDefault();
          }}
          onChange={(e) => onChange(e.target.value.trim())}
        />
      )}
    </div>
  );
}

/**
 * One card's row. Every keystroke used to draw every row -- 2,400 textareas at 1,200 cards, a
 * tenth of a second or more a key, and over a second on a slow phone -- so a key now draws
 * none of them. The row is memoised, its handlers are the editor's stable callbacks, and its
 * boxes are the browser's own (`defaultValue`): what is typed is on screen as it is typed, and
 * reaches the draft through `onChange`, with nothing to draw in between. The list around them
 * is drawn from a deferred copy of the cards, off the path of the key.
 *
 * Nothing else writes into a box once it is drawn: a row added, moved or removed is a row
 * drawn, moved or dropped by its key, and a draft replaced wholesale is a new editor.
 *
 * AND A ROW'S BUTTONS NAME ITS CARD, NOT ITS PLACE. The place a row is drawn with is a draw
 * behind, like the list: Remove card 970 and then, within a draw, Remove card 975 took card 976,
 * and Down held on card 1 moved it back and forth. A button says which card it is on, and the
 * editor finds where that card is in the draft as it is when the press lands.
 */
const FlashcardRow = memo(function FlashcardRow({
  card,
  index,
  last,
  idPrefix,
  onChange,
  onMove,
  onRemove,
}: {
  card: DraftCard;
  index: number;
  last: boolean;
  idPrefix: string;
  onChange: (cardId: string, side: 'term' | 'definition', value: string) => void;
  onMove: (cardId: string, delta: -1 | 1) => void;
  onRemove: (cardId: string) => void;
}) {
  const n = index + 1;
  return (
    <li className="flashcards__row">
      <p className="meta flashcards__row-number">Card {n}</p>
      <div className="flashcards__row-sides">
        <div className="field">
          <label className="field__label" htmlFor={`${idPrefix}-term-${card.id}`}>
            Term<span className="sr-only">, card {n}</span>
          </label>
          <textarea
            id={`${idPrefix}-term-${card.id}`}
            className="field__textarea flashcards__side-input"
            rows={2}
            dir="auto"
            defaultValue={card.term}
            maxLength={units(TERM_MAX)}
            onChange={(e) => onChange(card.id, 'term', e.target.value)}
          />
        </div>
        <div className="field">
          <label className="field__label" htmlFor={`${idPrefix}-definition-${card.id}`}>
            Definition<span className="sr-only">, card {n}</span>
          </label>
          <textarea
            id={`${idPrefix}-definition-${card.id}`}
            className="field__textarea flashcards__side-input"
            rows={2}
            dir="auto"
            defaultValue={card.definition}
            maxLength={units(DEFINITION_MAX)}
            onChange={(e) => onChange(card.id, 'definition', e.target.value)}
          />
        </div>
      </div>
      <div className="flashcards__row-actions">
        <button
          type="button"
          className="btn btn--plain"
          aria-label={`Move card ${n} up`}
          aria-disabled={index === 0}
          onClick={() => onMove(card.id, -1)}
        >
          Up
        </button>
        <button
          type="button"
          className="btn btn--plain"
          aria-label={`Move card ${n} down`}
          aria-disabled={last}
          onClick={() => onMove(card.id, 1)}
        >
          Down
        </button>
        <button
          type="button"
          className="btn btn--plain"
          aria-label={`Remove card ${n}`}
          onClick={() => onRemove(card.id)}
        >
          Remove
        </button>
      </div>
    </li>
  );
});

export function FlashcardEditor({
  userId,
  initial,
  saved,
  heading,
  headingId,
  online,
  onSave,
  onLeave,
  leaveLabel,
  onLoadLatest,
  onGone,
}: {
  userId: string;
  initial: SetDraft;
  /** The set as it is saved, or null for a new one. */
  saved: FlashcardSet | null;
  heading: string;
  headingId: string;
  online: boolean;
  /** Saves the payload, and moves on when it resolves; a rejection is said here. */
  onSave: (payload: SavePayload) => Promise<void>;
  onLeave: () => void;
  leaveLabel: string;
  /** Opens the editor again on the set as the account now has it, these edits let go. */
  onLoadLatest?: () => void;
  /** Leaves a set deleted on another screen deleted. */
  onGone?: () => void;
}) {
  const id = useId();
  const focusAfter = useFocusAfter();
  const keyInStorage = draftKey(userId, saved?.id ?? null);
  // A draft this tab kept for this set -- from a way out that did not ask -- is where the
  // editor starts, and with it the version of the set that draft began from.
  const [kept] = useState(() => {
    const found = readKeptDraft(readStored(keyInStorage, 'session'), saved?.id ?? null);
    return found && draftUnsaved(found.draft, saved) ? found : null;
  });
  const [draft, setDraft] = useState<SetDraft>(kept?.draft ?? initial);
  const [base] = useState<string | null>(kept ? kept.base : (saved?.updatedAt ?? null));
  const [problems, setProblems] = useState<string[]>([]);
  const [saveError, setSaveError] = useState<string | null>(null);
  const [conflict, setConflict] = useState<'changed' | 'gone' | null>(null);
  const [saving, setSaving] = useState(false);
  const held = useRef<HTMLFieldSetElement>(null);
  // A way out pressed once over unsaved changes -- the one above the form or the one below
  // it -- and said beside it: the next press leaves.
  const [leaving, setLeaving] = useState<null | 'top' | 'bottom'>(null);
  const [importing, setImporting] = useState(false);
  const [moved, setMoved] = useState('');
  /*
   * Said in the live region beside the cards. The same words twice -- "Card 5 removed." for
   * two cards in turn -- change nothing in the region, and a screen reader says nothing the
   * second time; so a repeat is told apart by a no-break space, which is not read.
   */
  const announce = useCallback((words: string) => {
    setMoved((said) => (said === words ? `${words}\u00a0` : words));
  }, []);
  // Worked out a draw behind the typing, so a key press never waits on a pass over the set.
  // Only for asking before the tab closes; a way out pressed here asks of the draft as it is.
  const settled = useDeferredValue(draft);
  const unsaved = useMemo(() => draftUnsaved(settled, saved), [settled, saved]);

  // The latest draft, for the handlers below, which are made once and must not go stale.
  const latest = useRef(draft);
  useLayoutEffect(() => {
    latest.current = draft;
  }, [draft]);
  // Set once the draft is saved or let go, after which nothing may write it back.
  const finished = useRef(false);

  const keep = useCallback(() => {
    if (finished.current) return;
    const now = latest.current;
    writeStored(
      keyInStorage,
      draftUnsaved(now, saved) ? JSON.stringify({ draft: now, base }) : null,
      'session',
    );
  }, [keyInStorage, saved, base]);
  const forget = useCallback(() => {
    finished.current = true;
    writeStored(keyInStorage, null, 'session');
  }, [keyInStorage]);

  // A moment after typing stops. Not on the way out: an unmount is also a sign-out, which
  // has just cleared this reader's drafts, and must not find one written back after it.
  useEffect(() => {
    const timer = window.setTimeout(keep, KEEP_AFTER_MS);
    return () => window.clearTimeout(timer);
  }, [draft, keep]);

  // Closing or reloading the tab with changes not saved asks first, and keeps them either way.
  useEffect(() => {
    if (!unsaved) return;
    const onBeforeUnload = (event: BeforeUnloadEvent) => {
      keep();
      event.preventDefault();
      // Some browsers still ask only when this is set.
      event.returnValue = '';
    };
    window.addEventListener('beforeunload', onBeforeUnload);
    return () => window.removeEventListener('beforeunload', onBeforeUnload);
  }, [unsaved, keep]);

  const change = (next: Partial<SetDraft>) => {
    setDraft((d) => ({ ...d, ...next }));
    setLeaving(null);
  };
  const changeCard = useCallback((cardId: string, side: 'term' | 'definition', value: string) => {
    setDraft((d) => ({
      ...d,
      cards: d.cards.map((c) => (c.id === cardId ? { ...c, [side]: value } : c)),
    }));
    setLeaving(null);
  }, []);

  const addCard = () => {
    const card = { id: mutationId(), term: '', definition: '' };
    setDraft((d) => ({ ...d, cards: [...d.cards, card] }));
    focusAfter(`${id}-term-${card.id}`);
  };

  /*
   * By the card's id, found in the draft as it is. `latest` is the draft as last drawn, and
   * each press moves it on at once, so a second press before the first is drawn finds the
   * cards the first left; the update finds the card again in whatever draft it is applied to,
   * so it moves or removes that card and no other. A press on a row whose card is already
   * gone does nothing, and says nothing.
   */
  const removeCard = useCallback(
    (cardId: string) => {
      const cards = latest.current.cards;
      const index = cards.findIndex((c) => c.id === cardId);
      if (index < 0) return;
      const after = cards[index + 1] ?? cards[index - 1];
      latest.current = { ...latest.current, cards: cards.filter((c) => c.id !== cardId) };
      setDraft((d) => ({ ...d, cards: d.cards.filter((c) => c.id !== cardId) }));
      announce(`Card ${index + 1} removed.`);
      focusAfter(after ? `${id}-term-${after.id}` : `${id}-add`);
    },
    [announce, focusAfter, id],
  );

  const move = useCallback(
    (cardId: string, delta: -1 | 1) => {
      const cards = latest.current.cards;
      const index = cards.findIndex((c) => c.id === cardId);
      const to = index + delta;
      if (index < 0 || to < 0 || to >= cards.length) return;
      latest.current = { ...latest.current, cards: moveDraftCard(cards, index, delta) };
      setDraft((d) => {
        const at = d.cards.findIndex((c) => c.id === cardId);
        const next = at + delta;
        return at < 0 || next < 0 || next >= d.cards.length
          ? d
          : { ...d, cards: moveDraftCard(d.cards, at, delta) };
      });
      announce(`Card ${index + 1} is now card ${to + 1} of ${cards.length}.`);
    },
    [announce],
  );

  /** Saves the draft -- over a newer version of the set when the reader chose that. */
  const save = async (over = false) => {
    if (saving) return;
    setSaveError(null);
    if (!online) {
      setSaveError('You look offline. Saving needs a connection.');
      return;
    }
    const { payload, problems: found } = validateDraft(draft);
    setProblems(found);
    if (!payload) {
      focusAfter(`${id}-problems`);
      return;
    }
    // What is held while the save is on its way (below) cannot keep focus, and a browser drops
    // it to the page: Enter in the title would leave a keyboard reader nowhere. Save, which
    // says "Saving…", takes it instead, without scrolling a long set to its end.
    if (held.current?.contains(document.activeElement)) {
      document.getElementById(`${id}-save`)?.focus({ preventScroll: true });
    }
    setSaving(true);
    try {
      await onSave({ ...payload, baseUpdatedAt: over ? null : base });
      forget();
    } catch (e: unknown) {
      const code = sqlState(e);
      const detail = sqlDetail(e);
      const clash = saved && !over ? saveConflict(code, detail) : null;
      setConflict(clash);
      setSaveError(
        clash
          ? null
          : isOfflineFailure(e)
            ? 'That did not reach your account — you look offline. Your changes are still here.'
            : (saveRefusal(code, detail, e instanceof Error ? e.message : String(e)) ??
              (e instanceof Error ? e.message : 'The set could not be saved.')),
      );
      focusAfter(clash ? `${id}-conflict` : `${id}-save-error`);
    } finally {
      setSaving(false);
    }
  };

  const leave = (where: 'top' | 'bottom') => {
    if (draftUnsaved(draft, saved) && leaving !== where) {
      setLeaving(where);
      return;
    }
    forget();
    onLeave();
  };

  // Always drawn, above the form and below it, and filled only beside the control that was
  // pressed: a live region added together with its text is not reliably announced.
  const unsavedLine = (where: 'top' | 'bottom') => (
    <p role="status" className={leaving === where ? 'remember__error' : 'sr-only'}>
      {leaving === where && 'Your changes are not saved. Press again to leave without saving them.'}
    </p>
  );

  const room = useMemo(
    () => CARD_LIMIT - draft.cards.filter((c) => c.term.trim() || c.definition.trim()).length,
    [draft.cards],
  );
  const formId = `${id}-form`;

  // The rows, from the cards a draw behind: a key's own draw reuses this very list and draws
  // no row at all, and the deferred one compares each row's props and draws the one typed in.
  const shownCards = useDeferredValue(draft.cards);
  const rows = useMemo(
    () => (
      <ol className="flashcards__rows">
        {shownCards.map((c, i) => (
          <FlashcardRow
            key={c.id}
            card={c}
            index={i}
            last={i === shownCards.length - 1}
            idPrefix={id}
            onChange={changeCard}
            onMove={move}
            onRemove={removeCard}
          />
        ))}
      </ol>
    ),
    [shownCards, id, changeCard, move, removeCard],
  );

  return (
    <section
      className="stack measure flashcards"
      aria-labelledby={headingId}
      // Focus leaving the editor -- for the masthead, say -- keeps the draft at once.
      onBlur={(e) => {
        if (!e.currentTarget.contains(e.relatedTarget as Node | null)) keep();
      }}
    >
      <div className="flashcards__bar">
        <button type="button" className="btn btn--plain meta" onClick={() => leave('top')}>
          ← {leaveLabel}
        </button>
      </div>
      {unsavedLine('top')}
      <h1 id={headingId} tabIndex={-1} dir="auto">
        {heading}
      </h1>
      {kept && (
        <p className="flashcards__notice">
          Your unsaved changes were kept. Save them, or Cancel to let them go.
        </p>
      )}
      {/*
       * HELD WHILE A SAVE IS ON ITS WAY. The save sends the draft as it was when Save was
       * pressed, and a successful one closes the editor and lets its kept draft go -- so what
       * was typed in between was on screen, then gone, and in neither the set nor the draft.
       * A disabled fieldset holds every box and button in it at once, natively, without
       * drawing a row: the rows are memoised, and a prop on each would draw all of them twice.
       * `role="none"`, because it groups nothing a reader needs named.
       */}
      <fieldset ref={held} className="stack flashcards__hold" disabled={saving} role="none">
        <form
          id={formId}
          className="stack"
          onSubmit={(e) => {
            e.preventDefault();
            void save();
          }}
        >
          <div className="field">
            <label className="field__label" htmlFor={`${id}-title`}>
              Title
            </label>
            <input
              id={`${id}-title`}
              className="field__input"
              dir="auto"
              value={draft.title}
              maxLength={units(TITLE_MAX)}
              onChange={(e) => change({ title: e.target.value })}
            />
          </div>
          <div className="field">
            <label className="field__label" htmlFor={`${id}-description`}>
              Description, if you want one
            </label>
            <textarea
              id={`${id}-description`}
              className="field__textarea flashcards__description"
              rows={2}
              dir="auto"
              value={draft.description}
              maxLength={units(DESCRIPTION_MAX)}
              onChange={(e) => change({ description: e.target.value })}
            />
          </div>
          <fieldset className="flashcards__langs">
            <legend className="field__label">Languages, for reading cards aloud</legend>
            <p className="form-note">
              Set these when a side is not in your own language, so Listen uses a voice for it. A
              voice installed on this device reads your cards; nothing is sent anywhere.
            </p>
            <LanguageChoice
              label="Terms are in"
              value={draft.termLang}
              onChange={(termLang) => change({ termLang })}
            />
            <LanguageChoice
              label="Definitions are in"
              value={draft.definitionLang}
              onChange={(definitionLang) => change({ definitionLang })}
            />
          </fieldset>

          <h2 className="flashcards__subheading">Cards</h2>
          <p className="sr-only" role="status">
            {moved}
          </p>
          {rows}
        </form>

        {/* Outside the form: Enter in the importer's boxes is the importer's, not Save. */}
        <div className="flashcards__actions">
          <button id={`${id}-add`} type="button" className="btn" onClick={addCard}>
            Add a card
          </button>
          <button
            type="button"
            className="btn btn--plain"
            aria-expanded={importing}
            aria-controls={`${id}-import`}
            onClick={() => setImporting((o) => !o)}
          >
            Add from text
          </button>
        </div>
        {importing && (
          <div id={`${id}-import`} className="flashcards__inset">
            <FlashcardImport
              headingLevel={3}
              primary={false}
              limit={Math.max(0, room)}
              takeLabel={(n) => (n === 0 ? 'Add cards' : `Add ${cardCount(n)}`)}
              onTake={(cards) => {
                // The unused empty rows go, so the new cards follow the last real one.
                setDraft((d) => ({
                  ...d,
                  cards: [
                    ...d.cards.filter((c) => c.term.trim() || c.definition.trim()),
                    ...cards.map((c) => ({ id: mutationId(), ...c })),
                  ],
                }));
                setImporting(false);
                announce(`${cardCount(cards.length)} added at the end.`);
                focusAfter(`${id}-add`);
              }}
            />
          </div>
        )}
      </fieldset>

      {problems.length > 0 && (
        <div id={`${id}-problems`} tabIndex={-1} className="stack" role="alert">
          <p className="remember__error">The set is not saved yet:</p>
          <ul className="flashcards__problems">
            {problems.map((p) => (
              <li key={p}>{p}</li>
            ))}
          </ul>
        </div>
      )}
      {saveError && (
        <p id={`${id}-save-error`} tabIndex={-1} className="remember__error" role="alert">
          {saveError}
        </p>
      )}
      {conflict && (
        <div className="stack" role="alert">
          <p id={`${id}-conflict`} tabIndex={-1} className="remember__error">
            {conflict === 'changed'
              ? 'This set was changed somewhere else after you opened it — in another tab, or on another device. Saving yours now would undo those changes.'
              : 'This set was deleted somewhere else after you opened it.'}
          </p>
          <div className="flashcards__actions">
            {conflict === 'changed' ? (
              <>
                <button
                  type="button"
                  className="btn"
                  onClick={() => {
                    forget();
                    onLoadLatest?.();
                  }}
                >
                  Load the latest, and let mine go
                </button>
                <button
                  type="button"
                  className="btn btn--plain"
                  aria-describedby={`${id}-conflict`}
                  onClick={() => void save(true)}
                >
                  Save mine over it
                </button>
              </>
            ) : (
              <>
                <button
                  type="button"
                  className="btn"
                  aria-describedby={`${id}-conflict`}
                  onClick={() => void save(true)}
                >
                  Put it back, as it is here
                </button>
                <button
                  type="button"
                  className="btn btn--plain"
                  onClick={() => {
                    forget();
                    onGone?.();
                  }}
                >
                  Leave it deleted
                </button>
              </>
            )}
          </div>
        </div>
      )}
      <div className="flashcards__actions">
        <button
          id={`${id}-save`}
          type="submit"
          form={formId}
          className="btn btn--primary"
          aria-disabled={saving || !online}
          aria-describedby={!online ? `${id}-offline` : undefined}
        >
          {saving ? 'Saving…' : 'Save'}
        </button>
        <button type="button" className="btn btn--plain" onClick={() => leave('bottom')}>
          Cancel
        </button>
      </div>
      {unsavedLine('bottom')}
      {!online && (
        <p id={`${id}-offline`} className="form-note">
          You are offline. Saving needs a connection; your changes stay here until then.
        </p>
      )}
    </section>
  );
}
