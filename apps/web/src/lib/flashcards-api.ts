/**
 * The flashcard calls, wrapped once so the two screens read them the same way.
 *
 * Reads are plain selects under RLS, which is the whole of what makes a set private: the
 * policy answers only the reader's own rows. Writes go through the two functions the
 * database offers and nothing else. No model is involved anywhere (law 2).
 *
 * EVERY READ IS PAGED. The API answers at most 100 rows whatever a request asks
 * (`max_rows` in supabase/config.toml), and that holds inside an embed as well -- measured:
 * `flashcard_sets?select=*,flashcards(*)` on a set of 150 cards returned 100 of them, with
 * nothing to say the rest existed. A set can hold 2,000 cards and a reader 500 sets, so a
 * single request would silently study, export and cache a fraction of either.
 */
import {
  shapeSet,
  shapeSetSummaries,
  type FlashcardSet,
  type FlashcardSetSummary,
  type SavePayload,
} from './flashcards.js';
import { rpcError } from './rpc-error.js';
import { supabase } from './supabase.js';

/** What the API answers at most per request. */
const PAGE = 100;

/** A set id's shape. Anything else is no set, not a request for Postgres to refuse. */
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** Pages after the first, in parallel: the first says how many there are. */
function laterPages(count: number): number[] {
  return Array.from({ length: Math.max(0, Math.ceil(count / PAGE) - 1) }, (_, i) => (i + 1) * PAGE);
}

/** The reader's sets, most recently changed first, each with its number of cards. */
export async function fetchSets(signal?: AbortSignal): Promise<FlashcardSetSummary[]> {
  const page = (from: number, counted: boolean) => {
    const request = supabase
      .from('flashcard_sets')
      .select('id, title, description, updated_at, flashcards(count)', {
        count: counted ? 'exact' : undefined,
      })
      .order('updated_at', { ascending: false })
      .order('id', { ascending: true })
      .range(from, from + PAGE - 1);
    return signal ? request.abortSignal(signal) : request;
  };
  const first = await page(0, true);
  if (first.error) throw rpcError(first.error);
  const rest = await Promise.all(laterPages(first.count ?? 0).map((from) => page(from, false)));
  const failed = rest.find((r) => r.error);
  if (failed?.error) throw rpcError(failed.error);
  // A set saved between two pages can appear on both; it is listed once.
  const seen = new Set<string>();
  return [first, ...rest]
    .flatMap((r) => shapeSetSummaries(r.data))
    .filter((s) => !seen.has(s.id) && seen.add(s.id) !== undefined);
}

/**
 * One set with every card, or null when the address names no set of the reader's -- one
 * that does not exist, was deleted, or is somebody else's, which RLS makes the same thing.
 *
 * The cards come in pages by position, in parallel. A save landing between the pages
 * could hand back half of one version and half of the next, so the set's `updated_at` is
 * read again after them, and a set that moved is read again from the start.
 */
export async function fetchSet(setId: string, signal?: AbortSignal): Promise<FlashcardSet | null> {
  if (!UUID.test(setId)) return null;
  const abortable = <T extends { abortSignal: (s: AbortSignal) => T }>(q: T): T =>
    signal ? q.abortSignal(signal) : q;
  for (let attempt = 0; attempt < 3; attempt += 1) {
    const head = await abortable(
      supabase
        .from('flashcard_sets')
        .select('id, title, description, term_lang, definition_lang, updated_at, flashcards(count)')
        .eq('id', setId),
    );
    if (head.error) throw rpcError(head.error);
    const row = head.data?.[0];
    if (!row) return null;
    const count = row.flashcards[0]?.count ?? 0;
    const pages = await Promise.all(
      [0, ...laterPages(count)].map((from) =>
        abortable(
          supabase
            .from('flashcards')
            .select('id, term, definition, position')
            .eq('set_id', setId)
            .order('position', { ascending: true })
            .range(from, from + PAGE - 1),
        ),
      ),
    );
    const failed = pages.find((p) => p.error);
    if (failed?.error) throw rpcError(failed.error);
    const cards = pages.flatMap((p) => p.data ?? []);
    const again = await abortable(
      supabase.from('flashcard_sets').select('updated_at').eq('id', setId),
    );
    if (again.error) throw rpcError(again.error);
    const now = again.data?.[0];
    if (!now) return null;
    if (now.updated_at === row.updated_at && cards.length === count) return shapeSet(row, cards);
  }
  throw new Error('This set kept changing while it was being read. Try again.');
}

export interface SavedSet {
  id: string;
  updatedAt: string;
}

/** Create or replace the reader's set; the payload's ids are the ones it keeps. */
export async function saveSet(payload: SavePayload): Promise<SavedSet> {
  const { data, error } = await supabase.rpc('save_flashcard_set', {
    p_set: { ...payload, cards: payload.cards.map((c) => ({ ...c })) },
  });
  if (error) throw rpcError(error);
  const out = (data ?? {}) as { id?: unknown; updatedAt?: unknown };
  return {
    id: typeof out.id === 'string' ? out.id : payload.id,
    updatedAt: typeof out.updatedAt === 'string' ? out.updatedAt : new Date().toISOString(),
  };
}

/** Delete the reader's set and its cards. False when there was no such set of theirs. */
export async function deleteSet(setId: string): Promise<boolean> {
  const { data, error } = await supabase.rpc('delete_flashcard_set', { p_id: setId });
  if (error) throw rpcError(error);
  return data === true;
}
