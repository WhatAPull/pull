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
 * NOTHING IS DROPPED WITHOUT SAYING SO. A blank line is nothing and is skipped, and so are
 * the header lines an Anki export begins with; every other line either becomes a card or is
 * listed as a problem with its line number, before anything is saved. A reader who pastes
 * two hundred lines and gets a hundred and ninety-eight cards is owed the two -- and one
 * whose file has columns past the second is told they were left out.
 */
import { CARD_LIMIT, DEFINITION_MAX, TERM_MAX, longerThan } from './flashcards.js';

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
  /** Cards read from a line with columns past the term and definition, which were left out. */
  extraColumns: number;
  /** Whether the text went on past `READ_LIMIT` records, which were not read. */
  unread: boolean;
  /** Null characters taken out of the text, which no set can hold (`normalise`). */
  nulls: number;
}

/**
 * How many records are read at most: ten for every card a set can hold, which is every card
 * and a problem between each besides. Eight megabytes of one-letter lines is four million
 * records, and reading them all took ten seconds with the tab frozen, to say that four
 * million lines were not cards.
 */
export const READ_LIMIT = CARD_LIMIT * 10;

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
 * Narrower than "a line starting with #", on purpose: the keys Anki writes, and only those.
 * A card can begin with one -- `#1 fan`, `#include<TAB>C preprocessor`, `#define: a macro` --
 * and a rule that skipped every such line would drop it without a word. A line that is not a
 * header and has no separator is still shown as a problem, so nothing a reader typed
 * disappears either way.
 */
const ANKI_HEADER =
  /^#(separator|html|tags|columns|notetype|deck|if matches|(?:guid|notetype|deck|tags) column):(.*)$/i;

/** The columns an Anki export adds beside a note's fields, which are not a card's sides. */
const ANKI_COLUMN = /^(guid|notetype|deck|tags) column$/;

/** A spreadsheet's header row, which is not a card. */
const HEADER_ROW = /^(term|front|question|word)$/i;
const HEADER_ROW_2 = /^(definition|back|answer|meaning)$/i;

/**
 * The text as it is read: no byte-order mark, every line ending a new line, and no null
 * characters. Postgres text cannot hold U+0000 -- a save with one was refused whole, as a raw
 * `22P05` -- and a file full of them is UTF-16 read as UTF-8, one after every letter, which
 * the preview showed as cards the save then refused. Taken out here, and counted, so the
 * preview says so; the file is read as UTF-16 in the first place when its mark says it is.
 */
function normalise(text: string): string {
  return text
    .replace(/^\uFEFF/, '')
    .replace(/\r\n?/g, '\n')
    .replaceAll('\u0000', '');
}

/**
 * A file's bytes as text: UTF-16 when it begins with UTF-16's byte-order mark -- what Excel
 * writes as "Unicode Text", and Notepad as "Unicode" -- and UTF-8 otherwise, as `File.text()`
 * reads everything. Read as UTF-8, such a file was two replacement characters and a null
 * after every letter; the preview listed its cards and the save refused them.
 */
export function decodeFileText(bytes: Uint8Array): string {
  if (bytes[0] === 0xff && bytes[1] === 0xfe) return new TextDecoder('utf-16le').decode(bytes);
  if (bytes[0] === 0xfe && bytes[1] === 0xff) return new TextDecoder('utf-16be').decode(bytes);
  return new TextDecoder('utf-8').decode(bytes);
}

/** How many null characters a text has, for the preview to say it took them out. */
function nullCount(text: string): number {
  let n = 0;
  for (let i = text.indexOf('\u0000'); i >= 0; i = text.indexOf('\u0000', i + 1)) n += 1;
  return n;
}

/**
 * What an Anki export says about itself, in the header lines it begins with -- and only
 * there. Read anywhere, a card whose term was `Term` or `#define: a macro` was taken for a
 * header and dropped, so a set downloaded here did not come back whole.
 */
interface AnkiHeader {
  /** How many lines the header is, blank ones among them included; the cards start after. */
  lines: number;
  /** How many of them were header lines. */
  count: number;
  html: boolean;
  separator: string | null;
  /** Anki's own columns -- guid, note type, deck, tags -- counted from 1, to take out. */
  drop: ReadonlySet<number>;
}

/** No header: what text not split into lines has, since Anki's is lines. */
const NO_HEADER: AnkiHeader = { lines: 0, count: 0, html: false, separator: null, drop: new Set() };

function ankiHeader(text: string): AnkiHeader {
  const drop = new Set<number>();
  let html = false;
  let separator: string | null = null;
  let lines = 0;
  let count = 0;
  for (const line of text.split('\n')) {
    const header = ANKI_HEADER.exec(line.trim());
    if (!header) {
      if (line.trim() !== '') break;
      lines += 1;
      continue;
    }
    lines += 1;
    count += 1;
    const key = (header[1] as string).toLowerCase();
    const value = (header[2] as string).trim();
    if (key === 'html') html = value.toLowerCase() === 'true';
    else if (key === 'separator') separator = value.toLowerCase();
    else if (ANKI_COLUMN.test(key) && /^[1-9]\d{0,2}$/.test(value)) drop.add(Number(value));
  }
  return { lines, count, html, separator, drop };
}

/**
 * Anki's HTML, as text: a line break a line break, and every other tag gone.
 *
 * A tag is read up to the next `<` at most, not to the next `>` wherever it is: a field of
 * forty thousand `<` and no `>` had each one searched to the end of the field, and a file of
 * them froze the tab for as long as it was quadratic.
 */
function ankiText(html: string): string {
  return html
    .replace(/<br\s*\/?>/gi, '\n')
    .replace(/<\/(?:div|p)>/gi, '\n')
    .replace(/<[^<>]*>/g, '')
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
  /** Which fields were in quotes: a quoted field is a column its writer meant. */
  quoted: boolean[];
  where: string;
  text: string;
}

/** The records read, and whether the text went on past `READ_LIMIT` of them. */
interface Records {
  records: RawRecord[];
  unread: boolean;
}

/**
 * Records split on the card separator, and each into its fields at every term separator.
 * `ser, to be, permanently` is three fields here; `cardSides` below joins the last two again,
 * as Quizlet reads it.
 */
function plainRecords(text: string, options: ImportOptions, skipLines: number): Records {
  const cardSep = cardSeparatorText(options.cardsBy);
  const termSep = termSeparatorText(options.between);
  const lines = options.cardsBy.kind === 'newline';
  const out: RawRecord[] = [];
  const parts = text.split(cardSep);
  for (let i = skipLines; i < parts.length; i += 1) {
    const raw = parts[i] as string;
    if (raw.trim() === '') continue;
    if (out.length === READ_LIMIT) return { records: out, unread: true };
    const where = lines ? `Line ${i + 1}` : `Card ${out.length + 1}`;
    const fields = termSep === '' ? [raw] : raw.split(termSep);
    out.push({ fields, quoted: fields.map(() => false), where, text: raw.trim() });
  }
  return { records: out, unread: false };
}

/**
 * Separated values, read the way a spreadsheet writes them -- and Anki too, which quotes a
 * field holding its separator, a quote or a line break the same way: a field in double quotes
 * may hold the separator, line breaks and `""` for a quote.
 *
 * The rule `parseCsvRecords` in `ingestion.ts` keeps, and for its reason: a quote opens a
 * quoted field only at the start of a field, so `6" of snow` is text rather than the start
 * of a field that swallows the rest of the file. That parser is not reused because this one
 * has to say where each record began, take any separator, and begin after Anki's header.
 *
 * AND A QUOTE THAT NEVER CLOSES IS TEXT. A field that opens with one and runs to the end of
 * the input would otherwise take every line after it into one card; instead the scan goes
 * back to that quote and reads it as a character, so one stray quote costs one card's
 * punctuation rather than the import. Where it opened and on which line is all it keeps: the
 * record so far cannot change inside quotes, so it is the same record when the scan comes
 * back. It once copied it at every quote that opened a field, and one line of `"",` forty
 * thousand times -- 120 KB -- took seven seconds to read.
 */
function quotedRecords(text: string, sep: string, skipLines: number): Records {
  const out: RawRecord[] = [];
  let record: string[] = [];
  let quoted: boolean[] = [];
  let field = '';
  let fieldQuoted = false;
  let inQuotes = false;
  let atFieldStart = true;
  let line = 1;
  let recordLine = 1;
  let recordStart = 0;
  let literalQuote = -1;
  let opened: { at: number; line: number } | null = null;

  // The header's lines are not records.
  let begin = 0;
  for (let n = 0; n < skipLines && begin <= text.length; n += 1) {
    const end = text.indexOf('\n', begin);
    begin = end < 0 ? text.length + 1 : end + 1;
    line += 1;
  }

  const endField = () => {
    record.push(field);
    quoted.push(fieldQuoted);
    field = '';
    fieldQuoted = false;
    atFieldStart = true;
  };
  const endRecord = (end: number) => {
    endField();
    const source = text.slice(recordStart, end);
    if (source.trim() !== '') {
      out.push({ fields: record, quoted, where: `Line ${recordLine}`, text: source.trim() });
    }
    record = [];
    quoted = [];
  };

  for (let i = begin; i <= text.length; i += 1) {
    if (out.length === READ_LIMIT && atFieldStart && record.length === 0) {
      // Past the limit, and at the start of a record: is there anything more to read?
      if (text.slice(i).trim() !== '') return { records: out, unread: true };
      break;
    }
    if (i === text.length) {
      if (inQuotes && opened) {
        // Back to the quote that never closed, to read it as a character. Nothing was added to
        // the record while it was open, so the record is as it was.
        literalQuote = opened.at;
        i = opened.at - 1;
        line = opened.line;
        field = '';
        fieldQuoted = false;
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
    }
    if (ch === '"' && atFieldStart && i !== literalQuote) {
      inQuotes = true;
      fieldQuoted = true;
      atFieldStart = false;
      opened = { at: i, line };
    } else if (sep !== '' && text.startsWith(sep, i)) {
      endField();
      i += sep.length - 1;
    } else if (ch === '\n') {
      endRecord(i);
      line += 1;
    } else {
      field += ch;
      atFieldStart = false;
    }
  }
  return { records: out, unread: false };
}

/**
 * A record's term and definition, from its fields -- or why it has none.
 *
 * Anki's own columns come out first. Empty fields at the end are a spreadsheet's empty
 * columns, not part of the definition: `dog,perro,,` is `perro`. Past two fields, the rest
 * is joined back into the definition only when none of it was quoted, the file is not
 * Anki's and the separator is typed text -- a comma, a dash or one of the reader's own:
 * `hacer, to do, to make`, split at its first separator as Quizlet splits it. A quoted
 * field, any field of an Anki export, and a field after a tab are columns their writer meant
 * -- nobody types a tab into a definition, and a spreadsheet's third column is a column --
 * and one past the definition is left out and counted, rather than read into it.
 */
function cardSides(
  record: RawRecord,
  sep: string,
  anki: AnkiHeader,
): { term: string; definition: string; extra: boolean } | null {
  const kept = record.fields.map((f, i) => ({ f, q: record.quoted[i] === true }));
  const fields = anki.drop.size > 0 ? kept.filter((_, i) => !anki.drop.has(i + 1)) : kept;
  while (fields.length > 2 && (fields[fields.length - 1] as { f: string }).f.trim() === '') {
    fields.pop();
  }
  const [term, definition, ...rest] = fields;
  if (!term || !definition) return null;
  const join =
    rest.length > 0 && sep !== '\t' && anki.count === 0 && !definition.q && rest.every((x) => !x.q);
  return {
    term: term.f,
    definition: join ? [definition, ...rest].map((x) => x.f).join(sep) : definition.f,
    extra: rest.length > 0 && !join,
  };
}

/**
 * Cards from pasted or opened text, with every line that did not make one and why.
 *
 * Comma between term and definition and a new line between cards is CSV, and read as CSV,
 * as is an Anki export whatever its separator; every other choice is split as typed.
 * Surrounding whitespace comes off both sides.
 */
export function parseImport(input: string, options: ImportOptions): ImportResult {
  const limit = Math.max(0, options.limit ?? CARD_LIMIT);
  const nulls = nullCount(input);
  const text = normalise(input);
  const lines = options.cardsBy.kind === 'newline';
  // Only a file of lines has Anki's header, and only at its start.
  const anki = lines ? ankiHeader(text) : NO_HEADER;
  const termSep = termSeparatorText(options.between);
  const quoteAware = lines && (options.between.kind === 'comma' || anki.count > 0);
  const { records, unread } = quoteAware
    ? quotedRecords(text, termSep, anki.lines)
    : plainRecords(text, options, anki.lines);

  const cards: ImportedCard[] = [];
  const problems: ImportProblem[] = [];
  let headers = anki.count;
  let over = 0;
  let extraColumns = 0;
  records.forEach((r, i) => {
    const sides = cardSides(
      anki.html ? { ...r, fields: r.fields.map(ankiText) } : r,
      termSep,
      anki,
    );
    if (!sides) {
      problems.push({
        where: r.where,
        text: r.text,
        reason: 'No separator between a term and a definition.',
      });
      return;
    }
    const term = sides.term.trim();
    const definition = sides.definition.trim();
    if (i === 0 && HEADER_ROW.test(term) && HEADER_ROW_2.test(definition)) {
      headers += 1;
      return;
    }
    const reason = !term
      ? 'No term before the separator.'
      : !definition
        ? 'No definition after the separator.'
        : longerThan(term, TERM_MAX)
          ? `The term is over ${TERM_MAX.toLocaleString('en')} characters.`
          : longerThan(definition, DEFINITION_MAX)
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
    if (sides.extra) extraColumns += 1;
    cards.push({ term, definition });
  });
  return { cards, problems, headers, over, extraColumns, unread, nulls };
}

/** The letters of the scripts written right to left: Arabic, Hebrew and their neighbours. */
const RIGHT_TO_LEFT =
  /[\p{Script=Arabic}\p{Script=Hebrew}\p{Script=Syriac}\p{Script=Thaana}\p{Script=Nko}\p{Script=Samaritan}\p{Script=Mandaic}\p{Script=Adlam}\p{Script=Hanifi_Rohingya}]/u;

/** How far into a text `leadingDirection` looks for its first letter. */
const DIRECTION_SAMPLE = 400;

/**
 * The direction a text is written in, from its first letter -- what `dir="auto"` works out --
 * found in its first few hundred characters and no further.
 *
 * FOR THE IMPORT BOX, WHICH CANNOT HAVE `dir="auto"`. Given it, the browser weighed the whole
 * of what was pasted, and again as the box was drawn: a paste of a megabyte held the page for
 * fourteen seconds, one of eight never came back to say it was more than a set holds, and the
 * 8 MB limit was no limit. A list's direction is its first line's, which is here.
 */
export function leadingDirection(text: string): 'ltr' | 'rtl' {
  const first = /\p{L}/u.exec(text.slice(0, DIRECTION_SAMPLE));
  return first && RIGHT_TO_LEFT.test(first[0]) ? 'rtl' : 'ltr';
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
  const anki = ankiHeader(normalise(text)).separator;
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

/**
 * A field on one line: a tab or line break inside it would be read as a separator.
 *
 * Split and joined rather than replaced by one pattern: `\s*[\t\r\n]+\s*` retries its
 * leading `\s*` from every space of a long run, and a card of 2,000 spaces between two
 * letters took the whole download to twelve seconds.
 */
function oneLine(text: string): string {
  return text
    .split(/[\t\r\n]+/)
    .map((part) => part.trim())
    .filter(Boolean)
    .join(' ');
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
