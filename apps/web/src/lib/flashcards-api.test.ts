/**
 * The flashcard calls, against a fake PostgREST that pages as the real one does -- at most
 * 100 rows a request, whatever is asked -- and lets a test change the rows between two
 * requests, which is where every paging bug here lived.
 *
 * The module builds a Supabase client at import, so the client is mocked rather than the
 * network. What is exercised is the calls themselves: the paging, the cursor, the order the
 * list is shown in, whether it says it is complete, the re-read of a set that moved, and
 * what a save sends.
 */
import { beforeEach, describe, expect, it, vi } from 'vitest';

type Row = Record<string, unknown>;

/** The rows the fake serves, by table. Set per test. */
const TABLES = new Map<string, Row[]>();
/** Every request made, in order: its table and what it asked for. */
const REQUESTS: { table: string; gt: string | null; counted: boolean; range: number[] | null }[] =
  [];
/** Run before each request is answered, so a test can change the rows mid-read. */
let beforeAnswer: (n: number) => void = () => undefined;
/** What the two functions answer. */
let RPC: (name: string, args: Row) => { data: unknown; error: unknown } = () => ({
  data: null,
  error: null,
});
const RPC_CALLS: { name: string; args: Row }[] = [];

vi.mock('./supabase.js', () => {
  const builder = (table: string) => {
    const eq: [string, unknown][] = [];
    let gt: [string, string] | null = null;
    let order: string | null = null;
    let limit = 100;
    let range: [number, number] | null = null;
    let counted = false;
    let embedCount = false;
    const self = {
      select: (columns: string, options?: { count?: string; head?: boolean }) => {
        counted = options?.count === 'exact';
        embedCount = columns.includes('flashcards(count)');
        return self;
      },
      eq: (column: string, value: unknown) => {
        eq.push([column, value]);
        return self;
      },
      gt: (column: string, value: string) => {
        gt = [column, value];
        return self;
      },
      order: (column: string) => {
        order = column;
        return self;
      },
      limit: (n: number) => {
        limit = n;
        return self;
      },
      range: (from: number, to: number) => {
        range = [from, to];
        return self;
      },
      abortSignal: () => self,
      then: (resolve: (r: { data: Row[]; error: null; count: number | null }) => unknown) => {
        REQUESTS.push({ table, gt: gt?.[1] ?? null, counted, range });
        beforeAnswer(REQUESTS.length);
        const matching = (TABLES.get(table) ?? []).filter((r) => eq.every(([c, v]) => r[c] === v));
        const after = gt;
        const sorted = [...matching]
          .filter((r) => after === null || String(r[after[0]]) > after[1])
          .sort((a, b) => {
            if (order === null) return 0;
            const x = a[order] as string | number;
            const y = b[order] as string | number;
            return x < y ? -1 : x > y ? 1 : 0;
          });
        // `max_rows`: never more than 100, whatever the request asked for.
        const page = (range ? sorted.slice(range[0], range[1] + 1) : sorted.slice(0, limit)).slice(
          0,
          100,
        );
        const cards = TABLES.get('flashcards') ?? [];
        const data = page.map((r) =>
          embedCount
            ? { ...r, flashcards: [{ count: cards.filter((c) => c.set_id === r.id).length }] }
            : { ...r },
        );
        return resolve({ data, error: null, count: counted ? matching.length : null });
      },
    };
    return self;
  };
  return {
    supabase: {
      from: (table: string) => builder(table),
      rpc: (name: string, args: Row) => {
        RPC_CALLS.push({ name, args });
        return Promise.resolve(RPC(name, args));
      },
    },
  };
});

const { deleteSet, fetchSet, fetchSets, saveSet } = await import('./flashcards-api.js');
const { sqlDetail, sqlState } = await import('./rpc-error.js');

/** A uuid-shaped id whose text sorts by `n`. */
const uuid = (n: number, prefix = '0000') =>
  `${prefix}${String(n).padStart(4, '0')}-0000-4000-8000-000000000000`;

/** `n` sets, the later-numbered changed more recently. */
const sets = (n: number) =>
  Array.from({ length: n }, (_, i) => ({
    id: uuid(i + 1),
    title: `Set ${i + 1}`,
    description: null,
    term_lang: null,
    definition_lang: null,
    updated_at: `2026-09-${String(1 + (i % 28)).padStart(2, '0')}T10:00:00.${String(i).padStart(6, '0')}+00:00`,
  }));

beforeEach(() => {
  TABLES.clear();
  REQUESTS.length = 0;
  RPC_CALLS.length = 0;
  beforeAnswer = () => undefined;
});

describe('fetchSets', () => {
  it('reads every page by id and lists the sets most recently changed first', async () => {
    TABLES.set('flashcard_sets', sets(250));
    const { sets: list, complete } = await fetchSets();
    expect(list).toHaveLength(250);
    expect(complete).toBe(true);
    // Three pages, each after the last id of the one before; the first counts, and so does
    // a request after the last.
    expect(REQUESTS.map((r) => [r.gt, r.counted])).toEqual([
      [null, true],
      [uuid(100), false],
      [uuid(200), false],
      [null, true],
    ]);
    const times = list.map((s) => s.updatedAt);
    expect(times).toEqual([...times].sort().reverse());
    expect(list[0]?.cardCount).toBe(0);
  });

  it('stops at a page that is exactly full, on the empty one after it', async () => {
    TABLES.set('flashcard_sets', sets(200));
    const { sets: list, complete } = await fetchSets();
    expect(list).toHaveLength(200);
    expect(complete).toBe(true);
    expect(REQUESTS).toHaveLength(4);
  });

  it('keeps a set saved while the later pages are read -- it moves in time, not in id', async () => {
    TABLES.set('flashcard_sets', sets(250));
    // After the first page, set 150 is saved: the most recent of all now.
    beforeAnswer = (n) => {
      if (n !== 2) return;
      const row = TABLES.get('flashcard_sets')?.find((r) => r.id === uuid(150));
      if (row) row.updated_at = '2026-10-01T00:00:00+00:00';
    };
    const { sets: list, complete } = await fetchSets();
    expect(list).toHaveLength(250);
    expect(complete).toBe(true);
    expect(list[0]?.id).toBe(uuid(150));
    expect(new Set(list.map((s) => s.id)).size).toBe(250);
  });

  it('says it is not complete when a set is made or deleted while it reads', async () => {
    TABLES.set('flashcard_sets', sets(150));
    beforeAnswer = (n) => {
      if (n === 2) TABLES.get('flashcard_sets')?.splice(120, 1);
    };
    expect((await fetchSets()).complete).toBe(false);

    TABLES.set('flashcard_sets', sets(150));
    REQUESTS.length = 0;
    beforeAnswer = (n) => {
      // A set made on another screen, whose id sorts after the cursor: read, but not counted.
      if (n === 2) TABLES.get('flashcard_sets')?.push({ ...sets(1)[0], id: uuid(1, '0000a') });
    };
    const { sets: list, complete } = await fetchSets();
    expect(list).toHaveLength(151);
    expect(complete).toBe(false);
  });

  it('says it is not complete when a set is made behind the pages already read', async () => {
    TABLES.set('flashcard_sets', sets(150));
    beforeAnswer = (n) => {
      // After the first page: an id that sorts before its cursor, so it is never read, and the
      // first count was taken without it. Only the count after the last page sees it.
      if (n === 2) TABLES.get('flashcard_sets')?.push({ ...sets(1)[0], id: uuid(0) });
    };
    const { sets: list, complete } = await fetchSets();
    expect(list).toHaveLength(150);
    expect(list.map((s) => s.id)).not.toContain(uuid(0));
    expect(complete).toBe(false);
  });
});

describe('fetchSet', () => {
  const setId = uuid(7);
  const withCards = (n: number) => {
    TABLES.set('flashcard_sets', [{ ...sets(7)[6], id: setId, term_lang: 'es' }]);
    TABLES.set(
      'flashcards',
      Array.from({ length: n }, (_, i) => ({
        id: uuid(i, 'c000'),
        set_id: setId,
        term: `t${i}`,
        definition: `d${i}`,
        // Stored out of order: the pages come by position, whatever order rows are in.
        position: n - 1 - i,
      })),
    );
  };

  it('is null for an id that is not a uuid, without asking', async () => {
    expect(await fetchSet('not-a-set')).toBeNull();
    expect(await fetchSet(`${setId}'; drop`)).toBeNull();
    expect(REQUESTS).toEqual([]);
  });

  it('reads every card in pages by position, and the set around them', async () => {
    withCards(250);
    const set = await fetchSet(setId);
    expect(set?.cards).toHaveLength(250);
    expect(set?.cards[0]?.term).toBe('t249');
    expect(set?.cards[249]?.term).toBe('t0');
    expect(set?.termLang).toBe('es');
    const pages = REQUESTS.filter((r) => r.table === 'flashcards').map((r) => r.range);
    expect(pages).toEqual([
      [0, 99],
      [100, 199],
      [200, 299],
    ]);
  });

  it('reads a set again from the start when it changed while it was read', async () => {
    withCards(5);
    beforeAnswer = (n) => {
      // Between the cards and the second look at the time, on the first attempt only.
      if (n === 3) {
        const row = TABLES.get('flashcard_sets')?.[0];
        if (row) row.updated_at = '2026-10-01T00:00:00+00:00';
        TABLES.get('flashcards')?.pop();
      }
    };
    const set = await fetchSet(setId);
    expect(set?.cards).toHaveLength(4);
    expect(set?.updatedAt).toBe('2026-10-01T00:00:00+00:00');
    expect(REQUESTS.filter((r) => r.table === 'flashcard_sets')).toHaveLength(4);
  });

  it('gives up, in words, on a set that keeps changing', async () => {
    withCards(3);
    let tick = 0;
    beforeAnswer = () => {
      const row = TABLES.get('flashcard_sets')?.[0];
      if (row) row.updated_at = `2026-10-01T00:00:00.${String((tick += 1)).padStart(6, '0')}+00:00`;
    };
    await expect(fetchSet(setId)).rejects.toThrow(/kept changing/);
  });

  it('is null for a set that is not there, or went while it was read', async () => {
    TABLES.set('flashcard_sets', []);
    expect(await fetchSet(setId)).toBeNull();
    withCards(2);
    beforeAnswer = (n) => {
      if (n === 3) TABLES.set('flashcard_sets', []);
    };
    REQUESTS.length = 0;
    expect(await fetchSet(setId)).toBeNull();
  });
});

describe('saveSet', () => {
  const payload = {
    id: uuid(9),
    baseUpdatedAt: '2026-09-26T10:00:00.123456+00:00',
    title: 'Verbs',
    description: null,
    termLang: 'es',
    definitionLang: null,
    cards: [{ id: uuid(1, 'c000'), term: 'ser', definition: 'to be' }],
  };

  it('sends the set as it is, the base time included to the microsecond', async () => {
    RPC = () => ({
      data: { id: payload.id, updatedAt: '2026-09-26T11:00:00.5+00:00' },
      error: null,
    });
    expect(await saveSet(payload)).toEqual({
      id: payload.id,
      updatedAt: '2026-09-26T11:00:00.5+00:00',
    });
    expect(RPC_CALLS).toEqual([{ name: 'save_flashcard_set', args: { p_set: payload } }]);
  });

  it('falls back to what it sent when the answer is not the shape it expects', async () => {
    RPC = () => ({ data: null, error: null });
    const out = await saveSet(payload);
    expect(out.id).toBe(payload.id);
    expect(Number.isNaN(Date.parse(out.updatedAt))).toBe(false);
  });

  it('keeps the refusal’s SQLSTATE and DETAIL, which the editor turns into words', async () => {
    RPC = () => ({
      data: null,
      error: { code: '40001', details: 'changed', message: 'the set has changed' },
    });
    const refused = await saveSet(payload).catch((e: unknown) => e);
    expect(sqlState(refused)).toBe('40001');
    expect(sqlDetail(refused)).toBe('changed');
  });
});

describe('deleteSet', () => {
  it('says whether a set went', async () => {
    RPC = () => ({ data: true, error: null });
    expect(await deleteSet(uuid(1))).toBe(true);
    RPC = () => ({ data: false, error: null });
    expect(await deleteSet(uuid(1))).toBe(false);
    expect(RPC_CALLS.map((c) => c.args)).toEqual([{ p_id: uuid(1) }, { p_id: uuid(1) }]);
  });
});
