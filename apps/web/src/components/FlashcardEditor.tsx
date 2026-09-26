/**
 * Making or changing a set: its title, a description, the languages its sides are in, and
 * its cards as rows of term and definition -- added, removed and moved with buttons, so
 * nothing needs a drag. Cards can also be added from pasted text or a file.
 *
 * Saving needs a connection; the button says so rather than failing. A save that is refused
 * is said in words, from the refusal's SQLSTATE and DETAIL. Leaving with changes not saved
 * asks once, as a course correction does: the first press says so beside the control, the
 * second leaves.
 */
import { useId, useState } from 'react';
import {
  CARD_LIMIT,
  DEFINITION_MAX,
  DESCRIPTION_MAX,
  TERM_MAX,
  TITLE_MAX,
  draftUnsaved,
  moveDraftCard,
  saveRefusal,
  validateDraft,
  type FlashcardSet,
  type SavePayload,
  type SetDraft,
} from '../lib/flashcards.js';
import { isOfflineFailure } from '../lib/offline.js';
import { sqlDetail, sqlState } from '../lib/rpc-error.js';
import { mutationId } from '../lib/submission.js';
import { FlashcardImport } from './FlashcardImport.js';
import { cardCount, useFocusAfter } from './FlashcardParts.js';

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
          onChange={(e) => onChange(e.target.value.trim())}
        />
      )}
    </div>
  );
}

export function FlashcardEditor({
  initial,
  saved,
  heading,
  headingId,
  online,
  onSave,
  onLeave,
  leaveLabel,
}: {
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
}) {
  const id = useId();
  const focusAfter = useFocusAfter();
  const [draft, setDraft] = useState<SetDraft>(initial);
  const [problems, setProblems] = useState<string[]>([]);
  const [saveError, setSaveError] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);
  // A way out pressed once over unsaved changes -- the one above the form or the one below
  // it -- and said beside it: the next press leaves.
  const [leaving, setLeaving] = useState<null | 'top' | 'bottom'>(null);
  const [importing, setImporting] = useState(false);
  const [moved, setMoved] = useState('');
  const unsaved = draftUnsaved(draft, saved);

  const change = (next: Partial<SetDraft>) => {
    setDraft((d) => ({ ...d, ...next }));
    setLeaving(null);
  };
  const changeCard = (cardId: string, side: 'term' | 'definition', value: string) => {
    setDraft((d) => ({
      ...d,
      cards: d.cards.map((c) => (c.id === cardId ? { ...c, [side]: value } : c)),
    }));
    setLeaving(null);
  };

  const addCard = () => {
    const card = { id: mutationId(), term: '', definition: '' };
    setDraft((d) => ({ ...d, cards: [...d.cards, card] }));
    focusAfter(`${id}-term-${card.id}`);
  };

  const removeCard = (index: number) => {
    const after = draft.cards[index + 1] ?? draft.cards[index - 1];
    setDraft((d) => ({ ...d, cards: d.cards.filter((_, i) => i !== index) }));
    setMoved(`Card ${index + 1} removed.`);
    focusAfter(after ? `${id}-term-${after.id}` : `${id}-add`);
  };

  const move = (index: number, delta: -1 | 1) => {
    const to = index + delta;
    if (to < 0 || to >= draft.cards.length) return;
    setDraft((d) => ({ ...d, cards: moveDraftCard(d.cards, index, delta) }));
    setMoved(`Card ${index + 1} is now card ${to + 1} of ${draft.cards.length}.`);
  };

  const save = async () => {
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
    setSaving(true);
    try {
      await onSave(payload);
    } catch (e: unknown) {
      setSaveError(
        isOfflineFailure(e)
          ? 'That did not reach your account — you look offline. Your changes are still here.'
          : (saveRefusal(sqlState(e), sqlDetail(e), e instanceof Error ? e.message : String(e)) ??
              (e instanceof Error ? e.message : 'The set could not be saved.')),
      );
      focusAfter(`${id}-save-error`);
    } finally {
      setSaving(false);
    }
  };

  const leave = (where: 'top' | 'bottom') => {
    if (unsaved && leaving !== where) {
      setLeaving(where);
      return;
    }
    onLeave();
  };

  // Always drawn, above the form and below it, and filled only beside the control that was
  // pressed: a live region added together with its text is not reliably announced.
  const unsavedLine = (where: 'top' | 'bottom') => (
    <p role="status" className={leaving === where ? 'remember__error' : 'sr-only'}>
      {leaving === where && 'Your changes are not saved. Press again to leave without saving them.'}
    </p>
  );

  const room = CARD_LIMIT - draft.cards.filter((c) => c.term.trim() || c.definition.trim()).length;

  return (
    <section className="stack measure flashcards" aria-labelledby={headingId}>
      <div className="flashcards__bar">
        <button type="button" className="btn btn--plain meta" onClick={() => leave('top')}>
          ← {leaveLabel}
        </button>
      </div>
      {unsavedLine('top')}
      <h1 id={headingId} tabIndex={-1}>
        {heading}
      </h1>
      <form
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
            value={draft.title}
            maxLength={TITLE_MAX}
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
            value={draft.description}
            maxLength={DESCRIPTION_MAX}
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
        <ol className="flashcards__rows">
          {draft.cards.map((c, i) => (
            <li key={c.id} className="flashcards__row">
              <p className="meta flashcards__row-number">Card {i + 1}</p>
              <div className="flashcards__row-sides">
                <div className="field">
                  <label className="field__label" htmlFor={`${id}-term-${c.id}`}>
                    Term
                  </label>
                  <textarea
                    id={`${id}-term-${c.id}`}
                    className="field__textarea flashcards__side-input"
                    rows={2}
                    value={c.term}
                    maxLength={TERM_MAX}
                    onChange={(e) => changeCard(c.id, 'term', e.target.value)}
                  />
                </div>
                <div className="field">
                  <label className="field__label" htmlFor={`${id}-definition-${c.id}`}>
                    Definition
                  </label>
                  <textarea
                    id={`${id}-definition-${c.id}`}
                    className="field__textarea flashcards__side-input"
                    rows={2}
                    value={c.definition}
                    maxLength={DEFINITION_MAX}
                    onChange={(e) => changeCard(c.id, 'definition', e.target.value)}
                  />
                </div>
              </div>
              <div className="flashcards__row-actions">
                <button
                  type="button"
                  className="btn btn--plain"
                  aria-label={`Move card ${i + 1} up`}
                  aria-disabled={i === 0}
                  onClick={() => move(i, -1)}
                >
                  Up
                </button>
                <button
                  type="button"
                  className="btn btn--plain"
                  aria-label={`Move card ${i + 1} down`}
                  aria-disabled={i === draft.cards.length - 1}
                  onClick={() => move(i, 1)}
                >
                  Down
                </button>
                <button
                  type="button"
                  className="btn btn--plain"
                  aria-label={`Remove card ${i + 1}`}
                  onClick={() => removeCard(i)}
                >
                  Remove
                </button>
              </div>
            </li>
          ))}
        </ol>
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
                setMoved(`${cardCount(cards.length)} added at the end.`);
                focusAfter(`${id}-add`);
              }}
            />
          </div>
        )}

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
        <div className="flashcards__actions">
          <button
            type="submit"
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
      </form>
    </section>
  );
}
