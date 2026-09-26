/**
 * Cards from text: pasted, or read from a .txt, .csv or .tsv file on this device. The
 * separators are Quizlet's own choices, so a set exported from Quizlet pastes straight in;
 * the preview lists every card and every line that did not make one before anything is
 * taken. Nothing is uploaded: the file is read in the browser.
 */
import { useId, useMemo, useState } from 'react';
import { CARD_LIMIT } from '../lib/flashcards.js';
import {
  guessSeparators,
  parseImport,
  separatorProblem,
  type CardSeparator,
  type ImportedCard,
  type TermSeparator,
} from '../lib/flashcards-import.js';
import { cardCount } from './FlashcardParts.js';

/** A file larger than this is not a list of cards: 2,000 cards of the longest sides is 6 MB. */
const FILE_LIMIT = 8 * 1024 * 1024;

/** How many parsed cards the preview draws; the count above it says how many there are. */
const PREVIEW_ROWS = 200;

export function FlashcardImport({
  limit = CARD_LIMIT,
  takeLabel,
  onTake,
  disabled = false,
  disabledReason,
  busy = false,
  headingLevel = 2,
  primary = true,
}: {
  /** How many cards may still be added: the room left in the set. */
  limit?: number;
  takeLabel: (count: number) => string;
  onTake: (cards: ImportedCard[]) => void;
  disabled?: boolean;
  disabledReason?: string;
  busy?: boolean;
  headingLevel?: 2 | 3;
  /** False inside a form that has its own primary control: one primary button a screen. */
  primary?: boolean;
}) {
  const id = useId();
  const [text, setText] = useState('');
  const [between, setBetween] = useState<TermSeparator['kind']>('tab');
  const [betweenCustom, setBetweenCustom] = useState('');
  const [cardsBy, setCardsBy] = useState<CardSeparator['kind']>('newline');
  const [cardsByCustom, setCardsByCustom] = useState('');
  const [fileNote, setFileNote] = useState<string | null>(null);
  const [fileError, setFileError] = useState<string | null>(null);

  const options = useMemo(
    () => ({
      between:
        between === 'custom'
          ? ({ kind: 'custom', text: betweenCustom } as const)
          : ({ kind: between } as TermSeparator),
      cardsBy:
        cardsBy === 'custom'
          ? ({ kind: 'custom', text: cardsByCustom } as const)
          : ({ kind: cardsBy } as CardSeparator),
      limit,
    }),
    [between, betweenCustom, cardsBy, cardsByCustom, limit],
  );
  const problem = separatorProblem(options);
  const result = useMemo(
    () => (problem || !text.trim() ? null : parseImport(text, options)),
    [problem, text, options],
  );

  const chooseFile = async (file: File) => {
    setFileError(null);
    setFileNote(null);
    if (file.size > FILE_LIMIT) {
      setFileError('That file is larger than 8 MB, which is more than a set can hold.');
      return;
    }
    try {
      const read = await file.text();
      const guess = guessSeparators(file.name, read);
      setBetween(guess.between.kind);
      if (guess.between.kind === 'custom') setBetweenCustom(guess.between.text);
      setCardsBy(guess.cardsBy.kind);
      setText(read);
      setFileNote(`Read ${file.name}. Check the separators below match it.`);
    } catch {
      setFileError('That file could not be read. Is it a text file?');
    }
  };

  const Heading = headingLevel === 2 ? 'h2' : 'h3';
  const count = result?.cards.length ?? 0;

  return (
    <div className="stack flashcards__import">
      <div className="field">
        <label className="field__label" htmlFor={`${id}-text`}>
          Paste your cards
        </label>
        <textarea
          id={`${id}-text`}
          className="field__textarea"
          rows={8}
          value={text}
          onChange={(e) => setText(e.target.value)}
          aria-describedby={`${id}-text-note`}
        />
        <p id={`${id}-text-note`} className="form-note">
          One card a line, with a tab between the term and its definition — what Quizlet’s export
          gives you. Other separators are below.
        </p>
      </div>
      <div className="field">
        <label className="field__label" htmlFor={`${id}-file`}>
          Or open a file
        </label>
        <input
          id={`${id}-file`}
          type="file"
          className="field__input"
          accept=".txt,.csv,.tsv,text/plain,text/csv,text/tab-separated-values"
          onChange={(event) => {
            const selected = event.target.files?.[0];
            event.target.value = '';
            if (selected) void chooseFile(selected);
          }}
        />
        <p className="form-note">
          A .txt, .csv or .tsv file — an Anki text export included. It is read on this device and
          not uploaded; only the cards you save are.
        </p>
        {fileNote && (
          <p className="form-note" role="status">
            {fileNote}
          </p>
        )}
        {fileError && (
          <p className="remember__error" role="alert">
            {fileError}
          </p>
        )}
      </div>

      <fieldset className="flashcards__choice">
        <legend className="field__label">Between term and definition</legend>
        {(
          [
            ['tab', 'Tab'],
            ['comma', 'Comma'],
            ['dash', 'Dash ( - )'],
            ['custom', 'Custom'],
          ] as const
        ).map(([kind, label]) => (
          <label key={kind} className="flashcards__radio">
            <input
              type="radio"
              name={`${id}-between`}
              checked={between === kind}
              onChange={() => setBetween(kind)}
            />{' '}
            {label}
          </label>
        ))}
        {between === 'custom' && (
          <input
            className="field__input flashcards__custom"
            aria-label="The separator between term and definition"
            value={betweenCustom}
            maxLength={20}
            onChange={(e) => setBetweenCustom(e.target.value)}
          />
        )}
      </fieldset>
      <fieldset className="flashcards__choice">
        <legend className="field__label">Between cards</legend>
        {(
          [
            ['newline', 'New line'],
            ['semicolon', 'Semicolon'],
            ['custom', 'Custom'],
          ] as const
        ).map(([kind, label]) => (
          <label key={kind} className="flashcards__radio">
            <input
              type="radio"
              name={`${id}-cards`}
              checked={cardsBy === kind}
              onChange={() => setCardsBy(kind)}
            />{' '}
            {label}
          </label>
        ))}
        {cardsBy === 'custom' && (
          <input
            className="field__input flashcards__custom"
            aria-label="The separator between cards"
            value={cardsByCustom}
            maxLength={20}
            onChange={(e) => setCardsByCustom(e.target.value)}
          />
        )}
      </fieldset>

      <section className="stack flashcards__preview" aria-labelledby={`${id}-preview`}>
        <Heading id={`${id}-preview`} className="flashcards__subheading">
          Preview
        </Heading>
        {/* Always drawn, so what it says is announced as it changes. */}
        <p role="status" className="form-note">
          {problem
            ? problem
            : !result
              ? 'Nothing pasted yet.'
              : `${cardCount(count)} to add` +
                (result.problems.length > 0
                  ? `, and ${result.problems.length} ${result.problems.length === 1 ? 'line that is' : 'lines that are'} not a card.`
                  : '.')}
        </p>
        {result && result.over > 0 && (
          <p className="remember__error">
            {limit === 0
              ? `This set already has ${CARD_LIMIT.toLocaleString()} cards, which is as many as a set holds.`
              : `Only the first ${cardCount(limit)} can be added: a set holds at most ${CARD_LIMIT.toLocaleString()}. ${result.over.toLocaleString()} more were left out.`}
          </p>
        )}
        {result && result.headers > 0 && (
          <p className="form-note">
            {result.headers === 1
              ? 'One header line was skipped.'
              : `${result.headers} header lines were skipped.`}
          </p>
        )}
        {result && result.problems.length > 0 && (
          <>
            <p className="form-note">These lines were not added. Fix them above to include them.</p>
            <ul className="flashcards__problems">
              {result.problems.map((p, i) => (
                <li key={`${p.where}-${i}`}>
                  <span className="meta">{p.where}</span> {p.reason}
                  {p.text && <span className="flashcards__problem-text"> “{p.text}”</span>}
                </li>
              ))}
            </ul>
          </>
        )}
        {count > 0 && (
          <ol className="flashcards__cards">
            {result?.cards.slice(0, PREVIEW_ROWS).map((c, i) => (
              <li key={i} className="flashcards__pair">
                <span className="flashcards__pair-term">{c.term}</span>
                <span className="flashcards__pair-definition">{c.definition}</span>
              </li>
            ))}
          </ol>
        )}
        {count > PREVIEW_ROWS && (
          <p className="form-note">
            And {(count - PREVIEW_ROWS).toLocaleString()} more, all of which will be added.
          </p>
        )}
      </section>

      <div className="flashcards__actions">
        <button
          type="button"
          className={primary ? 'btn btn--primary' : 'btn'}
          aria-disabled={disabled || busy || count === 0}
          aria-describedby={disabled && disabledReason ? `${id}-disabled` : undefined}
          onClick={() => {
            if (disabled || busy || !result || count === 0) return;
            onTake(result.cards);
          }}
        >
          {busy ? 'Saving…' : takeLabel(count)}
        </button>
      </div>
      {disabled && disabledReason && (
        <p id={`${id}-disabled`} className="form-note">
          {disabledReason}
        </p>
      )}
    </div>
  );
}
