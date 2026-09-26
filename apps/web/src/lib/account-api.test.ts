/**
 * The export walk, which had no test at all until it lost somebody's history.
 *
 * `buildAccountExport` pages every table a reader owns and writes them into one file.
 * A round-3 change moved it from offset paging to keyset paging — correctly, because
 * an offset is unstable under concurrent writes — and guarded the cursor with
 * `typeof cursor !== 'string'`. `history_events.id` and `feed_impressions.id` are
 * `bigint`, which PostgREST serialises as a JSON number, so the guard threw on the
 * second page of either. `data[table] = rows` sits after the loop inside the same
 * `try`, so the table did not truncate: it vanished, including the rows already
 * fetched. Every reader with more than 100 history events lost all of it.
 *
 * The module builds a Supabase client at import, so the client is mocked rather than
 * the network. What is exercised is the walk itself: the cursor, the page boundary
 * and where rows end up.
 */
import { beforeEach, describe, expect, it, vi } from 'vitest';

/** Rows the fake serves, by table. Set per test. */
const TABLES = new Map<string, Record<string, unknown>[]>();
/** The page size each table was last asked for, so a test can pin one. */
const LIMITS = new Map<string, number>();

vi.mock('./supabase.js', () => {
  /** Enough of PostgREST's builder to run the walk: chainable, and awaitable. */
  const builder = (table: string) => {
    const keys: string[] = [];
    let after: (string | number)[] | null = null;
    let limit = 100;
    const self = {
      select: () => self,
      eq: () => self,
      order: (column: string) => {
        keys.push(column);
        return self;
      },
      // Only the one shape the walk sends for a pair key: `a.gt."x",and(a.eq."x",b.gt."y")`.
      or: (filter: string) => {
        const m = /^(\w+)\.gt\."([^"]*)",and\(\1\.eq\."\2",(\w+)\.gt\."([^"]*)"\)$/.exec(filter);
        if (!m) throw new Error(`the fake cannot read ${filter}`);
        after = [m[2] as string, m[4] as string];
        return self;
      },
      limit: (n: number) => {
        limit = n;
        LIMITS.set(table, n);
        return self;
      },
      gt: (_column: string, value: string) => {
        after = [value];
        return self;
      },
      then: (resolve: (r: { data: unknown[] | null; error: unknown }) => unknown): unknown => {
        const all = TABLES.get(table) ?? [];
        /*
         * Ordered and compared BY THE COLUMN'S OWN TYPE, which is the whole point.
         *
         * `.gt()` is evaluated server-side against a bigint column, so `101 > 100`.
         * The first version of this fake compared `String(id)`, where `"100" > "9"`
         * is false — the walk then re-served rows it had already yielded and the
         * assertion caught 1295 rows instead of 151. A fake that orders differently
         * from the database proves nothing about a cursor.
         */
        /*
         * The ROW's type decides, and the cursor is coerced into it — which is what
         * PostgREST does with a query-string value against a typed column, and the
         * only reason sending `String(bigint)` back as a cursor is correct at all.
         * Comparing the cursor as the string it arrives as put `"100" > "9"` at
         * false and made the walk re-serve pages it had already yielded.
         */
        const cmp = (a: unknown, b: unknown) => {
          if (typeof a === 'number') {
            const rhs = typeof b === 'number' ? b : Number(b);
            return Number.isNaN(rhs) ? 0 : a - rhs;
          }
          return String(a) < String(b) ? -1 : String(a) > String(b) ? 1 : 0;
        };
        const order = keys.length > 0 ? keys : ['id'];
        const byKeys = (x: Record<string, unknown>, y: unknown[]) => {
          for (const [i, k] of order.entries()) {
            const c = cmp(x[k], y[i]);
            if (c !== 0) return c;
          }
          return 0;
        };
        const sorted = [...all].sort((x, y) =>
          byKeys(
            x,
            order.map((k) => y[k]),
          ),
        );
        const from = after;
        const rest = from === null ? sorted : sorted.filter((r) => byKeys(r, from) > 0);
        return resolve({ data: rest.slice(0, limit), error: null });
      },
    };
    return self;
  };
  return { supabase: { from: (table: string) => builder(table) } };
});

const { buildAccountExport, isRecentSignInRequired, pairAfter } = await import('./account-api.js');
const { rpcError } = await import('./rpc-error.js');

/** `n` rows whose `id` is a JSON number, as PostgREST renders a bigint. */
const bigintRows = (n: number) =>
  Array.from({ length: n }, (_, i) => ({ id: i + 1, user_id: 'u1', kind: 'read' }));

/** `n` rows whose `id` is a uuid-shaped string, ordered. */
const uuidRows = (n: number) =>
  Array.from({ length: n }, (_, i) => ({
    id: `0000${String(i + 1).padStart(4, '0')}-0000-0000-0000-000000000000`,
    user_id: 'u1',
  }));

beforeEach(() => {
  TABLES.clear();
});

describe('buildAccountExport', () => {
  it('exports every page of a bigint-keyed table, not just the first', async () => {
    // 151 is the reviewer's measured case: two pages and a remainder, which is what
    // every reader with any history looks like.
    TABLES.set('history_events', bigintRows(151));

    const out = await buildAccountExport('u1', 'reader@example.com');

    expect(out.incomplete).toEqual([]);
    expect(out.data['history_events']).toHaveLength(151);
  });

  it('leaves nothing out of a table whose rows exactly fill a page', async () => {
    // The boundary: `got.length < PAGE` is false on the last full page, so the walk
    // asks once more and must terminate on the empty answer rather than loop.
    TABLES.set('history_events', bigintRows(200));

    const out = await buildAccountExport('u1', null);

    expect(out.data['history_events']).toHaveLength(200);
    expect(out.incomplete).toEqual([]);
  });

  it('still pages a uuid-keyed table', async () => {
    TABLES.set('notes', uuidRows(150));

    const out = await buildAccountExport('u1', null);

    expect(out.data['notes']).toHaveLength(150);
    expect(out.incomplete).toEqual([]);
  });

  it('records a table it cannot page rather than dropping it silently', async () => {
    // A key that is neither a string nor a number is a walk that cannot continue.
    // The table lands in `incomplete` with a reason, which is what the file promises
    // — the failure was doing that to a perfectly readable bigint.
    TABLES.set(
      'history_events',
      Array.from({ length: 150 }, () => ({ id: { nested: true }, user_id: 'u1' })),
    );

    const out = await buildAccountExport('u1', null);

    expect(out.incomplete.map((i) => i.table)).toContain('history_events');
  });

  it('includes the reader’s private source text and version history', async () => {
    TABLES.set('study_sources', [{ id: 'source-1', owner_id: 'u1' }]);
    TABLES.set('study_source_mutations', [
      { client_mutation_id: 'mutation-1', owner_id: 'u1', version_id: 'version-1' },
    ]);
    TABLES.set('study_url_preview_daily_usage', [
      { day_utc: '2026-09-24', owner_id: 'u1', preview_count: 2 },
    ]);
    TABLES.set('study_source_versions', [
      {
        id: 'version-1',
        source_id: 'source-1',
        owner_id: 'u1',
        extracted_text: 'My corrected note.',
      },
    ]);

    const out = await buildAccountExport('u1', null);

    expect(out.data['study_sources']).toHaveLength(1);
    expect(out.data['study_source_mutations']).toHaveLength(1);
    expect(out.data['study_url_preview_daily_usage']).toEqual([
      { day_utc: '2026-09-24', owner_id: 'u1', preview_count: 2 },
    ]);
    expect(out.data['study_source_versions']).toEqual([
      {
        id: 'version-1',
        source_id: 'source-1',
        owner_id: 'u1',
        extracted_text: 'My corrected note.',
      },
    ]);
  });
  it('includes what study generation derived from the reader’s material', async () => {
    TABLES.set('study_generations', [{ id: 'gen-1', owner_id: 'u1', goal: 'Explain it' }]);
    TABLES.set('study_claims', [{ id: 'claim-1', owner_id: 'u1', statement: 'A claim.' }]);
    TABLES.set('study_claim_evidence', [{ id: 'ev-1', owner_id: 'u1', span_text: 'A span.' }]);
    TABLES.set('study_items', [{ id: 'item-1', owner_id: 'u1', prompt: 'A question?' }]);

    const out = await buildAccountExport('u1', null);

    expect(out.data['study_generations']).toHaveLength(1);
    expect(out.data['study_claims']).toHaveLength(1);
    expect(out.data['study_claim_evidence']).toHaveLength(1);
    expect(out.data['study_items']).toHaveLength(1);
    for (const table of [
      'study_generation_access',
      'study_generation_sources',
      'study_stage_cache',
      'study_stage_cache_sources',
      'study_lessons',
      'study_lesson_claims',
      'study_item_claims',
      'study_reports',
      'study_status_log',
      'study_answer_events',
      'study_courses',
      'study_course_sources',
      'study_progress_events',
    ]) {
      expect(Object.keys(out.data)).toContain(table);
    }
    expect(out.incomplete).toEqual([]);
  });
  it('walks the cached model output in small pages and still takes every row', async () => {
    TABLES.set(
      'study_stage_cache',
      Array.from({ length: 25 }, (_, i) => ({
        id: `cache-${String(i).padStart(2, '0')}`,
        owner_id: 'u1',
      })),
    );

    const out = await buildAccountExport('u1', null);

    expect(out.data['study_stage_cache']).toHaveLength(25);
    expect(out.incomplete).toEqual([]);
    // Pinned: without `page: 10` the walk still takes every row, just in pages of a
    // hundred rows of up to 400 KB each, so the row count alone cannot tell.
    expect(LIMITS.get('study_stage_cache')).toBe(10);
    expect(LIMITS.get('study_claims')).toBe(100);
  });
  it('takes every step of a long path once, paging by path and step together', async () => {
    // 150 steps on one path and 30 on another: a cursor on `path_id` alone would stop
    // after the first page, every later step of that path sorting as "not after it".
    const steps = [
      ...Array.from({ length: 150 }, (_, i) => ({ path_id: 'path-a', ordinal: i + 1 })),
      ...Array.from({ length: 30 }, (_, i) => ({ path_id: 'path-b', ordinal: i + 1 })),
    ].map((s) => ({ ...s, user_id: 'u1', tested_out: false }));
    TABLES.set('path_step_done', steps);
    TABLES.set('path_progress', [
      { user_id: 'u1', path_id: 'path-a' },
      { user_id: 'u1', path_id: 'path-b' },
    ]);

    const out = await buildAccountExport('u1', null);

    const got = out.data['path_step_done'] as { path_id: string; ordinal: number }[];
    expect(got).toHaveLength(180);
    expect(new Set(got.map((s) => `${s.path_id}:${s.ordinal}`)).size).toBe(180);
    expect(out.data['path_progress']).toHaveLength(2);
    expect(out.incomplete).toEqual([]);
  });

  it('quotes a pair cursor so its value cannot be read as the filter’s syntax', () => {
    expect(pairAfter(['path_id', 'ordinal'], ['p', '7'])).toBe(
      'path_id.gt."p",and(path_id.eq."p",ordinal.gt."7")',
    );
    expect(pairAfter(['a', 'b'], ['x,y)"z', '1'])).toBe(
      'a.gt."x,y)\\"z",and(a.eq."x,y)\\"z",b.gt."1")',
    );
  });

  it('names every table it walked, so a missing one is visible in the file', async () => {
    const out = await buildAccountExport('u1', null);
    // Empty tables still appear as empty arrays. A table that vanished from `data`
    // is the shape of the defect this file was written for.
    expect(Object.keys(out.data)).toContain('history_events');
    expect(Object.keys(out.data)).toContain('feed_impressions');
    expect(Object.keys(out.data)).toContain('recall_events');
    // The privacy policy lists a reader's path progress among what is stored against them.
    expect(Object.keys(out.data)).toContain('path_progress');
    expect(Object.keys(out.data)).toContain('path_step_done');
  });
});

describe('isRecentSignInRequired', () => {
  it("knows the database's stale-sign-in refusal, and only that", () => {
    const refusal = rpcError({
      code: '28000',
      message: 'Deleting an account needs a recent sign-in.',
    });
    expect(isRecentSignInRequired(refusal)).toBe(true);
    expect(isRecentSignInRequired(rpcError({ code: '42501', message: 'denied' }))).toBe(false);
    expect(isRecentSignInRequired(new Error('offline'))).toBe(false);
    expect(isRecentSignInRequired('28000')).toBe(false);
  });
});
