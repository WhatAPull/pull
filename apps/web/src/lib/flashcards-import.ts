/**
 * Cards in and out as text: pasting a set from Quizlet or a spreadsheet, opening an Anki
 * text export, and downloading a set as a file those can open again. Pure; the screen reads
 * the file and hands the text here.
 *
 * THE SEPARATORS ARE QUIZLET'S OWN CHOICES -- between term and definition a tab, a comma or
 * something custom, between cards a new line, a semicolon or something custom -- plus a
 * dash, because "term - definition" is how people type a list by hand. A set exported from
 * Quizlet with its defaults (tab, new line) pastes straight in with ours.
 *
 * NOTHING IS DROPPED WITHOUT SAYING SO. A blank line is nothing and is skipped, and so is
 * an Anki header line; every other line either becomes a card or is listed as a problem
 * with its line number, before anything is saved. A reader who pastes two hundred lines
 * and gets a hundred and ninety-eight cards is owed the two.
 */
import { CARD_LIMIT, DEFINITION_MAX, TERM_MAX } from './flashcards.js';

export type TermSeparator =
  { kind: 'tab' } | { kind: 'comma' } | { kind: 'dash' } | { kind: 'custom'; text: string };

export type CardSeparator =
  { kind: 'newline' } | { kind: 'semicolon' } | { kind: 'custom'; text: string };

export interface ImportOptions {
  between: TermSeparator;
  cardsBy: CardSeparator;
  /** How many cards may be taken: the room left in the set. */
  limit?: number;
}

export interface ImportedCard {
  term: string;
  definition: string;
}

export interface ImportProblem {
  /** "Line 4", or "Card 4" when cards are not separated by lines. */
  where: string;
  text: string;
  reason: string;
}

export interface ImportResult {
  cards: ImportedCard[];
  problems: ImportProblem[];
  /** Anki's `#key:value` header lines, and a spreadsheet's "Term, Definition" header row. */
  headers: number;
  /** Cards past the limit, not taken. */
  over: number;
}

export function termSeparatorText(sep: TermSeparator): string {
  switch (sep.kind) {
    case 'tab':
      return '\t';
    case 'comma':
      return ',';
    case 'dash':
      return ' - ';
    case 'custom':
      return sep.text;
  }
}

export function cardSeparatorText(sep: CardSeparator): string {
  switch (sep.kind) {
    case 'newline':
      return '\n';
    case 'semicolon':
      return ';';
    case 'custom':
      return sep.text;
  }
}

/** What is wrong with the separators chosen, or null: a custom one has to be something. */
export function separatorProblem(
  options: Pick<ImportOptions, 'between' | 'cardsBy'>,
): string | null {
  if (options.between.kind === 'custom' && options.between.text === '') {
    return 'Type what separates each term from its definition.';
  }
  if (options.cardsBy.kind === 'custom' && options.cardsBy.text === '') {
    return 'Type what separates one card from the next.';
  }
  if (termSeparatorText(options.between) === cardSeparatorText(options.cardsBy)) {
    return 'The two separators must be different.';
  }
  return null;
}

/**
 * An Anki header line: `#separator:tab`, `#html:true`, `#notetype column:1`.
 *
 * Narrower than "a line starting with #", on purpose. A card can begin with one -- `#1 fan`,
 * `#include<TAB>C preprocessor` -- and a rule that skipped every such line would drop it
 * without a word. A line that is not a header and has no separator is still shown as a
 * problem, so nothing a reader typed disappears either way.
 */
const ANKI_HEADER = /^#[a-z][a-z ]*:/i;

/** A spreadsheet's header row, which is not a card. */
const HEADER_ROW = /^(term|front|question|word)$/i;
const HEADER_ROW_2 = /^(definition|back|answer|meaning)$/i;

function normalise(text: string): string {
  return text.replace(/^\uFEFF/, '').replace(/\r\n?/g, '\n');
}

/** Anki's HTML, as text: a line break a line break, and every other tag gone. */
function ankiText(html: string): string {
  return html
    .replace(/<br\s*\/?>/gi, '\n')
    .replace(/<\/(?:div|p)>/gi, '\n')
    .replace(/<[^>]*>/g, '')
    .replace(/&nbsp;/g, ' ')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&amp;/g, '&');
}

/** A record of the source and where it began, before it is read as a card. */
interface RawRecord {
  fields: string[];
  where: string;
  text: string;
}

/**
 * Records split on the card separator, each split once, at its first term separator:
 * `ser, to be, permanently` is `ser` and `to be, permanently`, as Quizlet reads it.
 */
function plainRecords(text: string, options: ImportOptions, headers: { n: number }): RawRecord[] {
  const cardSep = cardSeparatorText(options.cardsBy);
  const termSep = termSeparatorText(options.between);
  const lines = options.cardsBy.kind === 'newline';
  const out: RawRecord[] = [];
  let card = 0;
  text.split(cardSep).forEach((raw, i) => {
    if (raw.trim() === '') return;
    if (lines && ANKI_HEADER.test(raw.trim())) {
      headers.n += 1;
      return;
    }
    card += 1;
    const where = lines ? `Line ${i + 1}` : `Card ${card}`;
    const at = termSep === '' ? -1 : raw.indexOf(termSep);
    out.push({
      fields: at < 0 ? [raw] : [raw.slice(0, at), raw.slice(at + termSep.length)],
      where,
      text: raw.trim(),
    });
  });
  return out;
}

/**
 * Comma-separated values, read the way a spreadsheet writes them: a field in double quotes
 * may hold commas, line breaks and `""` for a quote.
 *
 * The rule `parseCsvRecords` in `ingestion.ts` keeps, and for its reason: a quote opens a
 * quoted field only at the start of a field, so `6" of snow` is text rather than the start
 * of a field that swallows the rest of the file. That parser is not reused because this one
 * has to say where each record began, and skip Anki's header lines at the start of a record.
 *
 * AND A QUOTE THAT NEVER CLOSES IS TEXT. A field that opens with one and runs to the end of
 * the input would otherwise take every line after it into one card; instead the scan goes
 * back to that quote and reads it as a character, so one stray quote costs one card's
 * punctuation rather than the import.
 */
function csvRecords(text: string, headers: { n: number }): RawRecord[] {
  const out: RawRecord[] = [];
  let record: string[] = [];
  let field = '';
  let inQuotes = false;
  let atFieldStart = true;
  let line = 1;
  let recordLine = 1;
  let recordStart = 0;
  let literalQuote = -1;
  let opened: { at: number; record: string[]; line: number } | null = null;

  const endRecord = (end: number) => {
    record.push(field);
    const source = text.slice(recordStart, end);
    if (source.trim() !== '') {
      out.push({ fields: record, where: `Line ${recordLine}`, text: source.trim() });
    }
    record = [];
    field = '';
    atFieldStart = true;
  };

  for (let i = 0; i <= text.length; i += 1) {
    if (i === text.length) {
      if (inQuotes && opened) {
        // Back to the quote that never closed, to read it as a character.
        literalQuote = opened.at;
        i = opened.at - 1;
        record = opened.record;
        line = opened.line;
        field = '';
        inQuotes = false;
        atFieldStart = true;
        opened = null;
        continue;
      }
      if (field !== '' || record.length > 0) endRecord(i);
      break;
    }
    const ch = text[i] as string;
    if (inQuotes) {
      if (ch === '"') {
        if (text[i + 1] === '"') {
          field += '"';
          i += 1;
        } else {
          inQuotes = false;
          opened = null;
        }
      } else {
        if (ch === '\n') line += 1;
        field += ch;
      }
      continue;
    }
    if (atFieldStart && record.length === 0 && field === '') {
      recordStart = i;
      recordLine = line;
      const end = text.indexOf('\n', i);
      const rest = text.slice(i, end < 0 ? text.length : end);
      if (ANKI_HEADER.test(rest)) {
        headers.n += 1;
        if (end < 0) break;
        i = end;
        line += 1;
        continue;
      }
    }
    if (ch === '"' && atFieldStart && i !== literalQuote) {
      inQuotes = true;
      atFieldStart = false;
      opened = { at: i, record: [...record], line };
    } else if (ch === ',') {
      record.push(field);
      field = '';
      atFieldStart = true;
    } else if (ch === '\n') {
      endRecord(i);
      line += 1;
    } else {
      field += ch;
      atFieldStart = false;
    }
  }
  return out;
}

/**
 * Cards from pasted or opened text, with every line that did not make one and why.
 *
 * Comma between term and definition and a new line between cards is CSV, and read as CSV;
 * every other choice is split as typed. Surrounding whitespace comes off both sides.
 */
export function parseImport(input: string, options: ImportOptions): ImportResult {
  const limit = Math.max(0, options.limit ?? CARD_LIMIT);
  const headers = { n: 0 };
  const text = normalise(input);
  // Anki says when its fields are HTML, in a header; nothing else does.
  const html = /^#html:true$/im.test(text);

  const csv = options.between.kind === 'comma' && options.cardsBy.kind === 'newline';
  const records = csv ? csvRecords(text, headers) : plainRecords(text, options, headers);

  const cards: ImportedCard[] = [];
  const problems: ImportProblem[] = [];
  let over = 0;
  records.forEach((r, i) => {
    const fields = html ? r.fields.map(ankiText) : r.fields;
    if (fields.length < 2) {
      problems.push({
        where: r.where,
        text: r.text,
        reason: 'No separator between a term and a definition.',
      });
      return;
    }
    const term = (fields[0] as string).trim();
    // A CSV row with more than two fields is one definition with commas in it, unquoted.
    const definition = fields.slice(1).join(',').trim();
    if (i === 0 && HEADER_ROW.test(term) && HEADER_ROW_2.test(definition)) {
      headers.n += 1;
      return;
    }
    const reason = !term
      ? 'No term before the separator.'
      : !definition
        ? 'No definition after the separator.'
        : term.length > TERM_MAX
          ? `The term is over ${TERM_MAX.toLocaleString('en')} characters.`
          : definition.length > DEFINITION_MAX
            ? `The definition is over ${DEFINITION_MAX.toLocaleString('en')} characters.`
            : null;
    if (reason) {
      problems.push({ where: r.where, text: r.text, reason });
      return;
    }
    if (cards.length >= limit) {
      over += 1;
      return;
    }
    cards.push({ term, definition });
  });
  return { cards, problems, headers: headers.n, over };
}

/**
 * The separators a file most likely uses, from its name and -- for an Anki export -- the
 * header that says. A reader can change either before importing; this only saves them the
 * step when the file says what it is.
 */
export function guessSeparators(
  fileName: string,
  text: string,
): Pick<ImportOptions, 'between' | 'cardsBy'> {
  const cardsBy: CardSeparator = { kind: 'newline' };
  const anki = /^#separator:(.+)$/im.exec(normalise(text))?.[1]?.trim().toLowerCase();
  if (anki) {
    const between: TermSeparator =
      anki === 'tab'
        ? { kind: 'tab' }
        : anki === 'comma'
          ? { kind: 'comma' }
          : anki === 'semicolon'
            ? { kind: 'custom', text: ';' }
            : anki === 'pipe'
              ? { kind: 'custom', text: '|' }
              : anki === 'space'
                ? { kind: 'custom', text: ' ' }
                : { kind: 'tab' };
    return { between, cardsBy };
  }
  return { between: /\.csv$/i.test(fileName) ? { kind: 'comma' } : { kind: 'tab' }, cardsBy };
}

/* --------------------------------------------------------------------------
 * Out
 * -------------------------------------------------------------------------- */

/** A field on one line: a tab or line break inside it would be read as a separator. */
function oneLine(text: string): string {
  return text.replace(/\s*[\t\r\n]+\s*/g, ' ').trim();
}

/**
 * The set as `term<TAB>definition`, a card a line: what Quizlet's import and Anki's
 * "Import File" both read with their defaults, and what `parseImport` reads with ours.
 *
 * AS TYPED, WITH NO FORMULA DEFUSING. `export-formats.ts` prefixes a cell that begins with
 * `=`, `+`, `-` or `@` because its CSV is made for a spreadsheet, where that cell is a
 * formula. This file is made to be imported into a flashcard app, and offered as `.txt`
 * rather than `.csv`, so a spreadsheet does not open it by default; there, the prefix would
 * be a stray apostrophe on every chemistry answer (`+1`) and every card about an equation,
 * in the reader's own set, for ever. The text is theirs, and it goes back as they wrote it.
 */
export function toTsv(cards: readonly ImportedCard[]): string {
  return cards.map((c) => `${oneLine(c.term)}\t${oneLine(c.definition)}\n`).join('');
}

/** A file name from a set's title: its words, joined, and never empty. */
export function exportFileName(title: string): string {
  const slug = title
    .normalize('NFKD')
    .replace(/\p{M}/gu, '')
    .toLowerCase()
    .replace(/[^\p{L}\p{N}]+/gu, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 60)
    .replace(/-+$/g, '');
  return `${slug || 'flashcards'}.txt`;
}
