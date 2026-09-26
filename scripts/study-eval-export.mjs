import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { connection } from './study-beta-report.mjs';

/*
 * Export a study generation run in the shape `scripts/study-eval.mjs` reads.
 *
 * The point is the ledger gate. `study-eval.mjs` certifies ledger completeness only
 * against a provider-attempt inventory that was NOT reconstructed from the attempts or
 * the ledger (docs/eval/study-quality.md). Here the two come from different writers:
 *
 *   providerAttemptIds   `provider_calls`, written by the transport BEFORE each request
 *   attempts, ledger     `cost_ledger`, written by the accounting AFTER each request
 *
 * A ledger row with no journal id (the step-level fallback for a recording that failed)
 * is exported as an attempt of its own, which cannot match the inventory, so the gate
 * fails -- correctly, because per-attempt accounting did fail for that step.
 *
 * Human judgements are not in the database. They come from a reviews file, keyed by item
 * id, and an item without one is exported unreviewed, which the evaluator counts against
 * release readiness.
 *
 * Usage:
 *   node scripts/study-eval-export.mjs --manifest m.json [--reviews r.json] --jobs id,id,...
 *
 * The manifest names each fixture source by the exact set of version ids its course was
 * generated from, with its rights and categories:
 *   { "sources": [{ "id": "qualified-trial", "versionIds": ["..."], "rights": "self-authored",
 *                   "categories": ["notes", "qualified"] }] }
 *
 * Reads with `psql` against DATABASE_URL (the local stack by default; the hosted database's
 * owner URL for a release gate, docs/study-beta.md). It exports ids, statuses and costs --
 * never source text, and never a reader's answers. psql is run as the beta report runs it
 * (`connection`): the password in its environment, never its arguments, so no error it prints
 * carries it; no ~/.psqlrc, whose `\timing` line would not parse as JSON; none of the
 * operator's PG* variables; and TLS asked for off loopback. Every aggregate is ordered, so
 * exporting the same run again writes the same file, and the same digest.
 */

function sameSet(a, b) {
  return a.length === b.length && [...a].sort().join(',') === [...b].sort().join(',');
}

/** Pure: rows in, evaluator input out. Exported for the test. */
export function buildStudyEvalRun({ manifest, generations, items, calls, ledger, reviews = {} }) {
  const sources = manifest?.sources;
  if (!Array.isArray(sources) || sources.length === 0) {
    throw new Error('the manifest needs a nonempty sources array');
  }

  const sourceOfJob = new Map();
  const sourceOfGeneration = new Map();
  for (const generation of generations) {
    const source = sources.find((s) => sameSet(s.versionIds ?? [], generation.versionIds));
    if (!source) {
      throw new Error(
        `generation ${generation.generationId} (job ${generation.jobId}) matches no manifest source`,
      );
    }
    sourceOfJob.set(generation.jobId, source.id);
    sourceOfGeneration.set(generation.generationId, source.id);
  }

  const attempts = [];
  const ledgerRows = [];
  for (const row of ledger) {
    const sourceId = sourceOfJob.get(row.jobId);
    if (!sourceId) continue;
    const attemptId = row.providerCallId ?? `ledger-${row.id}`;
    attempts.push({ id: attemptId, sourceId, stage: row.step });
    ledgerRows.push({ attemptId, costCents: Number(row.costCents) });
  }

  const providerAttemptIds = calls.filter((c) => sourceOfJob.has(c.jobId)).map((c) => c.id);

  /*
   * What made the run, and when: the pipelines its preparations were made with -- prompt,
   * schema and model for each stage, the extraction's as each claim recorded it and the
   * assembly's as each generation did -- and the last of them to be saved. A release gate is
   * for one pipeline, and as fresh as its run: a generation whose claims were extracted two
   * ways was made by two pipelines, and says so.
   */
  const stage = (p) => ({
    promptHash: p?.promptHash ?? null,
    schemaHash: p?.schemaHash ?? null,
    model: p?.model ?? null,
  });
  const pipelines = [];
  let ranAt = null;
  for (const generation of generations) {
    if (generation.provenance) {
      const extractions = generation.extraction?.length ? generation.extraction : [null];
      for (const extraction of extractions) {
        const pipeline = { extract: stage(extraction), assemble: stage(generation.provenance) };
        if (!pipelines.some((q) => JSON.stringify(q) === JSON.stringify(pipeline))) {
          pipelines.push(pipeline);
        }
      }
    }
    if (generation.assembledAt && (ranAt === null || generation.assembledAt > ranAt)) {
      ranAt = generation.assembledAt;
    }
  }

  /*
   * What the validator decided, which is what the gate measures. A question validation
   * passed reached learners -- even if it was reported and suspended since, or retired --
   * so it is visible; one it quarantined, or one malformed at generation (`rejected`), is
   * reviewed as quarantined. A reader's own version is not the model's output and is left
   * out, as is a draft that never finished validation. `decided` is the status the
   * `validation` row of `study_status_log` recorded; without one, the current status.
   */
  const decision = (item) => {
    if (item.authoredBy === 'reader') return null;
    if (item.status === 'rejected') return 'quarantined';
    const decided = item.decided ?? item.status;
    return decided === 'validated' ? 'visible' : decided === 'quarantined' ? 'quarantined' : null;
  };
  const exportedItems = items
    .filter((item) => sourceOfGeneration.has(item.generationId) && decision(item))
    .map((item) => {
      const review = reviews[item.id] ?? {};
      return {
        id: item.id,
        sourceId: sourceOfGeneration.get(item.generationId),
        status: decision(item),
        adversarial: review.adversarial === true,
        reviewers: Array.isArray(review.reviewers) ? review.reviewers : [],
        ...(review.adjudicated ? { adjudicated: review.adjudicated } : {}),
      };
    });

  return {
    sources: sources.map(({ id, rights, categories }) => ({ id, rights, categories })),
    items: exportedItems,
    attempts,
    ledger: ledgerRows,
    providerAttemptIds,
    pipelines,
    ranAt,
  };
}

function psqlJson(psql, sql) {
  let out;
  try {
    out = execFileSync('psql', [...psql.args, '-v', 'ON_ERROR_STOP=1', '-Atq', '-c', sql], {
      encoding: 'utf8',
      maxBuffer: 64 * 1024 * 1024,
      env: psql.env,
      stdio: ['ignore', 'pipe', 'pipe'],
    }).trim();
  } catch (e) {
    const said =
      String(e.stderr ?? '')
        .trim()
        .split('\n')[0] || e.message;
    throw new Error(`the database refused or could not be reached: ${said}`);
  }
  return JSON.parse(out || '[]');
}

function argument(name) {
  const at = process.argv.indexOf(name);
  return at === -1 ? undefined : process.argv[at + 1];
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const manifestPath = argument('--manifest');
  const jobList = argument('--jobs');
  if (!manifestPath || !jobList) {
    process.stderr.write(
      'Usage: node scripts/study-eval-export.mjs --manifest m.json [--reviews r.json] --jobs id,id\n',
    );
    process.exit(2);
  }
  let psql;
  try {
    psql = connection(
      process.env.DATABASE_URL ?? 'postgresql://postgres:postgres@127.0.0.1:54322/postgres',
      process.env,
    );
  } catch (e) {
    process.stderr.write(`study-eval-export: ${e.message}\n`);
    process.exit(2);
  }
  const jobs = jobList.split(',').map((j) => j.trim());
  if (!jobs.every((j) => /^[0-9a-f-]{36}$/.test(j))) {
    throw new Error('--jobs takes comma-separated job uuids');
  }
  const inList = jobs.map((j) => `'${j}'`).join(',');
  const manifest = JSON.parse(readFileSync(manifestPath, 'utf8'));
  const reviewsPath = argument('--reviews');
  const reviews = reviewsPath ? JSON.parse(readFileSync(reviewsPath, 'utf8')) : {};

  let run;
  try {
    run = exportRun(psql, manifest, reviews, inList);
  } catch (e) {
    process.stderr.write(`study-eval-export: ${e.message}\n`);
    process.exit(3);
  }
  process.stdout.write(JSON.stringify(run, null, 2) + '\n');
}

function exportRun(psql, manifest, reviews, inList) {
  return buildStudyEvalRun({
    manifest,
    reviews,
    generations: psqlJson(
      psql,
      `
      select coalesce(json_agg(json_build_object(
        'generationId', g.id, 'jobId', g.job_id,
        'provenance', g.assembly_provenance,
        'extraction', (select coalesce(jsonb_agg(distinct jsonb_build_object(
                         'promptHash', c.prompt_hash, 'schemaHash', c.schema_hash,
                         'model', c.model)), '[]')
                       from public.study_claims c where c.generation_id = g.id),
        -- UTC, so the lexical comparison above is a comparison of times.
        'assembledAt', to_char(g.assembled_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
        'versionIds', (select json_agg(s.source_version_id order by s.position)
                       from public.study_generation_sources s where s.generation_id = g.id))
        order by g.id), '[]')
      from public.study_generations g where g.job_id in (${inList});`,
    ),
    items: psqlJson(
      psql,
      `
      select coalesce(json_agg(json_build_object(
        'id', i.id, 'generationId', i.generation_id, 'status', i.status,
        'authoredBy', i.authored_by,
        'decided', (select l.to_status from public.study_status_log l
                    where l.item_id = i.id and l.reason = 'validation'
                    order by l.at desc, l.id desc limit 1))
        order by i.id), '[]')
      from public.study_items i join public.study_generations g on g.id = i.generation_id
      where g.job_id in (${inList});`,
    ),
    calls: psqlJson(
      psql,
      `
      select coalesce(json_agg(json_build_object('id', pc.id, 'jobId', pc.job_id)
        order by pc.id), '[]')
      from public.provider_calls pc where pc.job_id in (${inList});`,
    ),
    ledger: psqlJson(
      psql,
      `
      select coalesce(json_agg(json_build_object(
        'id', cl.id, 'jobId', cl.job_id, 'step', cl.operation,
        'providerCallId', cl.provider_call_id, 'costCents', cl.cost_cents)
        order by cl.id), '[]')
      from public.cost_ledger cl where cl.job_id in (${inList});`,
    ),
  });
}
