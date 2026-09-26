/**
 * Flashcards: a reader's own sets of term/definition cards, and the four ways to study one
 * in a sitting. Pure, so every rule here runs in the node test environment.
 *
 * NOTHING HERE CALLS A MODEL, and nothing needs to (law 2). A distractor is another card's
 * answer from the same set, a true/false statement pairs a prompt with its own answer or
 * another card's, and a typed answer is graded by `gradeCloze` -- the rule the rest of the
 * app already grades typed recall with -- rather than by a new fuzzy one.
 *
 * DETERMINISTIC, SEEDED BY THE SITTING. Every shuffle takes a seed made once when a mode is
 * entered, joined with the card's id where the order is per card. A render must never
 * reshuffle what the reader is looking at: `mcqOptions` in `activities.ts` records what a
 * `Date.now()` per render does to a click. A new sitting -- Shuffle, Retake, Play again --
 * is a new seed, which is the only way an order changes.
 *
 * NOTHING HERE IS RECORDED. What a reader sorts, answers or times in a sitting stays on the
 * page (and, for a round in progress and a best Match time, in this browser's storage). A
 * memory per card, and a queue of what is due across sets, is PR 13.
 */
import { gradeCloze, normaliseAnswer, seededShuffle, semanticMarks } from './activities.js';
import { isRecord, int, nullableStr, rows, str } from './shape.js';

/* --------------------------------------------------------------------------
 * The set
 * -------------------------------------------------------------------------- */

/** The limits `save_flashcard_set` enforces, mirrored so the screens say them first. */
export const TITLE_MAX = 200;
export const DESCRIPTION_MAX = 2000;
export const TERM_MAX = 1000;
export const DEFINITION_MAX = 2000;
/** Cards in one set. */
export const CARD_LIMIT = 2000;
/** Sets one reader keeps. */
export const SET_LIMIT = 500;

export interface Flashcard {
  id: string;
  term: string;
  definition: string;
}

export interface FlashcardSet {
  id: string;
  title: string;
  description: string | null;
  /** The language each side is written in, only to choose a voice. */
  termLang: string | null;
  definitionLang: string | null;
  updatedAt: string;
  /** In the set's order. */
  cards: Flashcard[];
}

/** A set as the list shows it. */
export interface FlashcardSetSummary {
  id: string;
  title: string;
  description: string | null;
  updatedAt: string;
  cardCount: number;
}

/** The side a reader answers with; the other side is the prompt. */
export type AnswerSide = 'term' | 'definition';

export function promptOf(card: Flashcard, answerWith: AnswerSide): string {
  return answerWith === 'definition' ? card.term : card.definition;
}

export function answerOf(card: Flashcard, answerWith: AnswerSide): string {
  return answerWith === 'definition' ? card.definition : card.term;
}

/** The side a side is not. */
export function otherSide(side: AnswerSide): AnswerSide {
  return side === 'term' ? 'definition' : 'term';
}

/** The language a side of this set is written in, when the reader said. */
export function sideLang(
  set: Pick<FlashcardSet, 'termLang' | 'definitionLang'>,
  side: AnswerSide,
): string | null {
  return side === 'term' ? set.termLang : set.definitionLang;
}

/** A language tag's shape, as the table checks it. */
export const LANG_TAG = /^[A-Za-z]{2,3}(-[A-Za-z0-9]{1,8})*$/;

/** The rows of `flashcard_sets` with their embedded card count, as the list reads them. */
export function shapeSetSummaries(data: unknown): FlashcardSetSummary[] {
  return rows(data).flatMap((r) => {
    const id = str(r.id);
    if (!id) return [];
    // `flashcards(count)` arrives as `[{ count: n }]`.
    const counted = rows(r.flashcards)[0];
    return [
      {
        id,
        title: str(r.title),
        description: nullableStr(r.description),
        updatedAt: str(r.updated_at),
        cardCount: counted ? int(counted.count) : 0,
      },
    ];
  });
}

/** One set row and its cards, in position order whatever order they arrived in. */
export function shapeSet(row: unknown, cardRows: unknown): FlashcardSet | null {
  if (!isRecord(row)) return null;
  const id = str(row.id);
  if (!id) return null;
  const cards = rows(cardRows)
    .map((c) => ({
      id: str(c.id),
      term: str(c.term),
      definition: str(c.definition),
      position: int(c.position),
    }))
    .filter((c) => c.id && c.term && c.definition)
    .sort((a, b) => a.position - b.position)
    .map(({ id: cardId, term, definition }) => ({ id: cardId, term, definition }));
  return {
    id,
    title: str(row.title),
    description: nullableStr(row.description),
    termLang: nullableStr(row.term_lang),
    definitionLang: nullableStr(row.definition_lang),
    updatedAt: str(row.updated_at),
    cards,
  };
}

/**
 * A set as it came back from this device's store, which may have been written by an older
 * build: a set missing its cards or a card missing a side is not shown, rather than shown
 * with blanks the modes would ask about.
 */
export function isFlashcardSet(value: unknown): value is FlashcardSet {
  if (!isRecord(value)) return false;
  if (typeof value.id !== 'string' || typeof value.title !== 'string') return false;
  if (typeof value.updatedAt !== 'string' || !Array.isArray(value.cards)) return false;
  return value.cards.every(
    (c: unknown) =>
      isRecord(c) &&
      typeof c.id === 'string' &&
      typeof c.term === 'string' &&
      typeof c.definition === 'string',
  );
}

/** A set's summary, from the set itself: what the list shows of a copy on this device. */
export function summaryOf(set: FlashcardSet): FlashcardSetSummary {
  return {
    id: set.id,
    title: set.title,
    description: set.description,
    updatedAt: set.updatedAt,
    cardCount: set.cards.length,
  };
}

/* --------------------------------------------------------------------------
 * Answers that are the same answer
 * -------------------------------------------------------------------------- */

/**
 * What two answers are compared by: the letters as `normaliseAnswer` folds them, and the
 * marks `semanticMarks` keeps, as `gradeCloze` compares them. Two answers with the same key
 * are one answer to a reader typing it, so they are one option, never two.
 *
 * An answer that normalises to nothing -- `?`, `…` -- keeps its own text, or every such
 * answer in a set would be taken for the same one.
 */
export function answerKey(text: string): string {
  const letters = normaliseAnswer(text);
  return letters ? `${letters}|${semanticMarks(text)}` : `raw|${text.trim()}`;
}

/**
 * The other cards' answers to offer beside this one's: from the set itself, in set order,
 * each once, and never one a reader would take for the right answer.
 */
export function otherAnswers(
  cards: readonly Flashcard[],
  card: Flashcard,
  answerWith: AnswerSide,
): string[] {
  const seen = new Set([answerKey(answerOf(card, answerWith))]);
  const out: string[] = [];
  for (const other of cards) {
    if (other.id === card.id) continue;
    const text = answerOf(other, answerWith);
    const key = answerKey(text);
    if (seen.has(key)) continue;
    seen.add(key);
    out.push(text);
  }
  return out;
}

/** Up to `count` distractors, chosen by the seed from the other cards' answers. */
export function distractors(
  cards: readonly Flashcard[],
  card: Flashcard,
  answerWith: AnswerSide,
  count: number,
  seed: string,
): string[] {
  return seededShuffle(otherAnswers(cards, card, answerWith), seed).slice(0, Math.max(0, count));
}

/** How many choices a multiple-choice question offers at most: the answer and three more. */
export const CHOICES = 4;

/**
 * The options for a multiple-choice question on this card: its answer and up to three
 * distractors, in an order the seed fixes. Fewer in a small set -- two cards make a choice
 * of two -- and none when there is nothing to choose between, which a caller asks as a
 * written question instead: one option is not a choice.
 */
export function choiceOptions(
  cards: readonly Flashcard[],
  card: Flashcard,
  answerWith: AnswerSide,
  seed: string,
): string[] {
  const wrong = distractors(cards, card, answerWith, CHOICES - 1, `${seed}:distractors`);
  if (wrong.length === 0) return [];
  return seededShuffle([answerOf(card, answerWith), ...wrong], `${seed}:order`);
}

/** Whether a typed answer is this card's answer: exact, or close by `gradeCloze`'s rule. */
export function writtenCorrect(typed: string, answer: string): boolean {
  return gradeCloze(typed, answer).correct;
}

/* --------------------------------------------------------------------------
 * Flashcards: one card at a time, sorted by the reader
 * -------------------------------------------------------------------------- */

/**
 * A round of cards: the order it goes in, where the reader is, and which cards they said
 * they know. `index === order.length` is the end of the round.
 *
 * A card passed with Next rather than sorted counts as still learning at the end: the
 * reader did not say they knew it, and "Study the ones still learning" should not leave it
 * out.
 */
export interface CardsRound {
  order: readonly string[];
  index: number;
  known: readonly string[];
}

/** A round over these cards, in the set's order or -- with a seed -- shuffled by it. */
export function startCardsRound(cardIds: readonly string[], seed: string | null): CardsRound {
  return {
    order: seed === null ? [...cardIds] : seededShuffle(cardIds, seed),
    index: 0,
    known: [],
  };
}

/** Previous and Next. Past the last card is the end of the round; before the first is not. */
export function stepRound(round: CardsRound, delta: number): CardsRound {
  const index = Math.min(round.order.length, Math.max(0, round.index + delta));
  return index === round.index ? round : { ...round, index };
}

/** The card on screen, sorted as known or still learning, and the next one shown. */
export function sortCard(round: CardsRound, verdict: 'known' | 'learning'): CardsRound {
  const id = round.order[round.index];
  if (id === undefined) return round;
  const known =
    verdict === 'known'
      ? round.known.includes(id)
        ? round.known
        : [...round.known, id]
      : round.known.filter((k) => k !== id);
  return { ...round, known, index: round.index + 1 };
}

export function roundOver(round: CardsRound): boolean {
  return round.index >= round.order.length;
}

/** The round's cards the reader did not say they know, in the round's order. */
export function stillLearning(round: CardsRound): string[] {
  return round.order.filter((id) => !round.known.includes(id));
}

/** The same cards in a new order, from the first, keeping what the reader sorted. */
export function shuffleRound(round: CardsRound, seed: string): CardsRound {
  return { order: seededShuffle(round.order, seed), index: 0, known: round.known };
}

/**
 * A round kept in this browser's storage, read back against the set as it is now.
 *
 * The set may have changed since -- a card deleted, one added -- so a kept id the set no
 * longer has is dropped, and the place is moved back by the cards dropped before it. A
 * round with nothing left in it is no round: the caller starts afresh. Anything that is
 * not the shape this build writes is also none, since it was written by some other one.
 */
export function restoreRound(saved: unknown, cardIds: readonly string[]): CardsRound | null {
  if (!isRecord(saved) || !Array.isArray(saved.order) || !Array.isArray(saved.known)) return null;
  if (typeof saved.index !== 'number' || !Number.isInteger(saved.index)) return null;
  const present = new Set(cardIds);
  const kept = saved.order.filter((id): id is string => typeof id === 'string' && present.has(id));
  const order = [...new Set(kept)];
  if (order.length === 0) return null;
  const before = saved.order
    .slice(0, Math.max(0, saved.index))
    .filter((id: unknown) => typeof id === 'string' && present.has(id)).length;
  const known = saved.known.filter(
    (id): id is string => typeof id === 'string' && order.includes(id),
  );
  return { order, index: Math.min(order.length, before), known: [...new Set(known)] };
}

/* --------------------------------------------------------------------------
 * Learn: multiple choice, then written, until each card is mastered
 * -------------------------------------------------------------------------- */

/** How many cards a round of Learn asks about. */
export const LEARN_ROUND = 7;

/**
 * Where a card is in Learn. It is asked as multiple choice until answered right, then as a
 * written question until answered right, and is then mastered. A wrong answer at either
 * stage sends it back to multiple choice, to be asked again in a later round.
 */
export type LearnStage = 'choice' | 'written' | 'mastered';

export interface LearnAnswered {
  cardId: string;
  /** The stage the question was asked at. */
  asked: Exclude<LearnStage, 'mastered'>;
  correct: boolean;
  /** What the reader chose or typed. */
  response: string;
  /** Counted right on the reader's word, after a written answer was marked wrong. */
  overridden: boolean;
}

export interface LearnState {
  seed: string;
  answerWith: AnswerSide;
  /** Every card being learnt, in the order the seed gave them. */
  order: readonly string[];
  stages: Readonly<Record<string, LearnStage>>;
  /** Cards with nothing to choose between: asked in writing from the start, and after a miss. */
  writtenOnly: readonly string[];
  round: readonly string[];
  roundNo: number;
  /** The question in the round being asked; `round.length` once the round is over. */
  position: number;
  /** The answer just given, shown until the reader goes on. */
  answered: LearnAnswered | null;
}

/**
 * The next round: the first cards in the sitting's order that are not mastered. A card
 * still being learnt keeps its place in the next round, and one mastered makes room for the
 * next card of the set -- so a round is never all new cards, and never the same seven
 * forever once they are learnt.
 */
function planRound(order: readonly string[], stages: Readonly<Record<string, LearnStage>>) {
  return order.filter((id) => stages[id] !== 'mastered').slice(0, LEARN_ROUND);
}

/** Learn over these cards of the set -- all of them, or the ones a test missed. */
export function startLearn(
  cards: readonly Flashcard[],
  cardIds: readonly string[],
  answerWith: AnswerSide,
  seed: string,
): LearnState {
  const byId = new Map(cards.map((c) => [c.id, c]));
  const ids = [...new Set(cardIds)].filter((id) => byId.has(id));
  const order = seededShuffle(ids, seed);
  const writtenOnly = order.filter(
    (id) => otherAnswers(cards, byId.get(id) as Flashcard, answerWith).length === 0,
  );
  const stages: Record<string, LearnStage> = {};
  for (const id of order) stages[id] = writtenOnly.includes(id) ? 'written' : 'choice';
  return {
    seed,
    answerWith,
    order,
    stages,
    writtenOnly,
    round: planRound(order, stages),
    roundNo: 1,
    position: 0,
    answered: null,
  };
}

export type LearnQuestion =
  | { kind: 'choice'; card: Flashcard; prompt: string; answer: string; options: string[] }
  | { kind: 'written'; card: Flashcard; prompt: string; answer: string };

/** The question being asked, or null between rounds and at the end. */
export function learnQuestion(
  state: LearnState,
  cards: readonly Flashcard[],
): LearnQuestion | null {
  const id = state.round[state.position];
  const card = id === undefined ? undefined : cards.find((c) => c.id === id);
  if (!card) return null;
  const prompt = promptOf(card, state.answerWith);
  const answer = answerOf(card, state.answerWith);
  // The seed carries the round, so a card asked again is not answered by where its option was.
  const asked = state.answered?.cardId === card.id ? state.answered.asked : state.stages[card.id];
  if (asked === 'choice') {
    const options = choiceOptions(
      cards,
      card,
      state.answerWith,
      `${state.seed}:${state.roundNo}:${card.id}`,
    );
    if (options.length > 0) return { kind: 'choice', card, prompt, answer, options };
  }
  return { kind: 'written', card, prompt, answer };
}

function advanced(state: LearnState, cardId: string, from: LearnStage, correct: boolean) {
  if (correct) return from === 'choice' ? 'written' : 'mastered';
  return state.writtenOnly.includes(cardId) ? 'written' : 'choice';
}

/** The reader's answer to the question on screen, right or wrong. */
export function answerLearn(state: LearnState, correct: boolean, response: string): LearnState {
  const cardId = state.round[state.position];
  if (cardId === undefined || state.answered) return state;
  const asked = state.stages[cardId];
  if (asked === undefined || asked === 'mastered') return state;
  return {
    ...state,
    stages: { ...state.stages, [cardId]: advanced(state, cardId, asked, correct) },
    answered: { cardId, asked, correct, response, overridden: false },
  };
}

/**
 * "I was right": a written answer marked wrong, counted right on the reader's judgement.
 * Only for a written answer -- a choice was either the answer or not -- and only once.
 * Nothing is recorded, so the reader's word costs nobody anything but the reader.
 */
export function claimRight(state: LearnState): LearnState {
  const a = state.answered;
  if (!a || a.correct || a.asked !== 'written') return state;
  return {
    ...state,
    stages: { ...state.stages, [a.cardId]: 'mastered' },
    answered: { ...a, correct: true, overridden: true },
  };
}

/** On from the answer just given: the next question, or the end of the round. */
export function continueLearn(state: LearnState): LearnState {
  if (!state.answered) return state;
  return { ...state, answered: null, position: state.position + 1 };
}

export function learnRoundOver(state: LearnState): boolean {
  return state.answered === null && state.position >= state.round.length;
}

export function learnProgress(state: LearnState): { mastered: number; total: number } {
  return {
    mastered: state.order.filter((id) => state.stages[id] === 'mastered').length,
    total: state.order.length,
  };
}

export function learnDone(state: LearnState): boolean {
  const { mastered, total } = learnProgress(state);
  return total > 0 && mastered === total && state.answered === null;
}

/** The next round, once one is over. */
export function nextLearnRound(state: LearnState): LearnState {
  if (!learnRoundOver(state)) return state;
  return {
    ...state,
    round: planRound(state.order, state.stages),
    roundNo: state.roundNo + 1,
    position: 0,
  };
}

/* --------------------------------------------------------------------------
 * Test: a page of questions, graded at once
 * -------------------------------------------------------------------------- */

export type TestKind = 'true_false' | 'choice' | 'written';

/** The order a test's sections come in, and the order kinds are dealt in. */
export const TEST_KINDS: readonly TestKind[] = ['true_false', 'choice', 'written'];

export interface TestOptions {
  count: number;
  kinds: readonly TestKind[];
  answerWith: AnswerSide;
}

/** Twenty questions, or every card of a smaller set. */
export function defaultTestCount(cardCount: number): number {
  return Math.min(20, cardCount);
}

export type TestQuestion =
  | {
      kind: 'true_false';
      cardId: string;
      prompt: string;
      answer: string;
      /** What the statement pairs the prompt with: its own answer, or another card's. */
      shown: string;
      /** Whether `shown` is the prompt's own answer. */
      truth: boolean;
    }
  | { kind: 'choice'; cardId: string; prompt: string; answer: string; options: string[] }
  | { kind: 'written'; cardId: string; prompt: string; answer: string };

/**
 * A test over `count` cards the seed picks, the kinds dealt out in turn among the cards so
 * each chosen kind gets its share, then gathered into one section per kind.
 *
 * A card that cannot be asked as the kind it was dealt -- a multiple choice or a true/false
 * with no other answer in the set to offer -- is asked in writing instead, which every card
 * can be. A true/false is true or false by the seed, about half and half.
 */
export function buildTest(
  cards: readonly Flashcard[],
  options: TestOptions,
  seed: string,
): TestQuestion[] {
  const kinds = TEST_KINDS.filter((k) => options.kinds.includes(k));
  if (kinds.length === 0 || cards.length === 0) return [];
  const count = Math.min(cards.length, Math.max(1, Math.floor(options.count)));
  const picked = seededShuffle(cards, `${seed}:cards`).slice(0, count);
  const { answerWith } = options;
  const questions = picked.map((card, i): TestQuestion => {
    const prompt = promptOf(card, answerWith);
    const answer = answerOf(card, answerWith);
    const dealt = kinds[i % kinds.length] as TestKind;
    const cardSeed = `${seed}:${card.id}`;
    if (dealt === 'choice') {
      const opts = choiceOptions(cards, card, answerWith, cardSeed);
      if (opts.length > 0)
        return { kind: 'choice', cardId: card.id, prompt, answer, options: opts };
    }
    if (dealt === 'true_false') {
      const [other] = distractors(cards, card, answerWith, 1, `${cardSeed}:false`);
      if (other !== undefined) {
        const truth = seededShuffle([true, false], `${cardSeed}:truth`)[0] as boolean;
        return {
          kind: 'true_false',
          cardId: card.id,
          prompt,
          answer,
          shown: truth ? answer : other,
          truth,
        };
      }
    }
    return { kind: 'written', cardId: card.id, prompt, answer };
  });
  // One section per kind, in a fixed order, keeping the dealt order within each.
  return TEST_KINDS.flatMap((k) => questions.filter((q) => q.kind === k));
}

/** A reader's answer to one question: true or false, the option chosen, or what they typed. */
export type TestResponse = boolean | string | null;

export interface TestResult {
  score: number;
  total: number;
  correct: boolean[];
  /** The cards of the questions missed, once each, for "Learn the ones you missed". */
  missed: string[];
}

/** Every question graded at once. An unanswered question is a wrong one. */
export function gradeTest(
  questions: readonly TestQuestion[],
  responses: readonly TestResponse[],
): TestResult {
  const correct = questions.map((q, i) => {
    const r = responses[i] ?? null;
    switch (q.kind) {
      case 'true_false':
        return typeof r === 'boolean' && r === q.truth;
      case 'choice':
        return typeof r === 'string' && r === q.answer;
      case 'written':
        return typeof r === 'string' && r.trim() !== '' && writtenCorrect(r, q.answer);
    }
  });
  const missed = [...new Set(questions.filter((_, i) => !correct[i]).map((q) => q.cardId))];
  return { score: correct.filter(Boolean).length, total: questions.length, correct, missed };
}

/* --------------------------------------------------------------------------
 * Match: pair every term with its definition, against the clock
 * -------------------------------------------------------------------------- */

/** How many cards a game of Match lays out: twelve tiles. */
export const MATCH_CARDS = 6;

export interface MatchTile {
  /** `${cardId}:term` or `${cardId}:definition`. */
  id: string;
  cardId: string;
  side: AnswerSide;
  text: string;
}

export type MatchEvent =
  | { kind: 'selected'; tileId: string }
  | { kind: 'deselected'; tileId: string }
  | { kind: 'pair'; cardId: string }
  | { kind: 'miss'; tileIds: [string, string] };

export interface MatchState {
  tiles: readonly MatchTile[];
  /** Cards whose two tiles have been paired. */
  cleared: readonly string[];
  selected: string | null;
  /** When the first tile was chosen, in the caller's clock; null before. */
  startedAt: number | null;
  /** When the last pair cleared. */
  finishedAt: number | null;
  last: MatchEvent | null;
}

/**
 * The cards a game uses: up to six, picked by the seed, and never two whose tiles would
 * read the same. Twelve tiles where two say "to be" is a game a reader cannot win by
 * knowing the set, since the right tile and the wrong one look alike.
 */
export function matchCards(cards: readonly Flashcard[], seed: string): Flashcard[] {
  const seen = new Set<string>();
  const out: Flashcard[] = [];
  for (const card of seededShuffle(cards, `${seed}:cards`)) {
    const keys = [answerKey(card.term), answerKey(card.definition)];
    if (keys[0] === keys[1] || keys.some((k) => seen.has(k))) continue;
    keys.forEach((k) => seen.add(k));
    out.push(card);
    if (out.length === MATCH_CARDS) break;
  }
  return out;
}

/** A new game, or null when the set has fewer than two cards to pair. */
export function startMatch(cards: readonly Flashcard[], seed: string): MatchState | null {
  const chosen = matchCards(cards, seed);
  if (chosen.length < 2) return null;
  const tiles = chosen.flatMap((c): MatchTile[] => [
    { id: `${c.id}:term`, cardId: c.id, side: 'term', text: c.term },
    { id: `${c.id}:definition`, cardId: c.id, side: 'definition', text: c.definition },
  ]);
  return {
    tiles: seededShuffle(tiles, `${seed}:tiles`),
    cleared: [],
    selected: null,
    startedAt: null,
    finishedAt: null,
    last: null,
  };
}

export function matchDone(state: MatchState): boolean {
  return state.finishedAt !== null;
}

/**
 * A tile chosen. The first choice starts the clock and is held; the same tile again lets it
 * go; a second tile either clears the pair -- a card's term and its definition -- or is not
 * a pair, and either way nothing is held after it. A cleared tile, or any tile once the
 * game is over, does nothing.
 */
export function selectTile(state: MatchState, tileId: string, now: number): MatchState {
  if (state.finishedAt !== null) return state;
  const tile = state.tiles.find((t) => t.id === tileId);
  if (!tile || state.cleared.includes(tile.cardId)) return state;
  const startedAt = state.startedAt ?? now;
  if (state.selected === null) {
    return { ...state, startedAt, selected: tileId, last: { kind: 'selected', tileId } };
  }
  if (state.selected === tileId) {
    return { ...state, startedAt, selected: null, last: { kind: 'deselected', tileId } };
  }
  const held = state.tiles.find((t) => t.id === state.selected);
  if (held && held.cardId === tile.cardId && held.side !== tile.side) {
    const cleared = [...state.cleared, tile.cardId];
    const cards = new Set(state.tiles.map((t) => t.cardId)).size;
    return {
      ...state,
      startedAt,
      cleared,
      selected: null,
      finishedAt: cleared.length === cards ? now : null,
      last: { kind: 'pair', cardId: tile.cardId },
    };
  }
  return {
    ...state,
    startedAt,
    selected: null,
    last: { kind: 'miss', tileIds: [state.selected, tileId] },
  };
}

/** Tenths of a second on the clock: stopped at the last pair, counting before it. */
export function elapsedTenths(state: MatchState, now: number): number {
  if (state.startedAt === null) return 0;
  const end = state.finishedAt ?? now;
  return Math.max(0, Math.floor((end - state.startedAt) / 100));
}

/** `234` as "23.4 s". */
export function formatTenths(tenths: number): string {
  const t = Math.max(0, Math.floor(tenths));
  return `${Math.floor(t / 10)}.${t % 10} s`;
}

/** A best time kept in this browser: a positive whole number of tenths, or none. */
export function readBestTime(raw: string | null): number | null {
  if (raw === null) return null;
  const n = Number(raw);
  return Number.isInteger(n) && n > 0 ? n : null;
}

/** Whether a finished time beats the best one kept. */
export function beatsBest(tenths: number, best: number | null): boolean {
  return tenths > 0 && (best === null || tenths < best);
}

/* --------------------------------------------------------------------------
 * Editing a set
 * -------------------------------------------------------------------------- */

/**
 * A card as the editor holds it. The id is minted when the row is made -- not when the set
 * is saved -- so it is the row's React key from the start and the id the card is saved
 * under, and a save retried after a lost response names the same cards again.
 */
export interface DraftCard {
  id: string;
  term: string;
  definition: string;
}

export interface SetDraft {
  id: string;
  title: string;
  description: string;
  termLang: string;
  definitionLang: string;
  cards: DraftCard[];
}

/** A set, as the editor starts from it. */
export function draftOf(set: FlashcardSet): SetDraft {
  return {
    id: set.id,
    title: set.title,
    description: set.description ?? '',
    termLang: set.termLang ?? '',
    definitionLang: set.definitionLang ?? '',
    cards: set.cards.map((c) => ({ ...c })),
  };
}

/** A new set: a few empty rows to type into, each with its own id. */
export function newDraft(id: string, mint: () => string, rowsToStart = 3): SetDraft {
  return {
    id,
    title: '',
    description: '',
    termLang: '',
    definitionLang: '',
    cards: Array.from({ length: rowsToStart }, () => ({ id: mint(), term: '', definition: '' })),
  };
}

/** A row moved one place up (-1) or down (+1); unchanged at either end. */
export function moveDraftCard(cards: readonly DraftCard[], index: number, delta: -1 | 1) {
  const to = index + delta;
  if (index < 0 || index >= cards.length || to < 0 || to >= cards.length) return [...cards];
  const out = [...cards];
  const [card] = out.splice(index, 1);
  out.splice(to, 0, card as DraftCard);
  return out;
}

/** What `save_flashcard_set` takes. */
export interface SavePayload {
  id: string;
  title: string;
  description: string | null;
  termLang: string | null;
  definitionLang: string | null;
  cards: { id: string; term: string; definition: string }[];
}

/**
 * The draft as a save, or what is wrong with it, in words and by row.
 *
 * A row with nothing in either box is an unused row and is left out, which is what an
 * editor that starts with empty rows needs. A row with one side typed is a card half
 * made, and is said rather than dropped: losing a term the reader typed because they had
 * not got to its definition yet would be the editor deciding for them.
 */
export function validateDraft(draft: SetDraft): {
  payload: SavePayload | null;
  problems: string[];
} {
  const problems: string[] = [];
  const title = draft.title.trim();
  if (!title) problems.push('Give the set a title.');
  else if (title.length > TITLE_MAX) problems.push(`A title is at most ${TITLE_MAX} characters.`);
  const description = draft.description.trim();
  if (description.length > DESCRIPTION_MAX) {
    problems.push(`A description is at most ${DESCRIPTION_MAX.toLocaleString('en')} characters.`);
  }
  for (const [label, value] of [
    ['term', draft.termLang],
    ['definition', draft.definitionLang],
  ] as const) {
    const tag = value.trim();
    if (tag && (!LANG_TAG.test(tag) || tag.length > 35)) {
      problems.push(`The ${label} language should be a language code, such as “fr” or “pt-BR”.`);
    }
  }
  const cards: SavePayload['cards'] = [];
  draft.cards.forEach((c, i) => {
    const term = c.term.trim();
    const definition = c.definition.trim();
    if (!term && !definition) return;
    const n = i + 1;
    if (!term) problems.push(`Card ${n} needs a term.`);
    else if (term.length > TERM_MAX) {
      problems.push(`Card ${n}’s term is over ${TERM_MAX.toLocaleString('en')} characters.`);
    }
    if (!definition) problems.push(`Card ${n} needs a definition.`);
    else if (definition.length > DEFINITION_MAX) {
      problems.push(
        `Card ${n}’s definition is over ${DEFINITION_MAX.toLocaleString('en')} characters.`,
      );
    }
    cards.push({ id: c.id, term, definition });
  });
  if (cards.length === 0) problems.push('Add at least one card.');
  if (cards.length > CARD_LIMIT) {
    problems.push(`A set holds at most ${CARD_LIMIT.toLocaleString('en')} cards.`);
  }
  if (problems.length > 0) return { payload: null, problems };
  return {
    payload: {
      id: draft.id,
      title,
      description: description || null,
      termLang: draft.termLang.trim() || null,
      definitionLang: draft.definitionLang.trim() || null,
      cards,
    },
    problems,
  };
}

/**
 * Whether the draft says something the saved set does not -- what "leave without saving?"
 * asks about. Compared as a save would store it, so trailing spaces and an untouched empty
 * row are not changes; a new set is unsaved once anything at all is typed.
 */
export function draftUnsaved(draft: SetDraft, saved: FlashcardSet | null): boolean {
  const kept = (cards: readonly DraftCard[]) =>
    cards
      .map((c) => ({ id: c.id, term: c.term.trim(), definition: c.definition.trim() }))
      .filter((c) => c.term || c.definition);
  const mine = kept(draft.cards);
  if (!saved) {
    return (
      mine.length > 0 ||
      [draft.title, draft.description, draft.termLang, draft.definitionLang].some((v) => v.trim())
    );
  }
  if (
    draft.title.trim() !== saved.title ||
    (draft.description.trim() || null) !== saved.description ||
    (draft.termLang.trim() || null) !== saved.termLang ||
    (draft.definitionLang.trim() || null) !== saved.definitionLang ||
    mine.length !== saved.cards.length
  ) {
    return true;
  }
  return mine.some((c, i) => {
    const s = saved.cards[i];
    return !s || s.id !== c.id || s.term !== c.term || s.definition !== c.definition;
  });
}

/* --------------------------------------------------------------------------
 * What a refusal means
 * -------------------------------------------------------------------------- */

/** "card 3's term is 1 to 1000 characters" as a sentence a reader can read. */
function asSentence(message: string): string {
  const text = message.trim();
  if (!text) return '';
  const first = text.charAt(0).toUpperCase() + text.slice(1).replace(/'/g, '’');
  return /[.!?]$/.test(first) ? first : `${first}.`;
}

/**
 * A refusal of `save_flashcard_set` in words, from its SQLSTATE and DETAIL; null for one it
 * does not know, which the screen says as it came. The database's own message is kept for
 * malformed input, because it names the card: the editor checks the same rules first, so
 * reaching this means the two disagree, and the card's number is what helps.
 */
export function saveRefusal(
  code: string | undefined,
  detail: string | undefined,
  message: string,
): string | null {
  switch (code) {
    case '28000':
      return 'You are signed out. Sign in again to save this set.';
    case '42501':
      return detail === 'guest'
        ? 'A guest session cannot keep flashcard sets, because it ends with the tab. Sign in to make one.'
        : null;
    case '54000':
      if (detail === 'sets') {
        return `You have ${SET_LIMIT} sets, which is as many as an account keeps. Delete one you are done with to make another.`;
      }
      if (detail === 'cards') {
        return `A set holds at most ${CARD_LIMIT.toLocaleString('en')} cards. Split this one into two.`;
      }
      return null;
    case '22023':
      return `The set could not be saved as it is. ${asSentence(message)}`;
    case 'P0002':
      return 'This set could not be found.';
    default:
      return null;
  }
}
