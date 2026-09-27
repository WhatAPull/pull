/**
 * The list of a reader's sources, on the request it actually sends. One bounded read of 100
 * versions lists every source because the server holds a reader to 100 versions -- of their
 * own. A public course's excerpts are not counted there (20260925230000), so a reader can
 * have their 100 and twenty courses' excerpts besides: read with them, the newest excerpts
 * crowded the reader's own oldest sources out of the list, and listed text that is the
 * course's as the reader's own.
 */
import { beforeEach, describe, expect, it, vi } from 'vitest';

type Row = Record<string, unknown>;

let ROWS: Row[] = [];
const calls: { method: string; args: unknown[] }[] = [];

vi.mock('./supabase.js', () => {
  /** Enough of PostgREST's builder to run the read, applying what it asks for. */
  const builder = () => {
    let rows = [...ROWS];
    const self = {
      select: (...args: unknown[]) => {
        calls.push({ method: 'select', args });
        return self;
      },
      eq: (column: string, value: unknown) => {
        calls.push({ method: 'eq', args: [column, value] });
        rows = rows.filter((r) => r[column] === value);
        return self;
      },
      neq: (column: string, value: unknown) => {
        calls.push({ method: 'neq', args: [column, value] });
        rows = rows.filter((r) => r[column] !== value);
        return self;
      },
      order: (column: string, options: { ascending: boolean }) => {
        calls.push({ method: 'order', args: [column, options] });
        rows.sort((a, b) =>
          String(a[column]) < String(b[column])
            ? -1
            : String(a[column]) > String(b[column])
              ? 1
              : 0,
        );
        if (!options.ascending) rows.reverse();
        return self;
      },
      limit: (n: number) => {
        calls.push({ method: 'limit', args: [n] });
        rows = rows.slice(0, n);
        return self;
      },
      then: (resolve: (r: { data: Row[]; error: null }) => unknown) =>
        resolve({ data: rows, error: null }),
    };
    return self;
  };
  return { supabase: { from: () => builder() } };
});

const { fetchStudySources } = await import('./study-source-api.js');

const at = (minute: number) => new Date(Date.UTC(2026, 8, 1, 0, minute)).toISOString();

beforeEach(() => {
  ROWS = [];
  calls.length = 0;
});

describe('fetchStudySources', () => {
  it('lists every one of the reader’s 100 sources, and no public course’s excerpts', async () => {
    // A hundred sources of the reader's own, then twenty public courses' excerpts, newer.
    ROWS = [
      ...Array.from({ length: 100 }, (_, i) => ({
        id: `v${i}`,
        source_id: `s${i}`,
        version_no: 1,
        title: `Mine ${i}`,
        format: 'paste',
        origin_label: null,
        extraction_notes: null,
        created_at: at(i),
        owner_id: 'u1',
      })),
      ...Array.from({ length: 20 }, (_, i) => ({
        id: `x${i}`,
        source_id: `e${i}`,
        version_no: 1,
        title: `Excerpts: work ${i}`,
        format: 'public_course',
        origin_label: `public_course:p${i}`,
        extraction_notes: null,
        created_at: at(200 + i),
        owner_id: 'u1',
      })),
    ];

    const sources = await fetchStudySources('u1');

    expect(sources).toHaveLength(100);
    expect(sources.some((s) => s.format === ('public_course' as string))).toBe(false);
    expect(sources.map((s) => s.sourceId)).toContain('s0');
    expect(calls).toContainEqual({ method: 'neq', args: ['format', 'public_course'] });
    expect(calls).toContainEqual({ method: 'limit', args: [100] });
  });
});
