import { describe, expect, it } from 'vitest';
import {
  exportFileName,
  guessSeparators,
  parseImport,
  separatorProblem,
  toTsv,
  type ImportOptions,
} from './flashcards-import.js';

const TAB_LINES: ImportOptions = { between: { kind: 'tab' }, cardsBy: { kind: 'newline' } };
const CSV: ImportOptions = { between: { kind: 'comma' }, cardsBy: { kind: 'newline' } };

describe('pasting a set', () => {
  it('reads Quizlet’s own export: a tab between, a line a card', () => {
    const out = parseImport('ser\tto be (lasting)\nestar\tto be (for now)\n', TAB_LINES);
    expect(out.cards).toEqual([
      { term: 'ser', definition: 'to be (lasting)' },
      { term: 'estar', definition: 'to be (for now)' },
    ]);
    expect(out.problems).toEqual([]);
  });

  it('splits at the first separator only, so a definition keeps its own', () => {
    const out = parseImport('hacer\tto do\tto make', TAB_LINES);
    expect(out.cards).toEqual([{ term: 'hacer', definition: 'to do\tto make' }]);
    const dash = parseImport('ir - to go - to leave', {
      between: { kind: 'dash' },
      cardsBy: { kind: 'newline' },
    });
    expect(dash.cards).toEqual([{ term: 'ir', definition: 'to go - to leave' }]);
  });

  it('reads every separator Quizlet offers, and a custom one', () => {
    const semicolons = parseImport('ser\tto be;ir\tto go;', {
      between: { kind: 'tab' },
      cardsBy: { kind: 'semicolon' },
    });
    expect(semicolons.cards).toEqual([
      { term: 'ser', definition: 'to be' },
      { term: 'ir', definition: 'to go' },
    ]);
    const custom = parseImport('ser :: to be ## ir :: to go', {
      between: { kind: 'custom', text: '::' },
      cardsBy: { kind: 'custom', text: '##' },
    });
    expect(custom.cards).toEqual([
      { term: 'ser', definition: 'to be' },
      { term: 'ir', definition: 'to go' },
    ]);
    const dashes = parseImport('ser - to be\nir-to go', {
      between: { kind: 'dash' },
      cardsBy: { kind: 'newline' },
    });
    expect(dashes.cards).toEqual([{ term: 'ser', definition: 'to be' }]);
    // `-` without its spaces is part of a word, not a separator.
    expect(dashes.problems.map((p) => p.where)).toEqual(['Line 2']);
  });

  it('trims each side, skips blank lines, and reads Windows line endings', () => {
    const out = parseImport('\r\n  ser \t  to be  \r\n\r\n\t\r\nir\tto go\r\n', TAB_LINES);
    expect(out.cards).toEqual([
      { term: 'ser', definition: 'to be' },
      { term: 'ir', definition: 'to go' },
    ]);
    // A line of nothing but whitespace -- a lone tab included -- is blank, not a problem.
    expect(out.problems).toEqual([]);
  });

  it('lists a line with no separator as a problem, with its line number, not silently', () => {
    const out = parseImport('ser\tto be\njust a line\nir\t\n\tto go', TAB_LINES);
    expect(out.cards).toEqual([{ term: 'ser', definition: 'to be' }]);
    expect(out.problems).toEqual([
      {
        where: 'Line 2',
        text: 'just a line',
        reason: 'No separator between a term and a definition.',
      },
      { where: 'Line 3', text: 'ir', reason: 'No definition after the separator.' },
      { where: 'Line 4', text: 'to go', reason: 'No term before the separator.' },
    ]);
  });

  it('numbers cards rather than lines when cards are not separated by lines', () => {
    const out = parseImport('ser\tto be;nothing here;ir\tto go', {
      between: { kind: 'tab' },
      cardsBy: { kind: 'semicolon' },
    });
    expect(out.problems.map((p) => p.where)).toEqual(['Card 2']);
  });

  it('says a side is too long for a card', () => {
    const out = parseImport(`${'t'.repeat(1001)}\tx\ny\t${'d'.repeat(2001)}`, TAB_LINES);
    expect(out.cards).toEqual([]);
    expect(out.problems.map((p) => p.reason)).toEqual([
      'The term is over 1,000 characters.',
      'The definition is over 2,000 characters.',
    ]);
  });

  it('takes no more than the room left in the set, and counts the rest', () => {
    const lines = Array.from({ length: 10 }, (_, i) => `t${i}\td${i}`).join('\n');
    const out = parseImport(lines, { ...TAB_LINES, limit: 4 });
    expect(out.cards).toHaveLength(4);
    expect(out.cards[3]).toEqual({ term: 't3', definition: 'd3' });
    expect(out.over).toBe(6);
    const whole = Array.from({ length: 2005 }, (_, i) => `t${i}\td${i}`).join('\n');
    expect(parseImport(whole, TAB_LINES)).toMatchObject({ over: 5 });
  });
});

describe('Anki’s text export', () => {
  const anki = [
    '#separator:tab',
    '#html:true',
    '#notetype column:3',
    'ser\tto be<br>(lasting)',
    '#1 fan\tthe biggest one',
    'x&amp;y\t<b>and</b> &lt;both&gt;',
  ].join('\n');

  it('skips its header lines, and only those', () => {
    const out = parseImport(anki, TAB_LINES);
    expect(out.headers).toBe(3);
    // A card that begins with # is still a card.
    expect(out.cards.map((c) => c.term)).toEqual(['ser', '#1 fan', 'x&y']);
  });

  it('reads its HTML fields as text when it says they are HTML', () => {
    const out = parseImport(anki, TAB_LINES);
    expect(out.cards[0]).toEqual({ term: 'ser', definition: 'to be\n(lasting)' });
    expect(out.cards[2]).toEqual({ term: 'x&y', definition: 'and <both>' });
    // And leaves them alone when it does not.
    expect(parseImport('a<br>b\tc', TAB_LINES).cards).toEqual([
      { term: 'a<br>b', definition: 'c' },
    ]);
  });

  it('chooses the separators its header names', () => {
    expect(guessSeparators('deck.txt', anki)).toEqual(TAB_LINES);
    expect(guessSeparators('deck.txt', '#separator:Semicolon\na;b')).toEqual({
      between: { kind: 'custom', text: ';' },
      cardsBy: { kind: 'newline' },
    });
    expect(guessSeparators('deck.txt', '#separator:Pipe\na|b').between).toEqual({
      kind: 'custom',
      text: '|',
    });
    expect(guessSeparators('sheet.csv', 'a,b')).toEqual(CSV);
    expect(guessSeparators('list.tsv', 'a\tb')).toEqual(TAB_LINES);
  });
});

describe('a CSV file', () => {
  it('reads quoted fields with commas, quotes and line breaks in them', () => {
    const out = parseImport(
      'ser,"to be, lasting"\n"estar","to be\n(for now)"\n"say ""hi""",decir\n',
      CSV,
    );
    expect(out.cards).toEqual([
      { term: 'ser', definition: 'to be, lasting' },
      { term: 'estar', definition: 'to be\n(for now)' },
      { term: 'say "hi"', definition: 'decir' },
    ]);
    expect(out.problems).toEqual([]);
  });

  it('keeps the commas of an unquoted definition, as Quizlet splits at the first', () => {
    expect(parseImport('hacer,to do, to make', CSV).cards).toEqual([
      { term: 'hacer', definition: 'to do, to make' },
    ]);
  });

  it('reads a quote inside a field as a quote, not the start of one', () => {
    expect(parseImport('snow,6" of it\nrain,none', CSV).cards).toEqual([
      { term: 'snow', definition: '6" of it' },
      { term: 'rain', definition: 'none' },
    ]);
  });

  it('reads a quote that never closes as a character, and loses nothing after it', () => {
    const out = parseImport('ser,to be\n"ir,to go\nver,to see\n', CSV);
    expect(out.cards).toEqual([
      { term: 'ser', definition: 'to be' },
      { term: '"ir', definition: 'to go' },
      { term: 'ver', definition: 'to see' },
    ]);
  });

  it('says which line a problem is on, counting the lines inside quotes', () => {
    const out = parseImport('a,"one\ntwo"\nno separator\nb,c', CSV);
    expect(out.problems).toEqual([
      {
        where: 'Line 3',
        text: 'no separator',
        reason: 'No separator between a term and a definition.',
      },
    ]);
  });

  it('skips a header row and Anki’s header lines', () => {
    const out = parseImport('#separator:comma\nTerm,Definition\nser,to be\n', CSV);
    expect(out.headers).toBe(2);
    expect(out.cards).toEqual([{ term: 'ser', definition: 'to be' }]);
    // A header row only counts as one when it is the first.
    expect(parseImport('ser,to be\nterm,definition', CSV).cards).toHaveLength(2);
  });

  it('ignores a byte-order mark', () => {
    expect(parseImport('\uFEFFser,to be', CSV).cards).toEqual([
      { term: 'ser', definition: 'to be' },
    ]);
  });
});

describe('the separators chosen', () => {
  it('must be something, and must differ', () => {
    expect(separatorProblem(TAB_LINES)).toBeNull();
    expect(
      separatorProblem({ between: { kind: 'custom', text: '' }, cardsBy: { kind: 'newline' } }),
    ).toMatch(/each term/);
    expect(
      separatorProblem({ between: { kind: 'tab' }, cardsBy: { kind: 'custom', text: '' } }),
    ).toMatch(/one card/);
    expect(
      separatorProblem({ between: { kind: 'custom', text: ';' }, cardsBy: { kind: 'semicolon' } }),
    ).toMatch(/different/);
  });
});

describe('downloading a set', () => {
  it('writes a card a line, a tab between, as Quizlet and Anki read them', () => {
    expect(
      toTsv([
        { term: 'ser', definition: 'to be' },
        { term: '=SUM(A1)', definition: '+1 charge' },
      ]),
    ).toBe('ser\tto be\n=SUM(A1)\t+1 charge\n');
  });

  it('puts a field with a tab or a line break in it on one line', () => {
    expect(toTsv([{ term: 'a\tb', definition: 'one\n\ntwo \r\n three' }])).toBe(
      'a b\tone two three\n',
    );
  });

  it('reads back in as the same cards', () => {
    const cards = [
      { term: 'ser', definition: 'to be (lasting)' },
      { term: 'hacer', definition: 'to do, to make' },
      { term: '#1', definition: 'first - of all' },
      { term: '"quoted"', definition: 'with "quotes"' },
    ];
    const back = parseImport(toTsv(cards), TAB_LINES);
    expect(back.cards).toEqual(cards);
    expect(back.problems).toEqual([]);
    // A field that had a line break comes back on one line, which is what it was written as.
    expect(parseImport(toTsv([{ term: 'a', definition: 'one\ntwo' }]), TAB_LINES).cards).toEqual([
      { term: 'a', definition: 'one two' },
    ]);
  });

  it('names the file after the set', () => {
    expect(exportFileName('Spanish verbs: irregular!')).toBe('spanish-verbs-irregular.txt');
    expect(exportFileName('Ça va — café')).toBe('ca-va-cafe.txt');
    expect(exportFileName('日本語')).toBe('日本語.txt');
    expect(exportFileName('!!!')).toBe('flashcards.txt');
    expect(exportFileName('a'.repeat(100))).toBe(`${'a'.repeat(60)}.txt`);
  });
});
