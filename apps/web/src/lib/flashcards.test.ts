import { describe, expect, it } from 'vitest';
import {
  CARD_LIMIT,
  CHOICES,
  LEARN_ROUND,
  MATCH_CARDS,
  SET_BYTES_LIMIT,
  acceptedAnswers,
  answerKey,
  answerLearn,
  answerOf,
  beatsBest,
  bestTimeKey,
  buildTest,
  canMatch,
  charCount,
  choiceOptions,
  claimRight,
  continueLearn,
  defaultTestCount,
  distractors,
  draftKey,
  draftOf,
  draftUnsaved,
  elapsedTenths,
  formatTenths,
  gradeTest,
  isFlashcardSet,
  isReadersFlashcardKey,
  learnCorrect,
  learnDone,
  learnProgress,
  learnQuestion,
  learnRoundOver,
  matchCards,
  matchDone,
  moveDraftCard,
  newDraft,
  nextLearnRound,
  otherAnswers,
  promptOf,
  readBestTime,
  readKeptDraft,
  restoreRound,
  roundKey,
  roundOver,
  saveConflict,
  saveRefusal,
  selectTile,
  shapeSet,
  shapeSetSummaries,
  shuffleRound,
  sortCard,
  startCardsRound,
  startLearn,
  startMatch,
  stepRound,
  stillLearning,
  utf8Length,
  validateDraft,
  writtenCorrect,
  type Flashcard,
  type FlashcardSet,
  type LearnState,
  type MatchState,
  type TestQuestion,
} from './flashcards.js';

const card = (id: string, term: string, definition: string): Flashcard => ({
  id,
  term,
  definition,
});

const VERBS: Flashcard[] = [
  card('c1', 'ser', 'to be (lasting)'),
  card('c2', 'estar', 'to be (for now)'),
  card('c3', 'ir', 'to go'),
  card('c4', 'tener', 'to have'),
  card('c5', 'hacer', 'to do, to make'),
  card('c6', 'poder', 'to be able to'),
  card('c7', 'decir', 'to say'),
  card('c8', 'ver', 'to see'),
  card('c9', 'dar', 'to give'),
  card('c10', 'saber', 'to know (a fact)'),
];

const set = (cards: Flashcard[] = VERBS): FlashcardSet => ({
  id: 's1',
  title: 'Spanish verbs',
  description: null,
  termLang: 'es',
  definitionLang: 'en',
  updatedAt: '2026-09-26T10:00:00Z',
  cards,
});

describe('the two sides of a card', () => {
  it('prompts with the side the reader does not answer with', () => {
    const c = VERBS[0] as Flashcard;
    expect(promptOf(c, 'definition')).toBe('ser');
    expect(answerOf(c, 'definition')).toBe('to be (lasting)');
    expect(promptOf(c, 'term')).toBe('to be (lasting)');
    expect(answerOf(c, 'term')).toBe('ser');
  });
});

describe('shaping what the API returns', () => {
  it('reads the embedded count and skips a row with no id', () => {
    expect(
      shapeSetSummaries([
        {
          id: 's1',
          title: 'Verbs',
          description: null,
          updated_at: 't',
          flashcards: [{ count: 12 }],
        },
        { title: 'no id' },
        { id: 's2', title: 'Empty', description: 'd', updated_at: 't2', flashcards: [] },
      ]),
    ).toEqual([
      { id: 's1', title: 'Verbs', description: null, updatedAt: 't', cardCount: 12 },
      { id: 's2', title: 'Empty', description: 'd', updatedAt: 't2', cardCount: 0 },
    ]);
  });

  it('puts cards in position order whatever order the pages came in', () => {
    const shaped = shapeSet(
      {
        id: 's1',
        title: 'T',
        description: null,
        term_lang: 'es',
        definition_lang: null,
        updated_at: 't',
      },
      [
        { id: 'b', term: 'B', definition: 'b', position: 1 },
        { id: 'a', term: 'A', definition: 'a', position: 0 },
        { id: 'x', term: '', definition: 'no term', position: 2 },
      ],
    );
    expect(shaped?.cards.map((c) => c.id)).toEqual(['a', 'b']);
    expect(shaped?.termLang).toBe('es');
    expect(shapeSet(null, [])).toBeNull();
  });

  it('knows a set this device stored from one an older build left in another shape', () => {
    expect(isFlashcardSet(set())).toBe(true);
    expect(isFlashcardSet({ ...set(), cards: [{ id: 'c', term: 't' }] })).toBe(false);
    expect(isFlashcardSet({ id: 's', title: 't' })).toBe(false);
    expect(isFlashcardSet(null)).toBe(false);
  });
});

describe('distractors', () => {
  it('come from the other cards’ answers, never the card’s own', () => {
    const c = VERBS[2] as Flashcard;
    const others = otherAnswers(VERBS, c, 'definition');
    expect(others).not.toContain('to go');
    expect(others).toHaveLength(VERBS.length - 1);
    expect(others[0]).toBe('to be (lasting)');
  });

  it('drop an answer a reader would take for the right one, and duplicates of each other', () => {
    const cards = [
      card('a', 'colour', 'the Centre'),
      card('b', 'color', 'the center'),
      card('c', 'hue', 'a shade'),
      card('d', 'tint', 'A shade.'),
      card('e', 'Na+', 'sodium ion'),
      card('f', 'Na-', 'not a thing'),
    ];
    // "the center" is "the Centre" to a reader typing it, so it is not a wrong option.
    expect(otherAnswers(cards, cards[0] as Flashcard, 'definition')).toEqual([
      'a shade',
      'sodium ion',
      'not a thing',
    ]);
    // Marks are part of an answer: Na- is a distractor for Na+, not the same answer.
    expect(otherAnswers(cards, cards[4] as Flashcard, 'term')).toContain('Na-');
    expect(answerKey('the Centre')).toBe(answerKey('the center'));
    expect(answerKey('?')).not.toBe(answerKey('…'));
  });

  it('are chosen by the seed, the same way every time', () => {
    const c = VERBS[0] as Flashcard;
    const a = distractors(VERBS, c, 'definition', 3, 'sitting-1:c1');
    expect(a).toHaveLength(3);
    expect(distractors(VERBS, c, 'definition', 3, 'sitting-1:c1')).toEqual(a);
    const seeds = ['s2', 's3', 's4', 's5', 's6'].map((s) =>
      distractors(VERBS, c, 'definition', 3, s).join('|'),
    );
    expect(new Set([a.join('|'), ...seeds]).size).toBeGreaterThan(1);
  });

  it('make four options at most, fewer in a small set, and none with nothing to choose', () => {
    const options = choiceOptions(VERBS, VERBS[0] as Flashcard, 'definition', 'seed');
    expect(options).toHaveLength(CHOICES);
    expect(options).toContain('to be (lasting)');
    expect(new Set(options).size).toBe(CHOICES);
    expect(choiceOptions(VERBS, VERBS[0] as Flashcard, 'definition', 'seed')).toEqual(options);

    const two = VERBS.slice(0, 2);
    expect(choiceOptions(two, two[0] as Flashcard, 'definition', 'seed')).toHaveLength(2);
    const three = VERBS.slice(0, 3);
    expect(choiceOptions(three, three[0] as Flashcard, 'definition', 'seed')).toHaveLength(3);
    expect(choiceOptions(VERBS.slice(0, 1), VERBS[0] as Flashcard, 'definition', 'seed')).toEqual(
      [],
    );
    // Two cards with one answer between them are nothing to choose between.
    const same = [card('a', 'x', 'the same'), card('b', 'y', 'The same.')];
    expect(choiceOptions(same, same[0] as Flashcard, 'definition', 'seed')).toEqual([]);
  });

  it('puts the answer in more than one place across cards, so where it is says nothing', () => {
    const places = VERBS.map((c) => choiceOptions(VERBS, c, 'definition', `seed:${c.id}`)).map(
      (opts, i) => opts.indexOf(answerOf(VERBS[i] as Flashcard, 'definition')),
    );
    expect(new Set(places).size).toBeGreaterThan(1);
  });
});

describe('a written answer', () => {
  it('is graded by the rule typed recall is graded by everywhere else', () => {
    expect(writtenCorrect('to go', 'to go')).toBe(true);
    expect(writtenCorrect('To  go.', 'to go')).toBe(true);
    expect(writtenCorrect('colour', 'color')).toBe(true);
    // Two letters swapped are a slip; one letter substituted is another word.
    expect(writtenCorrect('mitochondira', 'mitochondria')).toBe(true);
    expect(writtenCorrect('efferent', 'afferent')).toBe(false);
    expect(writtenCorrect('', 'to go')).toBe(false);
    expect(writtenCorrect('Na-', 'Na+')).toBe(false);
  });
});

describe('Flashcards: a round', () => {
  const ids = VERBS.slice(0, 4).map((c) => c.id);

  it('goes in the set’s order, or a shuffled one the seed fixes', () => {
    expect(startCardsRound(ids, null).order).toEqual(ids);
    const shuffled = startCardsRound(ids, 'seed-a').order;
    expect([...shuffled].sort()).toEqual([...ids].sort());
    expect(startCardsRound(ids, 'seed-a').order).toEqual(shuffled);
  });

  it('moves with Previous and Next, and ends past the last card', () => {
    let round = startCardsRound(ids, null);
    expect(stepRound(round, -1)).toBe(round);
    round = stepRound(round, 1);
    expect(round.index).toBe(1);
    round = stepRound(stepRound(stepRound(round, 1), 1), 1);
    expect(roundOver(round)).toBe(true);
    expect(stepRound(round, 1).index).toBe(4);
    expect(roundOver(stepRound(round, -1))).toBe(false);
  });

  it('sorts a card, moves on, and ends with the ones still to learn', () => {
    let round = startCardsRound(ids, null);
    round = sortCard(round, 'known');
    round = sortCard(round, 'learning');
    // Passed with Next rather than sorted: not claimed as known.
    round = stepRound(round, 1);
    round = sortCard(round, 'known');
    expect(roundOver(round)).toBe(true);
    expect(round.known).toEqual(['c1', 'c4']);
    expect(stillLearning(round)).toEqual(['c2', 'c3']);
    expect(sortCard(round, 'known')).toBe(round);
  });

  it('takes a card back out of "known" when it is sorted again as still learning', () => {
    let round = sortCard(startCardsRound(ids, null), 'known');
    round = sortCard(stepRound(round, -1), 'learning');
    expect(round.known).toEqual([]);
    expect(stillLearning(round)).toEqual(ids);
  });

  it('studies the ones still learning as a round of their own', () => {
    let round = sortCard(startCardsRound(ids, null), 'known');
    round = stepRound(round, 3);
    const next = startCardsRound(stillLearning(round), null);
    expect(next.order).toEqual(['c2', 'c3', 'c4']);
    expect(next.known).toEqual([]);
  });

  it('shuffles from the first card and keeps what was sorted', () => {
    const round = sortCard(startCardsRound(ids, null), 'known');
    const shuffled = shuffleRound(round, 'again');
    expect(shuffled.index).toBe(0);
    expect(shuffled.known).toEqual(['c1']);
    expect([...shuffled.order].sort()).toEqual([...ids].sort());
  });

  it('comes back from storage against the set as it is now', () => {
    const saved = { order: ['c1', 'gone', 'c2', 'c3'], index: 3, known: ['c1', 'gone'] };
    // One card before the place was deleted, so the place moves back with it.
    expect(restoreRound(saved, ['c1', 'c2', 'c3', 'c9'])).toEqual({
      order: ['c1', 'c2', 'c3'],
      index: 2,
      known: ['c1'],
    });
    expect(restoreRound({ order: ['gone'], index: 0, known: [] }, ['c1'])).toBeNull();
    expect(restoreRound('not a round', ['c1'])).toBeNull();
    expect(restoreRound({ order: ['c1'], index: 'x', known: [] }, ['c1'])).toBeNull();
    expect(restoreRound({ order: ['c1'], index: 9, known: [] }, ['c1'])?.index).toBe(1);
  });
});

describe('Learn', () => {
  const cards = VERBS;
  const ids = cards.map((c) => c.id);
  const fresh = () => startLearn(cards, ids, 'term', 'learn-seed');

  /** Answer the question on screen, right or wrong, and go on. */
  const answer = (s: LearnState, correct: boolean) =>
    continueLearn(answerLearn(s, correct, correct ? 'right' : 'wrong'));

  it('asks rounds of seven from the cards not mastered, multiple choice first', () => {
    const s = fresh();
    expect(s.round).toHaveLength(LEARN_ROUND);
    expect([...s.order].sort()).toEqual([...ids].sort());
    const q = learnQuestion(s, cards);
    expect(q?.kind).toBe('choice');
    expect(q?.kind === 'choice' && q.options).toContain(q?.answer);
    expect(q?.answer).toBe(answerOf(q?.card as Flashcard, 'term'));
  });

  it('asks a card in writing once it is right in multiple choice, and masters it there', () => {
    let s = fresh();
    const first = s.round[0] as string;
    s = answer(s, true);
    expect(s.stages[first]).toBe('written');
    // Through the rest of the round.
    for (let i = 1; i < LEARN_ROUND; i += 1) s = answer(s, true);
    expect(learnRoundOver(s)).toBe(true);
    s = nextLearnRound(s);
    expect(s.roundNo).toBe(2);
    expect(s.round[0]).toBe(first);
    expect(learnQuestion(s, cards)?.kind).toBe('written');
    s = answer(s, true);
    expect(s.stages[first]).toBe('mastered');
    expect(learnProgress(s).mastered).toBe(1);
  });

  it('sends a card back to multiple choice after a wrong answer at either stage', () => {
    let s = fresh();
    const first = s.round[0] as string;
    s = answer(s, false);
    expect(s.stages[first]).toBe('choice');
    s = answerLearn(s, true, 'x');
    s = continueLearn(s);
    const second = s.round[1] as string;
    expect(s.stages[second]).toBe('written');
    // Wrong in writing: back to the start.
    for (let i = 2; i < LEARN_ROUND; i += 1) s = answer(s, true);
    s = nextLearnRound(s);
    s = answer(s, true); // `first`, now right in multiple choice
    s = answer(s, false); // `second`, wrong in writing
    expect(s.stages[second]).toBe('choice');
  });

  it('counts a written answer right on the reader’s word, and only a written one', () => {
    let s = fresh();
    const first = s.round[0] as string;
    s = answerLearn(s, false, 'wrong');
    // A choice was the answer or it was not.
    expect(claimRight(s)).toBe(s);
    s = continueLearn(s);
    for (let i = 1; i < LEARN_ROUND; i += 1) s = answer(s, true);
    s = nextLearnRound(s);
    s = answer(s, true); // `first` right in multiple choice
    for (let i = 1; i < s.round.length; i += 1) s = answer(s, true);
    s = nextLearnRound(s);
    expect(s.round[0]).toBe(first);
    s = answerLearn(s, false, 'ser?');
    expect(s.stages[first]).toBe('choice');
    s = claimRight(s);
    expect(s.stages[first]).toBe('mastered');
    expect(s.answered).toMatchObject({ correct: true, overridden: true, response: 'ser?' });
    expect(claimRight(s)).toBe(s);
  });

  it('keeps the question on screen, and its options, while its answer is shown', () => {
    let s = fresh();
    const before = learnQuestion(s, cards);
    s = answerLearn(s, true, 'right');
    const after = learnQuestion(s, cards);
    expect(after?.kind).toBe('choice');
    expect(after).toEqual(before);
    // One answer per question.
    expect(answerLearn(s, false, 'again')).toBe(s);
  });

  it('fills a round from the next cards once others are mastered', () => {
    let s = fresh();
    const firstRound = [...s.round];
    for (let round = 0; round < 2; round += 1) {
      for (let i = 0; i < s.round.length; i += 1) s = answer(s, true);
      s = nextLearnRound(s);
    }
    // Every card of the first round is mastered, so the third round is the rest.
    expect(firstRound.every((id) => s.stages[id] === 'mastered')).toBe(true);
    expect(s.round).toEqual(s.order.slice(LEARN_ROUND));
  });

  it('ends once every card is mastered', () => {
    let s = startLearn(cards, ['c1', 'c2'], 'term', 'x');
    expect(learnDone(s)).toBe(false);
    for (let round = 0; round < 2; round += 1) {
      for (let i = 0; i < s.round.length; i += 1) s = answer(s, true);
      s = nextLearnRound(s);
    }
    expect(learnDone(s)).toBe(true);
    expect(s.round).toEqual([]);
    expect(learnQuestion(s, cards)).toBeNull();
    expect(learnProgress(s)).toEqual({ mastered: 2, total: 2 });
  });

  it('asks a lone card in writing from the start, and after a miss', () => {
    let s = startLearn([VERBS[0] as Flashcard], ['c1'], 'term', 'x');
    expect(learnQuestion(s, [VERBS[0] as Flashcard])?.kind).toBe('written');
    s = answer(s, false);
    expect(s.stages['c1']).toBe('written');
    s = nextLearnRound(s);
    s = answer(s, true);
    expect(learnDone(nextLearnRound(s))).toBe(true);
  });

  it('asks a two-card set as a choice of two first, not in writing', () => {
    const two = VERBS.slice(0, 2);
    const s = startLearn(two, ['c1', 'c2'], 'term', 'two');
    expect(s.writtenOnly).toEqual([]);
    const q = learnQuestion(s, two);
    expect(q?.kind).toBe('choice');
    expect(q?.kind === 'choice' && q.options).toHaveLength(2);
  });

  it('shuffles a card’s options again when it is asked again in a later round', () => {
    // Where the right option was must not be how it is answered the second time.
    const moved = Array.from({ length: 20 }, (_, k) => {
      let s = startLearn(cards, ids, 'term', `again-${k}`);
      const first = learnQuestion(s, cards);
      s = answerLearn(s, false, 'wrong');
      for (let i = 0; i < LEARN_ROUND; i += 1) s = continueLearn(answerLearn(s, true, 'right'));
      s = nextLearnRound(s);
      const again = learnQuestion(s, cards);
      expect(again?.card.id).toBe(first?.card.id);
      return first?.kind === 'choice' && again?.kind === 'choice'
        ? first.options.join('|') !== again.options.join('|')
        : false;
    });
    expect(moved.some(Boolean)).toBe(true);
  });

  it('learns only the cards it is given, as "the ones you missed" asks', () => {
    const s = startLearn(cards, ['c3', 'c5', 'nope'], 'definition', 'x');
    expect([...s.order].sort()).toEqual(['c3', 'c5']);
    // Distractors still come from the whole set, so two cards get more than one wrong option.
    const q = learnQuestion(s, cards);
    expect(q?.kind === 'choice' && q.options).toHaveLength(CHOICES);
  });
});

describe('Test', () => {
  const kinds = ['true_false', 'choice', 'written'] as const;

  it('asks twenty questions by default, or every card of a smaller set', () => {
    expect(defaultTestCount(40)).toBe(20);
    expect(defaultTestCount(7)).toBe(7);
  });

  it('picks the cards and deals the kinds by the seed, one section a kind', () => {
    const qs = buildTest(VERBS, { count: 9, kinds, answerWith: 'definition' }, 'test-1');
    expect(qs).toHaveLength(9);
    expect(new Set(qs.map((q) => q.cardId)).size).toBe(9);
    expect(qs.map((q) => q.kind)).toEqual([
      ...Array<string>(3).fill('true_false'),
      ...Array<string>(3).fill('choice'),
      ...Array<string>(3).fill('written'),
    ]);
    expect(buildTest(VERBS, { count: 9, kinds, answerWith: 'definition' }, 'test-1')).toEqual(qs);
    const other = buildTest(VERBS, { count: 9, kinds, answerWith: 'definition' }, 'test-2');
    expect(other.map((q) => q.cardId)).not.toEqual(qs.map((q) => q.cardId));
  });

  it('asks only the kinds chosen, and nothing when none is', () => {
    const qs = buildTest(VERBS, { count: 5, kinds: ['choice'], answerWith: 'term' }, 's');
    expect(qs.every((q) => q.kind === 'choice')).toBe(true);
    expect(buildTest(VERBS, { count: 5, kinds: [], answerWith: 'term' }, 's')).toEqual([]);
    expect(buildTest(VERBS, { count: 50, kinds, answerWith: 'term' }, 's')).toHaveLength(10);
    expect(buildTest(VERBS, { count: 0, kinds, answerWith: 'term' }, 's')).toHaveLength(1);
  });

  it('makes a true/false statement true with its own answer and false with another’s', () => {
    const qs = buildTest(
      VERBS,
      { count: 10, kinds: ['true_false'], answerWith: 'definition' },
      't',
    );
    const tf = qs.filter((q) => q.kind === 'true_false');
    expect(tf).toHaveLength(10);
    for (const q of tf) {
      const own = answerOf(VERBS.find((c) => c.id === q.cardId) as Flashcard, 'definition');
      expect(q.shown === own).toBe(q.truth);
      if (!q.truth) expect(VERBS.map((c) => c.definition)).toContain(q.shown);
    }
    // About half and half, over enough of them.
    const many = Array.from({ length: 20 }, (_, i) =>
      buildTest(VERBS, { count: 10, kinds: ['true_false'], answerWith: 'term' }, `t${i}`),
    ).flat();
    const trues = many.filter((q) => q.kind === 'true_false' && q.truth).length;
    expect(trues).toBeGreaterThan(many.length * 0.3);
    expect(trues).toBeLessThan(many.length * 0.7);
  });

  it('asks in writing a card that has nothing to choose between', () => {
    const one = [VERBS[0] as Flashcard];
    const qs = buildTest(
      one,
      { count: 1, kinds: ['true_false', 'choice'], answerWith: 'term' },
      's',
    );
    expect(qs).toEqual([
      {
        kind: 'written',
        cardId: 'c1',
        prompt: 'to be (lasting)',
        answer: 'ser',
        accepted: ['ser'],
      },
    ]);
  });

  it('grades everything at once, an unanswered question as wrong', () => {
    const qs: TestQuestion[] = [
      { kind: 'true_false', cardId: 'c1', prompt: 'ser', answer: 'a', shown: 'b', truth: false },
      { kind: 'true_false', cardId: 'c2', prompt: 'estar', answer: 'a', shown: 'a', truth: true },
      {
        kind: 'choice',
        cardId: 'c3',
        prompt: 'ir',
        answer: 'to go',
        accepted: ['to go'],
        options: ['to go', 'to be'],
      },
      { kind: 'written', cardId: 'c4', prompt: 'to have', answer: 'tener', accepted: ['tener'] },
      { kind: 'written', cardId: 'c5', prompt: 'to do', answer: 'hacer', accepted: ['hacer'] },
      {
        kind: 'choice',
        cardId: 'c1',
        prompt: 'ser',
        answer: 'x',
        accepted: ['x'],
        options: ['x', 'y'],
      },
    ];
    const result = gradeTest(qs, [false, false, 'to go', 'Tener.', '   ', null]);
    expect(result.correct).toEqual([true, false, true, true, false, false]);
    expect(result.score).toBe(3);
    expect(result.total).toBe(6);
    // Once each, for "Learn the ones you missed" -- a card missed twice is one card to learn.
    expect(result.missed).toEqual(['c2', 'c5', 'c1']);
    expect(gradeTest([qs[0] as TestQuestion, qs[5] as TestQuestion], [true, 'y']).missed).toEqual([
      'c1',
    ]);
    expect(gradeTest(qs, []).score).toBe(0);
  });
});

describe('Match', () => {
  const now = 1_000_000;

  it('lays out up to six cards as twelve tiles, and needs two', () => {
    const state = startMatch(VERBS, 'm') as MatchState;
    expect(state.tiles).toHaveLength(MATCH_CARDS * 2);
    expect(new Set(state.tiles.map((t) => t.id)).size).toBe(12);
    expect(startMatch(VERBS.slice(0, 3), 'm')?.tiles).toHaveLength(6);
    expect(startMatch(VERBS.slice(0, 1), 'm')).toBeNull();
    expect(startMatch(VERBS, 'm')).toEqual(state);
  });

  it('never lays out two tiles that read the same', () => {
    const cards = [
      card('a', 'ser', 'to be'),
      card('b', 'estar', 'To be.'),
      card('c', 'same', 'same'),
      card('d', 'ir', 'to go'),
    ];
    const chosen = matchCards(cards, 'seed').map((c) => c.id);
    expect(chosen).toHaveLength(2);
    expect(chosen).toContain('d');
    expect(chosen).not.toContain('c');
  });

  it('offers a game exactly when it can lay one out, whatever the seed', () => {
    // A's tiles clash with B's (y) and with C's (x); B and C are a game.
    const abc = [card('A', 'x', 'y'), card('B', 'y', 'p'), card('C', 'q', 'x')];
    expect(canMatch(abc)).toBe(true);
    for (let i = 0; i < 1000; i += 1) {
      const game = startMatch(abc, `s${i}`);
      expect(game).not.toBeNull();
      expect(new Set(game?.tiles.map((t) => t.cardId))).toEqual(new Set(['B', 'C']));
    }
    // A star -- every card sharing one tile's text -- and a triangle have no two cards apart.
    const star = [card('1', 'hub', 'a'), card('2', 'hub', 'b'), card('3', 'c', 'hub')];
    const triangle = [card('1', 'x', 'y'), card('2', 'y', 'z'), card('3', 'z', 'x')];
    for (const cards of [star, triangle, [card('1', 'same', 'Same.'), card('2', 'a', 'b')]]) {
      expect(canMatch(cards)).toBe(false);
      expect(startMatch(cards, 'm')).toBeNull();
    }
    expect(canMatch(VERBS)).toBe(true);
    expect(canMatch(VERBS.slice(0, 1))).toBe(false);
  });

  it('clears a card’s term and definition as a pair, and stops the clock at the last', () => {
    let s = startMatch(VERBS.slice(0, 2), 'm') as MatchState;
    s = selectTile(s, 'c1:term', now);
    expect(s.startedAt).toBe(now);
    expect(s.last).toEqual({ kind: 'selected', tileId: 'c1:term' });
    s = selectTile(s, 'c1:definition', now + 1_000);
    expect(s.cleared).toEqual(['c1']);
    expect(s.last).toEqual({ kind: 'pair', cardId: 'c1' });
    expect(matchDone(s)).toBe(false);
    // A cleared tile does nothing.
    expect(selectTile(s, 'c1:term', now + 1_500)).toBe(s);
    s = selectTile(s, 'c2:definition', now + 2_000);
    s = selectTile(s, 'c2:term', now + 23_456);
    expect(matchDone(s)).toBe(true);
    expect(elapsedTenths(s, now + 99_999)).toBe(234);
    expect(formatTenths(elapsedTenths(s, now + 99_999))).toBe('23.4 s');
    expect(selectTile(s, 'c2:term', now + 30_000)).toBe(s);
  });

  it('says a wrong pair is not one, and holds nothing after it', () => {
    let s = startMatch(VERBS.slice(0, 3), 'm') as MatchState;
    s = selectTile(s, 'c1:term', now);
    s = selectTile(s, 'c2:definition', now + 500);
    expect(s.last).toEqual({ kind: 'miss', tileIds: ['c1:term', 'c2:definition'] });
    expect(s.selected).toBeNull();
    expect(s.cleared).toEqual([]);
    // Two terms are never a pair.
    s = selectTile(s, 'c1:term', now + 600);
    s = selectTile(s, 'c2:term', now + 700);
    expect(s.last?.kind).toBe('miss');
  });

  it('lets a tile go when it is chosen again', () => {
    let s = startMatch(VERBS.slice(0, 2), 'm') as MatchState;
    s = selectTile(s, 'c1:term', now);
    s = selectTile(s, 'c1:term', now + 10);
    expect(s.selected).toBeNull();
    expect(s.last).toEqual({ kind: 'deselected', tileId: 'c1:term' });
    // The clock started on the first choice and keeps going.
    expect(s.startedAt).toBe(now);
    expect(elapsedTenths(s, now + 1_234)).toBe(12);
  });

  it('shows no time before the first choice', () => {
    const s = startMatch(VERBS, 'm') as MatchState;
    expect(elapsedTenths(s, now)).toBe(0);
    expect(formatTenths(0)).toBe('0.0 s');
    expect(formatTenths(7)).toBe('0.7 s');
    expect(formatTenths(1234)).toBe('123.4 s');
  });

  it('keeps the best time only when it is better', () => {
    expect(readBestTime(null)).toBeNull();
    expect(readBestTime('234')).toBe(234);
    expect(readBestTime('-1')).toBeNull();
    expect(readBestTime('2.5')).toBeNull();
    expect(readBestTime('nonsense')).toBeNull();
    expect(beatsBest(200, null)).toBe(true);
    expect(beatsBest(200, 234)).toBe(true);
    expect(beatsBest(234, 234)).toBe(false);
    expect(beatsBest(300, 234)).toBe(false);
  });
});

describe('editing a set', () => {
  let n = 0;
  const mint = () => `new-${(n += 1)}`;

  it('starts a new set with empty rows that each have an id', () => {
    const d = newDraft('s-new', mint);
    expect(d.cards).toHaveLength(3);
    expect(new Set(d.cards.map((c) => c.id)).size).toBe(3);
  });

  it('moves a row up and down, and not past either end', () => {
    const rows = draftOf(set(VERBS.slice(0, 3))).cards;
    expect(moveDraftCard(rows, 2, -1).map((c) => c.id)).toEqual(['c1', 'c3', 'c2']);
    expect(moveDraftCard(rows, 0, 1).map((c) => c.id)).toEqual(['c2', 'c1', 'c3']);
    expect(moveDraftCard(rows, 0, -1).map((c) => c.id)).toEqual(['c1', 'c2', 'c3']);
    expect(moveDraftCard(rows, 2, 1).map((c) => c.id)).toEqual(['c1', 'c2', 'c3']);
  });

  it('saves trimmed, leaves out unused rows, and keeps each card’s id', () => {
    const d = {
      ...newDraft('s-new', mint),
      title: '  Verbs ',
      termLang: 'es',
      cards: [
        { id: 'k1', term: ' ser ', definition: ' to be ' },
        { id: 'k2', term: '', definition: '  ' },
        { id: 'k3', term: 'ir', definition: 'to go' },
      ],
    };
    expect(validateDraft(d)).toEqual({
      payload: {
        id: 's-new',
        title: 'Verbs',
        description: null,
        termLang: 'es',
        definitionLang: null,
        cards: [
          { id: 'k1', term: 'ser', definition: 'to be' },
          { id: 'k3', term: 'ir', definition: 'to go' },
        ],
      },
      problems: [],
    });
  });

  it('says what is wrong, by card number, rather than dropping half a card', () => {
    const d = {
      ...newDraft('s', mint),
      termLang: 'Spanish',
      cards: [
        { id: 'a', term: 'ser', definition: '' },
        { id: 'b', term: '', definition: 'to go' },
        { id: 'c', term: 't'.repeat(1001), definition: 'x' },
      ],
    };
    expect(validateDraft(d)).toEqual({
      payload: null,
      problems: [
        'Give the set a title.',
        'The term language should be a language code, such as “fr” or “pt-BR”.',
        'Card 1 needs a definition.',
        'Card 2 needs a term.',
        'Card 3’s term is over 1,000 characters.',
      ],
    });
    expect(validateDraft({ ...newDraft('s', mint), title: 'T' }).problems).toEqual([
      'Add at least one card.',
    ]);
    const tooMany = {
      ...newDraft('s', mint),
      title: 'T',
      cards: Array.from({ length: CARD_LIMIT + 1 }, (_, i) => ({
        id: `x${i}`,
        term: 't',
        definition: 'd',
      })),
    };
    expect(validateDraft(tooMany).problems).toEqual(['A set holds at most 2,000 cards.']);
  });

  it('refuses a language code longer than the database keeps, though its shape is right', () => {
    const tag = 'en-aaaaaaaa-bbbbbbbb-cccccccc-dddddd';
    expect(tag).toHaveLength(36);
    const d = { ...newDraft('s', mint), title: 'T', definitionLang: tag };
    d.cards = [{ id: 'a', term: 'a', definition: 'b' }];
    expect(validateDraft(d).problems).toEqual([
      'The definition language should be a language code, such as “fr” or “pt-BR”.',
    ]);
    expect(validateDraft({ ...d, definitionLang: tag.slice(0, 35) }).problems).toEqual([]);
  });

  it('counts characters as the database does, not UTF-16 units', () => {
    const emoji = '\u{1F600}';
    const d = { ...newDraft('s', mint), title: emoji.repeat(200) };
    d.cards = [{ id: 'a', term: emoji.repeat(1000), definition: emoji.repeat(2000) }];
    expect(validateDraft(d).problems).toEqual([]);
    expect(validateDraft({ ...d, title: emoji.repeat(201) }).problems).toEqual([
      'A title is at most 200 characters.',
    ]);
    // Blank as `.trim()` has it, which the database now shares: a no-break space is nothing.
    expect(validateDraft({ ...d, title: '\u00a0\u3000' }).problems).toEqual([
      'Give the set a title.',
    ]);
    expect(charCount(`a${emoji}b`)).toBe(3);
    expect(utf8Length(`a${emoji}é`)).toBe(1 + 4 + 2);
  });

  it('weighs the set as the database does, and says when it is over 2 MB', () => {
    const emoji = '\u{1F600}';
    // 174 cards of four-byte characters at both limits, and the rest in one-byte ones: the
    // database test's own set, exactly 2 MB.
    const cards = [
      ...Array.from({ length: 174 }, (_, i) => ({
        id: `e${i}`,
        term: emoji.repeat(1000),
        definition: emoji.repeat(2000),
      })),
      ...Array.from({ length: 4 }, (_, i) => ({
        id: `d${i}`,
        term: 'x',
        definition: 'd'.repeat(2000),
      })),
      { id: 'last', term: 'x', definition: 'd'.repeat(1144) },
    ];
    const d = { ...newDraft('s', mint), title: 'Big', cards };
    expect(validateDraft(d).problems).toEqual([]);
    expect(validateDraft({ ...d, description: 'd' }).problems).toEqual([
      `This set’s text comes to 2.1 MB, and a set holds at most 2 MB. Split it into two.`,
    ]);
    expect(SET_BYTES_LIMIT).toBe(2 * 1024 * 1024);
  });

  it('knows an unsaved change from a save that would change nothing', () => {
    const saved = set(VERBS.slice(0, 2));
    const d = draftOf(saved);
    expect(draftUnsaved(d, saved)).toBe(false);
    expect(draftUnsaved({ ...d, title: `${d.title}  ` }, saved)).toBe(false);
    expect(
      draftUnsaved({ ...d, cards: [...d.cards, { id: 'z', term: '', definition: '' }] }, saved),
    ).toBe(false);
    expect(draftUnsaved({ ...d, title: 'Other' }, saved)).toBe(true);
    expect(draftUnsaved({ ...d, cards: moveDraftCard(d.cards, 0, 1) }, saved)).toBe(true);
    expect(draftUnsaved({ ...d, description: 'New' }, saved)).toBe(true);
    // The same words under another card's id is another card: its memory would not follow.
    const renamed = d.cards.map((c, i) => (i === 0 ? { ...c, id: 'another' } : c));
    expect(draftUnsaved({ ...d, cards: renamed }, saved)).toBe(true);
    const fresh = newDraft('n', mint);
    expect(draftUnsaved(fresh, null)).toBe(false);
    expect(draftUnsaved({ ...fresh, title: 'x' }, null)).toBe(true);
  });
});

describe('cards that share a prompt', () => {
  // "bank" twice: each meaning is a right answer to it, so neither is ever a wrong one.
  const BANKS = [
    card('river', 'bank', 'the edge of a river'),
    card('money', 'bank', 'a place that keeps money'),
    card('cat', 'cat', 'a small animal that purrs'),
    card('dog', 'dog', 'an animal that barks'),
    card('sun', 'sun', 'the star at the centre of the solar system'),
  ];
  const river = BANKS[0] as Flashcard;

  it('never offers the other meaning as a wrong option', () => {
    expect(otherAnswers(BANKS, river, 'definition')).not.toContain('a place that keeps money');
    for (let i = 0; i < 50; i += 1) {
      const options = choiceOptions(BANKS, river, 'definition', `s${i}`);
      expect(options).toContain('the edge of a river');
      expect(options).not.toContain('a place that keeps money');
    }
  });

  it('never makes a false statement of the other meaning', () => {
    for (let i = 0; i < 50; i += 1) {
      const qs = buildTest(
        BANKS,
        { count: 5, kinds: ['true_false'], answerWith: 'definition' },
        `t${i}`,
      );
      for (const q of qs) {
        if (q.kind !== 'true_false' || q.truth) continue;
        const own = BANKS.find((c) => c.id === q.cardId) as Flashcard;
        expect(acceptedAnswers(BANKS, own, 'definition')).not.toContain(q.shown);
      }
    }
  });

  it('accepts either meaning, typed or chosen, in Test and in Learn', () => {
    expect(acceptedAnswers(BANKS, river, 'definition')).toEqual([
      'the edge of a river',
      'a place that keeps money',
    ]);
    const qs = buildTest(BANKS, { count: 5, kinds: ['written'], answerWith: 'definition' }, 'w');
    const q = qs.find((x) => x.cardId === 'river') as TestQuestion;
    const i = qs.indexOf(q);
    const responses = qs.map((_, k) => (k === i ? 'A place that keeps money.' : null));
    expect(gradeTest(qs, responses).correct[i]).toBe(true);

    let s = startLearn(BANKS, ['river'], 'definition', 'l');
    s = answerLearn(s, true, 'x');
    s = nextLearnRound(continueLearn(s));
    const written = learnQuestion(s, BANKS);
    expect(written?.kind).toBe('written');
    expect(written && learnCorrect(written, 'A place that keeps money.')).toBe(true);
    expect(written && learnCorrect(written, 'a cat')).toBe(false);
    expect(written && learnCorrect(written, '   ')).toBe(false);
  });

  it('asks in writing a card whose only other answers are right ones too', () => {
    const pair = BANKS.slice(0, 2);
    const s = startLearn(pair, ['river', 'money'], 'definition', 'p');
    expect(s.writtenOnly).toEqual(expect.arrayContaining(['river', 'money']));
    expect(learnQuestion(s, pair)?.kind).toBe('written');
  });

  it('keeps synonyms apart when answering with the term', () => {
    const synonyms = [
      card('b', 'big', 'grande'),
      card('l', 'large', 'grande'),
      card('s', 'small', 'pequeño'),
    ];
    const big = synonyms[0] as Flashcard;
    expect(otherAnswers(synonyms, big, 'term')).toEqual(['small']);
    expect(acceptedAnswers(synonyms, big, 'term')).toEqual(['big', 'large']);
  });
});

describe('a large set', () => {
  // The Learn and Test that froze: every card's answer keyed again for every other card.
  const big = Array.from({ length: CARD_LIMIT }, (_, i) =>
    card(`id-${i}`, `term number ${i} café`, `the definition of thing ${i}, a sentence long`),
  );
  // And a set whose answers are nearly all one answer, where a walk for three distinct
  // distractors has least to find.
  const alike = Array.from({ length: CARD_LIMIT }, (_, i) =>
    card(`a-${i}`, `question ${i}`, i < 3 ? `answer ${i}` : 'the same answer'),
  );
  const ids = big.map((c) => c.id);
  const all = { count: CARD_LIMIT, kinds: ['true_false', 'choice', 'written'] as const };
  /*
   * Each step alone takes tens of milliseconds, and took 46 seconds (Learn) and 32 (a Test of
   * every card) before. The budget is thirty times the first, so a loaded machine running
   * every package's tests at once does not fail it, and twenty times under the second.
   */
  const BUDGET_MS = 1500;

  it('opens Learn, builds a test of every card, and asks each question, all at once', () => {
    for (const cards of [big, alike]) {
      const fresh = [...cards];
      let t = performance.now();
      const s = startLearn(
        fresh,
        fresh.map((c) => c.id),
        'definition',
        'seed',
      );
      expect(performance.now() - t).toBeLessThan(BUDGET_MS);
      t = performance.now();
      for (let i = 0; i < 1000; i += 1) learnQuestion(s, fresh);
      expect(performance.now() - t).toBeLessThan(BUDGET_MS);
      for (const answerWith of ['definition', 'term'] as const) {
        t = performance.now();
        expect(buildTest(fresh, { ...all, answerWith }, answerWith)).toHaveLength(CARD_LIMIT);
        expect(performance.now() - t).toBeLessThan(BUDGET_MS);
      }
    }
    expect(startLearn(big, ids, 'definition', 'seed').writtenOnly).toEqual([]);
  });

  it('still offers three distractors where there are three to offer', () => {
    const q = choiceOptions(alike, alike[10] as Flashcard, 'definition', 'z');
    expect(q).toHaveLength(CHOICES);
    expect(new Set(q.map(answerKey)).size).toBe(CHOICES);
    // The card that says "the same answer" has only three others to be wrong with.
    expect(distractors(alike, alike[10] as Flashcard, 'definition', 9, 'z')).toHaveLength(3);
  });
});

describe('a refused save, in words', () => {
  it('names the limit, the guest and the signed-out reader', () => {
    expect(saveRefusal('54000', 'sets', '')).toMatch(/500 sets/);
    expect(saveRefusal('54000', 'cards', '')).toMatch(/2,000 cards/);
    expect(saveRefusal('54000', undefined, '')).toBeNull();
    expect(saveRefusal('42501', 'guest', '')).toMatch(/guest session/);
    expect(saveRefusal('42501', undefined, '')).toBeNull();
    expect(saveRefusal('28000', undefined, '')).toMatch(/signed out/);
    expect(saveRefusal('P0002', undefined, '')).toMatch(/could not be found/);
    expect(saveRefusal('22023', undefined, "card 3's term is 1 to 1000 characters")).toBe(
      'The set could not be saved as it is. Card 3’s term is 1 to 1000 characters.',
    );
    expect(saveRefusal(undefined, undefined, 'x')).toBeNull();
    expect(saveRefusal('54000', 'total', '')).toMatch(/20,000 cards across its sets/);
    expect(saveRefusal('54000', 'size', '')).toMatch(/2 MB of text/);
    expect(saveRefusal('40001', 'changed', '')).toMatch(/changed somewhere else/);
    expect(saveRefusal('40001', undefined, '')).toBeNull();
  });

  it('knows a set changed or deleted elsewhere from any other refusal', () => {
    expect(saveConflict('40001', 'changed')).toBe('changed');
    expect(saveConflict('P0002', undefined)).toBe('gone');
    expect(saveConflict('40001', undefined)).toBeNull();
    expect(saveConflict('54000', 'total')).toBeNull();
    expect(saveConflict(undefined, undefined)).toBeNull();
  });
});

describe('what the screens keep in this browser', () => {
  it('keys everything by reader and set, so a reader’s keys can be found together', () => {
    const keys = [
      roundKey('u1', 's1'),
      bestTimeKey('u1', 's2'),
      draftKey('u1', 's3'),
      draftKey('u1', null),
    ];
    expect(keys).toEqual([
      'wap:flashcards:round:u1:s1',
      'wap:flashcards:match-best:u1:s2',
      'wap:flashcards:draft:u1:s3',
      'wap:flashcards:draft:u1:new',
    ]);
    for (const key of keys) expect(isReadersFlashcardKey(key, 'u1')).toBe(true);
    for (const key of keys) expect(isReadersFlashcardKey(key, 'u')).toBe(false);
    expect(isReadersFlashcardKey('wap:flashcards:round:u10:s1', 'u1')).toBe(false);
    expect(isReadersFlashcardKey('wap:other:u1:s1', 'u1')).toBe(false);
  });

  it('reads back a kept draft for its own set, in the shape this build writes, or nothing', () => {
    const draft = draftOf(set(VERBS.slice(0, 2)));
    const raw = JSON.stringify({ draft, base: '2026-09-26T10:00:00.123456+00:00' });
    expect(readKeptDraft(raw, 's1')).toEqual({ draft, base: '2026-09-26T10:00:00.123456+00:00' });
    // A new set's draft may have any id: the one minted when it was begun.
    expect(readKeptDraft(JSON.stringify({ draft, base: null }), null)?.draft.id).toBe('s1');
    expect(readKeptDraft(raw, 'another set')).toBeNull();
    expect(readKeptDraft(null, 's1')).toBeNull();
    expect(readKeptDraft('not json', 's1')).toBeNull();
    expect(
      readKeptDraft(JSON.stringify({ draft: { ...draft, cards: [{ id: 1 }] }, base: null }), 's1'),
    ).toBeNull();
    expect(
      readKeptDraft(JSON.stringify({ draft: { ...draft, title: 7 }, base: null }), 's1'),
    ).toBeNull();
    expect(readKeptDraft(JSON.stringify({ draft, base: 5 }), 's1')).toBeNull();
  });
});
