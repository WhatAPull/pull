/**
 * What the flashcard screens share: where focus goes after a screen changes, whether there
 * is a connection, the "answer with" choice every mode offers, reading a side aloud, and
 * this browser's storage for the three conveniences kept there.
 *
 * Archive rules (docs/design.md): every control is a real button, radio or link a keyboard
 * reaches, a state is said in words beside any colour, and nothing moves.
 */
import { useCallback, useEffect, useId, useRef, useState } from 'react';
import { usePlayer } from './PlayerProvider.js';
import { type AnswerSide, type FlashcardSet, sideLang } from '../lib/flashcards.js';
import { localVoiceURI, onVoicesChanged } from '../lib/speech.js';

/** How many draws a focus target waits for its element: a few loads' worth. */
const FOCUS_WAIT_DRAWS = 60;

/**
 * FOCUS FOLLOWS THE SCREEN. Most controls here replace the screen they are on -- a mode
 * opens, a card is revealed, a round ends -- and focus on a removed element falls to the
 * top of the page, where a keyboard or screen-reader reader has lost their place. Each such
 * change names the element focus goes to next, and it goes there once that is drawn. The
 * same mechanism `Course.tsx` uses, for the same reason.
 *
 * `then` runs once focus has moved -- or once the element is given up on -- for what should
 * be said after it: a live region written in the same draw as a focus move was written
 * before it, and the heading focus landed on was read over it.
 */
export function useFocusAfter(): (id: string, then?: () => void) => void {
  const next = useRef<{ id: string; draws: number; then?: () => void } | null>(null);
  useEffect(() => {
    const target = next.current;
    if (target === null) return;
    const element = document.getElementById(target.id);
    if (!element) {
      target.draws += 1;
      if (target.draws > FOCUS_WAIT_DRAWS) {
        next.current = null;
        target.then?.();
      }
      return;
    }
    next.current = null;
    element.focus();
    target.then?.();
  });
  return useCallback((id: string, then?: () => void) => {
    next.current = { id, draws: 0, then };
  }, []);
}

/**
 * Whether the browser says there is a network. Trusted only when it says there is not --
 * `true` means an interface is up, not that a request will arrive -- so a screen uses it to
 * say why a control waits, and still handles a failed request on its own.
 */
export function useOnline(): boolean {
  const [online, setOnline] = useState(
    () => typeof navigator === 'undefined' || navigator.onLine !== false,
  );
  useEffect(() => {
    const on = () => setOnline(true);
    const off = () => setOnline(false);
    window.addEventListener('online', on);
    window.addEventListener('offline', off);
    return () => {
      window.removeEventListener('online', on);
      window.removeEventListener('offline', off);
    };
  }, []);
  return online;
}

export const SIDE_LABEL: Record<AnswerSide, string> = { term: 'Term', definition: 'Definition' };

/** "Answer with: Term / Definition", as two radios -- in every mode, and in words. */
export function AnswerWithChoice({
  value,
  onChange,
  note,
}: {
  value: AnswerSide;
  onChange: (side: AnswerSide) => void;
  /** What changing it does, when it does more than change the next question. */
  note?: string;
}) {
  const name = useId();
  return (
    <fieldset className="flashcards__choice">
      <legend className="field__label">Answer with</legend>
      {(['term', 'definition'] as const).map((side) => (
        <label key={side} className="flashcards__radio">
          <input
            type="radio"
            name={name}
            value={side}
            checked={value === side}
            onChange={() => onChange(side)}
          />{' '}
          {SIDE_LABEL[side]}
        </label>
      ))}
      {note && <span className="form-note">{note}</span>}
    </fieldset>
  );
}

/**
 * Reading a side aloud, through the player -- the one place in the app that speaks
 * (`PlayerProvider`) -- as a local-only interlude, as a course lesson is: spoken only by a
 * voice on this device, in the language the set says that side is in, and never stored.
 * A set is the reader's own text, and a remote voice would send it to the browser's vendor.
 *
 * `voiceFor` answers null where there is no such voice, and the screen then offers nothing:
 * a Listen button that says nothing, or reads a Spanish word in an English voice, is worse
 * than none.
 */
export function useListen(set: Pick<FlashcardSet, 'id' | 'title' | 'termLang' | 'definitionLang'>) {
  const player = usePlayer();
  const { dismiss, playNow, supported } = player;
  // Voices arrive after the page does; the answer is read again when they change.
  const [, setVoices] = useState(0);
  useEffect(() => onVoicesChanged(() => setVoices((n) => n + 1)), []);
  const queued = useRef(new Set<string>());

  const voiceFor = (side: AnswerSide): string | null =>
    supported ? localVoiceURI(sideLang(set, side)) : null;

  const listen = (text: string, side: AnswerSide, key: string) => {
    if (!voiceFor(side)) return;
    const id = `flashcards:${set.id}:${key}:${side}`;
    // Anything this screen queued before goes first: an interlude ends on what it
    // interrupted, and that must not be another side of another card.
    for (const other of queued.current) if (other !== id) dismiss(other);
    queued.current = new Set([id]);
    playNow({
      id,
      title: set.title,
      text,
      localOnly: true,
      lang: sideLang(set, side) ?? undefined,
    });
  };

  // Nothing this screen queued outlives it.
  useEffect(
    () => () => {
      for (const id of queued.current) dismiss(id);
    },
    [dismiss],
  );

  return { voiceFor, listen };
}

/** A Listen button for one side, or nothing where no voice on this device can read it. */
export function ListenButton({
  text,
  side,
  cardKey,
  listen,
}: {
  text: string;
  side: AnswerSide;
  cardKey: string;
  listen: ReturnType<typeof useListen>;
}) {
  if (!listen.voiceFor(side)) return null;
  return (
    <button
      type="button"
      className="btn btn--plain"
      // The side, not its words: a definition of 2,000 characters was read out in full each
      // time the button was reached, and the words are on the card beside it.
      aria-label={`Listen to the ${side}`}
      onClick={() => listen.listen(text, side, cardKey)}
    >
      Listen
    </button>
  );
}

/**
 * This browser's storage, for the three things kept there -- a round in progress and a best
 * Match time in `localStorage`, and a set being edited in this tab's `sessionStorage`. All
 * are conveniences for this viewer on this device, under keys by reader and set
 * (`lib/flashcards.ts`): storage can be absent or refuse (a private window, blocked site
 * data, a full quota), and then the screen simply starts afresh, so every access is wrapped
 * rather than trusted.
 */
type Where = 'local' | 'session';

const storage = (where: Where) => (where === 'local' ? window.localStorage : window.sessionStorage);

export function readStored(key: string, where: Where = 'local'): string | null {
  try {
    return storage(where).getItem(key);
  } catch {
    return null;
  }
}

/**
 * A value that cannot be written takes the one before it away rather than leaving it: a draft
 * that no longer fit the quota left the last one that did, and the editor, opened again, gave
 * that back as "your unsaved changes" -- older than what the reader had typed. No value is a
 * fresh start, which every screen already handles; an old one passes for the latest.
 */
export function writeStored(key: string, value: string | null, where: Where = 'local'): void {
  try {
    if (value === null) storage(where).removeItem(key);
    else storage(where).setItem(key, value);
  } catch {
    try {
      storage(where).removeItem(key);
    } catch {
      /* a convenience, never a requirement */
    }
  }
}

/** Whether a key press belongs to a field being typed in, which the modes leave alone. */
export function typingIn(target: EventTarget | null): boolean {
  if (!(target instanceof HTMLElement)) return false;
  return (
    target.isContentEditable ||
    target instanceof HTMLInputElement ||
    target instanceof HTMLTextAreaElement ||
    target instanceof HTMLSelectElement
  );
}

/** A date as the list says it: "3 Sept 2026". */
export function shortDate(iso: string): string {
  const d = new Date(iso);
  return Number.isNaN(d.getTime())
    ? ''
    : d.toLocaleDateString(undefined, { day: 'numeric', month: 'short', year: 'numeric' });
}

/** "1 card", "12 cards". */
export function cardCount(n: number): string {
  return `${n.toLocaleString()} ${n === 1 ? 'card' : 'cards'}`;
}
