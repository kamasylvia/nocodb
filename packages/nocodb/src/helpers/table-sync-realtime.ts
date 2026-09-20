import { Logger } from '@nestjs/common';
import { TableSyncStatus, TableSyncTrigger } from 'nocodb-sdk';
import type { NcContext } from '~/interface/config';
import { JobTypes } from '~/interface/Jobs';
import type { IJobsService } from '~/modules/jobs/jobs-service.interface';
import { MetaTable, RootScopes } from '~/utils/globals';
import Noco from '~/Noco';

// [CE-EE] F09 P3: realtime table-sync dispatch. BaseModelSqlv2's after*
// hooks tap into notifySourceChange() (fire-and-forget) whenever a SOURCE
// table of a realtime sync gains/changes/loses rows. The tap must be
// statically reachable — BaseModelSqlv2 has no NestJS DI — and importing
// TableSyncsService from BaseModelSqlv2 would create a value-level import
// cycle (service -> tables.service -> Model -> BaseModelSqlv2), so the
// implementation lives in this dependency-free helper and
// TableSyncsService.notifySourceChange delegates to it.
//
// The jobsService is resolved through the bootstrapped Nest application
// context (Noco.nestApp, stored by Noco.init). Before the app is up no
// data API can run, so the hook tap never fires in that window; the tap
// still try/catch-swallows everything (realtime must never break writes).

const logger = new Logger('TableSyncRealtime');

export type TableSyncChangeEvent =
  | 'insert'
  | 'update'
  | 'bulkUpdate'
  | 'delete'
  | 'bulkDelete'
  // [CE-EE] F09 P4: link-structure change — tapped from
  // BaseModelSqlv2.updateLastModified, which is the single funnel every
  // LTAR pair mutation goes through (relation manager add/remove child,
  // add-remove-links batch, nested insert/update, row delete touching
  // linked rows). Dispatched as a FULL resync per the P4 simplification
  // tier (junction pair recomputation runs in the full pass).
  | 'link';

/** [CE-EE] F09 P3: syncs whose event was skipped because the sync was
 *  Syncing at tap time. The processor checks this after each run and
 *  enqueues one watermark (empty affectedIds) catch-up job — otherwise a
 *  change landing mid-run would be lost until the next manual resync.
 *  In-memory by design: the CE fallback queue runs processors in the same
 *  process; multi-worker deployments only lose this catch-up nicety, not
 *  correctness of the queued job itself. */
const skippedDuringSync = new Set<string>();

export function markSkippedDuringSync(syncId: string) {
  skippedDuringSync.add(syncId);
}

export function consumeSkippedDuringSync(syncId: string): boolean {
  return skippedDuringSync.delete(syncId);
}

function getJobsService(): IJobsService | null {
  try {
    // Noco.nestApp is set in Noco.init before any route is served
    return Noco.nestApp?.get<IJobsService>('JobsService') ?? null;
  } catch {
    return null;
  }
}

type SyncTarget = {
  sync_id: string;
  workspace_id: string;
  base_id: string;
  created_by: string | null;
  /** [CE-EE] F09 P4: mapping role — 'main' syncs get incremental
   *  affectedIds runs, 'linked_shadow' syncs get full resyncs */
  role?: string;
  /** filled by the caller of claimAndEnqueue (loadRealtimeTargets callers
   *  know it; the catch-up path resolves it via the main mapping) */
  source_table_id?: string;
};

async function loadRealtimeTargets(
  sourceModelId: string,
): Promise<SyncTarget[]> {
  // one round trip: table mappings sourcing this table joined with their
  // sync row, filtered to realtime. [CE-EE] F09 P3-R1(lane1/2/4/5): NO
  // status filter here — a status='active' pre-filter made Syncing/paused
  // syncs invisible to the tap, so their events were silently dropped at
  // lookup and the CAS-miss → markSkipped → catch-up chain was unreachable.
  // All statuses flow through (the CAS claims only active runs; syncing/
  // paused claim-misses land in markSkippedDuringSync and the catch-up —
  // a full upsert+sweep pass — reconciles them on the next run/resume). Soft-deleted syncs hard-delete their mappings
  // (TableSync.delete), so no deleted filter is needed.
  // [CE-EE] F09 P4: role IN (main, linked_shadow) — main mappings feed
  // the main mirror (incremental affectedIds), linked_shadow mappings feed
  // shadow tables (full resync). Junction mappings carry no source_table_id
  // (their writes are raw-knex and never tap), so they can never match.
  return (await Noco.ncMeta
    .knex(MetaTable.TABLE_SYNC_MAPPINGS)
    .join(
      MetaTable.TABLE_SYNCS,
      `${MetaTable.TABLE_SYNCS}.id`,
      `${MetaTable.TABLE_SYNC_MAPPINGS}.fk_table_sync_id`,
    )
    .where({
      [`${MetaTable.TABLE_SYNC_MAPPINGS}.source_table_id`]: sourceModelId,
      [`${MetaTable.TABLE_SYNCS}.sync_trigger`]: TableSyncTrigger.Realtime,
    })
    .whereIn(`${MetaTable.TABLE_SYNC_MAPPINGS}.role`, ['main', 'linked_shadow'])
    .select(
      `${MetaTable.TABLE_SYNCS}.id as sync_id`,
      `${MetaTable.TABLE_SYNCS}.fk_workspace_id as workspace_id`,
      `${MetaTable.TABLE_SYNCS}.base_id as base_id`,
      `${MetaTable.TABLE_SYNCS}.created_by as created_by`,
      `${MetaTable.TABLE_SYNC_MAPPINGS}.role as role`,
    )) as SyncTarget[];
}

/** Claim the sync for exactly one queued run (atomic CAS on status) and
 *  enqueue the job. `affectedIds` null = no ids known — for 'incremental'
 *  mode the processor falls back to the full pass (upsert + disappearance
 *  sweep); for 'full-resync' mode (P4 link/shadow events) the whole sync
 *  including shadow + junction layers is recomputed.
 *  Returns the job id, or null when the claim missed (sync not active —
 *  the event is marked for catch-up instead). */
async function claimAndEnqueue(
  target: SyncTarget,
  affectedIds: string[] | null,
  // [CE-EE] F09 P4: main scalar events keep 'incremental'; link events and
  // linked_shadow targets dispatch a full resync (simplification tier)
  mode: 'incremental' | 'full-resync' = 'incremental',
): Promise<string | null> {
  const jobsService = getJobsService();
  if (!jobsService) {
    logger.warn(
      `Table sync realtime event dropped: jobs service unavailable`,
    );
    return null;
  }

  // claim the sync atomically: UPDATE ... WHERE status='active' — a
  // concurrent/queued run flips status to 'syncing' and this claim misses,
  // which is the documented "skip while Syncing, catch up afterwards" path
  const claimed = await Noco.ncMeta
    .knex(MetaTable.TABLE_SYNCS)
    .where({ id: target.sync_id, status: TableSyncStatus.Active })
    .update({ status: TableSyncStatus.Syncing });
  if (!claimed) {
    // [CE-EE] F09 P3-R2(lane2/R1 M3): claim misses were silent — a debug
    // line makes the skip -> catch-up chain observable in the logs
    logger.debug(
      `Table sync ${target.sync_id}: claim missed (syncing/paused) — marked for catch-up`,
    );
    return null;
  }

  try {
    const job = await jobsService.add(JobTypes.TableSyncRun, {
      context: {
        workspace_id: target.workspace_id,
        base_id: target.base_id,
      },
      user: { id: target.created_by ?? undefined },
      syncId: target.sync_id,
      mode,
      ...(affectedIds
        ? { affectedIdsBySource: { [target.source_table_id]: affectedIds } }
        : {}),
      // minimal req shim (audit attribution only) — passing the live
      // request through the queue would serialize the whole object
      req: { user: { id: target.created_by } } as any,
    });

    await Noco.ncMeta
      .knex(MetaTable.TABLE_SYNCS)
      .where({ id: target.sync_id })
      .update({ sync_job_id: String(job?.id || '') });

    return String(job?.id || '');
  } catch (e) {
    // release the claim so the sync does not stay stuck in 'syncing'
    await Noco.ncMeta
      .knex(MetaTable.TABLE_SYNCS)
      .where({ id: target.sync_id })
      .update({ status: TableSyncStatus.Active });
    logger.warn(
      `Table sync ${target.sync_id}: incremental enqueue failed: ${e?.message}`,
    );
    return null;
  }
}

/** [CE-EE] F09 P3: entry point for the BaseModelSqlv2 after* taps. Finds
 *  every active realtime sync whose main mapping sources the touched table
 *  and enqueues one incremental job per sync (affectedIdsBySource = the
 *  touched row ids). Fire-and-forget from the caller — this function still
 *  catches its own errors so a sync problem can never fail the write. */
export async function notifySourceChange(
  sourceContext: NcContext,
  sourceModelId: string,
  event: TableSyncChangeEvent,
  rowIds: (string | number)[],
): Promise<void> {
  try {
    if (!sourceModelId || !rowIds?.length) return;

    const targets = await loadRealtimeTargets(sourceModelId);
    if (!targets.length) return;

    const ids = rowIds.map((id) => String(id)).filter(Boolean);
    if (!ids.length) return;

    for (const target of targets) {
      // [CE-EE] F09 P4: main scalar events stay incremental (affectedIds
      // by pk); link events (junction pair changes) and linked_shadow
      // targets dispatch a full resync — the full pass recomputes the
      // shadow tables and junction RemoteId pairings
      const isLinkEvent = event === 'link';
      const isShadowTarget = target.role === 'linked_shadow';
      const mode: 'incremental' | 'full-resync' =
        isLinkEvent || isShadowTarget ? 'full-resync' : 'incremental';

      const jobId = await claimAndEnqueue(
        // the CAS needs the source table id for affectedIdsBySource
        { ...target, source_table_id: sourceModelId },
        !isLinkEvent && !isShadowTarget ? ids : null,
        mode,
      );
      if (jobId === null) {
        markSkippedDuringSync(target.sync_id);
      } else {
        logger.debug(
          `Table sync ${target.sync_id}: enqueued ${mode} run ${jobId} (${event}, ${ids.length} ids)`,
        );
      }
    }
  } catch (e) {
    logger.warn(
      `Table sync realtime dispatch failed for ${sourceModelId} (${event}): ${e?.message}`,
    );
  }
}

/** [CE-EE] F09 P3: fire-and-forget wrapper used by the BaseModelSqlv2 taps —
 *  never throws, never awaited on the write path. */
export function tapTableSyncRealtime(
  context: NcContext,
  modelId: string,
  event: TableSyncChangeEvent,
  rowIds: (string | number)[],
): void {
  // no .catch needed: notifySourceChange catches everything internally
  void notifySourceChange(
    context || { workspace_id: RootScopes.ROOT, base_id: RootScopes.ROOT },
    modelId,
    event,
    rowIds,
  );
}

/** [CE-EE] F09 P3: called by the processor after a run completes — when
 *  realtime events were skipped while this sync was Syncing, enqueue one
 *  watermark catch-up job (empty affectedIds). */
export async function enqueueCatchUpIfNeeded(syncId: string): Promise<void> {
  try {
    if (!syncId || !consumeSkippedDuringSync(syncId)) return;

    const row = (await Noco.ncMeta
      .knex(MetaTable.TABLE_SYNCS)
      .where({ id: syncId })
      .first()) as any;
    if (!row) return;

    const jobId = await claimAndEnqueue(
      {
        sync_id: row.id,
        workspace_id: row.fk_workspace_id,
        base_id: row.base_id,
        created_by: row.created_by,
        source_table_id: await getSyncSourceTableId(row.id),
      },
      null,
    );
    if (jobId) {
      logger.debug(
        `Table sync ${row.id}: enqueued watermark catch-up run ${jobId}`,
      );
    } else {
      // claim missed (sync not active — error/paused) or the enqueue failed:
      // keep the marker so a later run can still catch up
      markSkippedDuringSync(row.id);
    }
  } catch (e) {
    // keep the marker — the catch-up is retried after a later run
    markSkippedDuringSync(syncId);
    logger.warn(
      `Table sync ${syncId}: catch-up enqueue failed: ${e?.message}`,
    );
  }
}

// kept local to avoid importing the TableSync model here (the helper must
// stay dependency-free for the BaseModelSqlv2 tap)
async function getSyncSourceTableId(syncId: string): Promise<string> {
  const mapping = (await Noco.ncMeta
    .knex(MetaTable.TABLE_SYNC_MAPPINGS)
    .where({ fk_table_sync_id: syncId, role: 'main' })
    .first()) as any;
  return mapping?.source_table_id;
}


