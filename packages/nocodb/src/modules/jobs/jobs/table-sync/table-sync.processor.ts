import { Injectable, Logger } from '@nestjs/common';
import { Job } from 'bull';
import { TableSyncStatus } from 'nocodb-sdk';
import type { NcContext, NcRequest } from '~/interface/config';
import type { TableSyncJobData } from '~/interface/Jobs';
import Model from '~/models/Model';
import Source from '~/models/Source';
import TableSync from '~/models/TableSync';
import NcConnectionMgrv2 from '~/utils/common/NcConnectionMgrv2';
import type { BaseModelSqlv2 } from '~/db/BaseModelSqlv2';
import type { Column } from '~/models';
import { ColumnsService } from '~/services/columns.service';
// [CE-EE] F09 P3: post-run catch-up of realtime events
// that were skipped while a run was in flight
import { enqueueCatchUpIfNeeded } from '~/helpers/table-sync-realtime';

// [CE-EE] F09: Table Sync engine. One job run applies a full copy of the
// source table onto the mirror table:
//   - rows are matched by the engine-managed RemoteId column (the source row's
//     primary key) — new RemoteIds insert, existing ones update, and source
//     rows that disappeared are deleted (on_delete_action=delete) or flagged
//     via RemoteDeleted (on_delete_action=mark_deleted);
//   - writes go through the allowSystemColumn whitelist channel of the synced
//     destination table (bulkInsert/bulkUpdate/bulkDelete with
//     allowSystemColumn + the trusted-internal-copy flags). Regular users
//     keep hitting the synced read-only guard chain — the whitelist is never
//     reachable over HTTP.
// P1 scope: full-create (initial) and full-resync ("Sync now"). P3 adds the
// incremental mode: affectedIdsBySource pulls the touched source rows by pk
// (missing rows follow on_delete_action); an incremental run with no ids
// without touched ids falls back to the full pass (upsert + sweep) and skips the
// disappearance sweep — a partial pull must never sweep unobserved rows.

const SYNC_PAGE_SIZE = 500;

/** [CE-EE] F09: BaseModelSqlv2.list() returns a bare row array — tolerate a
 *  {list} envelope too, in case the wrapper shape changes upstream. */
function normalizeListResult(result: any): Record<string, any>[] {
  if (Array.isArray(result)) return result;
  return result?.list || [];
}

@Injectable()
export class TableSyncProcessor {
  private logger = new Logger(TableSyncProcessor.name);

  // [CE-EE] F09 P2: sanctioned synced-column authority path — source type
  // drift is propagated through columnUpdate with bypassSyncedFieldGuard
  // (the engine is the authority per columns.service's own comment)
  constructor(private readonly columnsService: ColumnsService) {}

  async job(job: Job) {
    // [CE-EE] F09: mode decides the pull shape — full-create/full-resync run
    // the full RemoteId-keyed upsert pass; incremental runs either the
    // affectedIds-by-pk pass (realtime taps) or the full-pass catch-up (catch-up), skipping the disappearance sweep
    const { syncId, req } = job.data as TableSyncJobData;

    // resolve the sync row without a base-bound context — the row itself
    // carries workspace/base ids (jobs run cross-base by definition)
    const sync = await TableSync.getAny(syncId);
    if (!sync) {
      this.logger.warn(`Table sync ${syncId} no longer exists — skipping`);
      return;
    }
    if (sync.status === TableSyncStatus.Paused) {
      this.logger.warn(`Table sync ${syncId} is paused — skipping run`);
      return;
    }

    const context: NcContext = {
      workspace_id: sync.fk_workspace_id,
      base_id: sync.base_id,
    };

    try {
      await this.applyFullSync(context, sync, req, job.data as TableSyncJobData);
      await TableSync.update(context, sync.base_id, syncId, {
        status: TableSyncStatus.Active,
        last_error: null,
        last_synced_at: new Date().toISOString(),
        sync_job_id: null,
      });
    } catch (e) {
      this.logger.error(`Table sync ${syncId} run failed: ${e?.message}`);
      await TableSync.update(context, sync.base_id, syncId, {
        status: TableSyncStatus.Error,
        last_error: e?.message || String(e),
        sync_job_id: null,
      });
      // swallow: the sync row carries the failure (status + last_error);
      // rethrowing would trigger queue-level retries against a half-written
      // mirror with no additional information
    }

    // [CE-EE] F09 P3: realtime events that arrived while this run held the
    // sync are not lost — one full-pass catch-up run re-pulls them
    await enqueueCatchUpIfNeeded(syncId);
  }

  private async applyFullSync(
    context: NcContext,
    sync: TableSync,
    req: NcRequest,
    // [CE-EE] F09 P3: incremental runs carry affectedIdsBySource (realtime
    // taps) or none (full-pass catch-up)
    jobData?: TableSyncJobData,
  ) {
    const mainMapping = await TableSync.getMainMapping(
      context,
      sync.base_id,
      sync.id,
    );
    if (!mainMapping) {
      throw new Error(
        'Main mapping is missing for this table sync (irrecoverable state)',
      );
    }

    const sourceContext: NcContext = {
      workspace_id: mainMapping.source_workspace_id,
      base_id: mainMapping.source_base_id,
    };

    const srcModel = await Model.get(sourceContext, mainMapping.source_table_id);
    if (!srcModel || srcModel.deleted) {
      throw new Error(
        'Source table has been deleted — delete this sync and recreate it',
      );
    }
    await srcModel.getColumns(sourceContext);

    const destModel = await Model.get(context, mainMapping.dest_table_id);
    if (!destModel || destModel.deleted) {
      throw new Error('Mirror table has been deleted');
    }
    await destModel.getColumns(context);

    const srcBaseModel = await this.getBaseModel(sourceContext, srcModel);
    const destBaseModel = await this.getBaseModel(context, destModel);

    // column identity: source col id → dest col id (titles may drift apart
    // post-mapping; ids are the stable join)
    const columnMappings = await TableSync.listColumnMappings(
      context,
      sync.base_id,
      sync.id,
    );
    const srcColById = new Map<string, Column>(
      srcModel.columns.map((c) => [c.id, c as Column]),
    );
    const destColById = new Map<string, Column>(
      destModel.columns.map((c) => [c.id, c as Column]),
    );
    const fieldMap = columnMappings
      .map(({ source_column_id, dest_column_id }) => ({
        srcId: source_column_id,
        destId: dest_column_id,
        srcTitle: srcColById.get(source_column_id)?.title,
        destTitle: destColById.get(dest_column_id)?.title,
      }))
      .filter((m) => !!m.srcTitle && !!m.destTitle);

    // [CE-EE] F09 P2: source column type drift propagation — when the source
    // column's type changed since mapping, carry the change onto the mirror
    // column through the bypass guard, then refresh the dest model meta
    for (const m of fieldMap) {
      const srcCol = srcColById.get(m.srcId);
      const destCol = destColById.get(m.destId);
      if (!srcCol || !destCol) continue;
      if (srcCol.uidt === destCol.uidt && srcCol.dt === destCol.dt) continue;
      try {
        // [CE-EE] F09 P2-R3(lane4 M-2): capture the pre-change type for the
        // log BEFORE mutation — logging after assignment printed new→new
        const oldType = destCol.dt || destCol.uidt;
        await this.columnsService.columnUpdate(context, {
          req,
          columnId: destCol.id,
          user: req?.user as any,
          bypassSyncedFieldGuard: true,
          column: {
            uidt: srcCol.uidt,
            dt: srcCol.dt,
          } as any,
        });
        destCol.uidt = srcCol.uidt;
        destCol.dt = srcCol.dt;
        this.logger.log(
          `Table sync ${sync.id}: propagated column type change ${destCol.title}: ${oldType} -> ${srcCol.uidt}`,
        );
      } catch (e) {
        this.logger.warn(
          `Table sync ${sync.id}: column type propagation failed for ${destCol.title}: ${e?.message}`,
        );
      }
    }

    const remoteIdCol = destModel.columns.find((c) => c.title === 'RemoteId');
    const remoteDeletedCol = destModel.columns.find(
      (c) => c.title === 'RemoteDeleted',
    );
    const destPkCol = destModel.columns.find((c) => c.pk);
    if (!remoteIdCol || !destPkCol) {
      throw new Error('Mirror table is missing the RemoteId / pk system column');
    }
    const pkKey = destPkCol.title;

    const selectedFields: string[] | null = sync.selected_fields;
    const fields = selectedFields
      ? fieldMap.filter(
          (m) => selectedFields.includes(m.srcTitle) || selectedFields.includes(m.destTitle),
        )
      : fieldMap;

    const markDeleted = sync.on_delete_action === 'mark_deleted';

    // [CE-EE] F09: the engine-only whitelist channel — these flags never
    // reach the HTTP layer, so the synced read-only guards stay intact for
    // every regular caller
    const engineWriteParams = {
      cookie: req,
      allowSystemColumn: true,
      skip_hooks: true,
      skipPermissionCheck: true,
      skipAttachmentOwnershipCheck: true,
    } as const;

    // [CE-EE] F09 P3: pull shape — incremental runs with touched row ids pull
    // those rows by pk; incremental runs without ids (catch-up) run a full
    // upsert pass WITHOUT the disappearance sweep; everything else stays the
    // full pass
    const isIncremental = jobData?.mode === 'incremental';
    const affectedIds =
      isIncremental && jobData?.affectedIdsBySource
        ? (jobData.affectedIdsBySource[mainMapping.source_table_id] ?? [])
        : null;

    // shared: build the mirror payload for one source row
    const buildRowPayload = (row: Record<string, any>) => {
      const remoteId = String(srcBaseModel.extractPksValues(row, true) ?? '');
      if (!remoteId) return null;
      const payload: Record<string, any> = {};
      for (const { srcTitle, destTitle } of fields) {
        const v = row[srcTitle];
        payload[destTitle] = v === undefined ? null : v;
      }
      payload[remoteIdCol.title] = remoteId;
      return { remoteId, payload };
    };

    // shared: locate the mirror row keyed by RemoteId (partial pulls look up
    // per row instead of scanning the whole mirror)
    const findDestRowByRemoteId = async (remoteId: string) =>
      normalizeListResult(
        await destBaseModel.list(
          {
            limit: 1,
            where: `(RemoteId,eq,${remoteId})`,
          } as any,
          { ignoreViewFilterAndSort: true, ignoreRls: true } as any,
        ),
      )[0];

    // shared: apply the on_delete policy to a mirror row whose source row is
    // gone (delete event, or a partial pull that can no longer see the row)
    const applyDeletePolicy = async (remoteId: string) => {
      const destRow = await findDestRowByRemoteId(remoteId);
      if (!destRow) return;
      if (markDeleted && remoteDeletedCol) {
        pendingUpdates.push({
          [pkKey]: destRow[pkKey],
          [remoteDeletedCol.title]: true,
        });
      } else {
        pendingDeletes.push({ [pkKey]: destRow[pkKey] });
      }
    };

    // shared: upsert one pulled source row
    const upsertSourceRow = async (row: Record<string, any>) => {
      const built = buildRowPayload(row);
      if (!built) return;
      const { remoteId, payload } = built;
      const destRow = await findDestRowByRemoteId(remoteId);
      if (destRow) {
        payload[pkKey] = destRow[pkKey];
        if (remoteDeletedCol && markDeleted) {
          payload[remoteDeletedCol.title] = false;
        }
        pendingUpdates.push(payload);
      } else {
        if (remoteDeletedCol) {
          payload[remoteDeletedCol.title] = false;
        }
        pendingInserts.push(payload);
      }
    };

    const pendingInserts: Record<string, any>[] = [];
    const pendingUpdates: Record<string, any>[] = [];
    const pendingDeletes: Record<string, any>[] = [];
    const seenRemoteIds = new Set<string>();

    if (isIncremental && affectedIds?.length) {
      // realtime path: pull exactly the touched source rows; ids the source
      // can no longer return (deleted / soft-deleted / filtered) follow the
      // on_delete policy
      for (const id of affectedIds) {
        const srcRow = await srcBaseModel.readByPk(
          id,
          false,
          {},
          { ignoreView: true, ignoreRls: true } as any,
        );
        if (srcRow) {
          await upsertSourceRow(srcRow);
        } else {
          await applyDeletePolicy(String(id));
        }
      }
    } else {
      // [CE-EE] F09 P3-R2(lane4 E1'): incremental runs WITHOUT touched ids
      // (catch-up) fall through to the FULL pass — upsert plus disappearance
      // sweep. The previous no-sweep catch-up could not see in-window DELETE
      // events (a deleted source row is simply absent from the pull, and
      // without a sweep its mirror row survived as a live ghost). A full
      // pull observes every row, so the sweep is safe and required here.
      // Full pass: scan the existing mirror once, then upsert the whole
      // source and sweep rows that disappeared
      const existingByRemoteId = new Map<string, Record<string, any>>();
      {
        let offset = 0;
        for (;;) {
          const rows = normalizeListResult(
            await destBaseModel.list(
              { limit: SYNC_PAGE_SIZE, offset } as any,
              { ignoreViewFilterAndSort: true, ignoreRls: true } as any,
            ),
          );
          for (const row of rows) {
            if (row[remoteIdCol.title] != null) {
              existingByRemoteId.set(String(row[remoteIdCol.title]), row);
            }
          }
          if (rows.length < SYNC_PAGE_SIZE) break;
          offset += SYNC_PAGE_SIZE;
        }
      }

      let offset = 0;
      for (;;) {
        const rows = normalizeListResult(
          await srcBaseModel.list(
            { limit: SYNC_PAGE_SIZE, offset } as any,
            { ignoreViewFilterAndSort: true, ignoreRls: true } as any,
          ),
        );

        for (const row of rows) {
          const remoteId = String(
            srcBaseModel.extractPksValues(row, true) ?? '',
          );
          if (!remoteId || seenRemoteIds.has(remoteId)) continue;
          seenRemoteIds.add(remoteId);

          const payload: Record<string, any> = {};
          for (const { srcTitle, destTitle } of fields) {
            const v = row[srcTitle];
            payload[destTitle] = v === undefined ? null : v;
          }
          payload[remoteIdCol.title] = remoteId;

          const existing = existingByRemoteId.get(remoteId);
          if (existing) {
            // matched: refresh values (+ clear a stale RemoteDeleted flag when
            // the source row reappeared under mark_deleted policy)
            payload[pkKey] = existing[pkKey];
            if (remoteDeletedCol && markDeleted) {
              payload[remoteDeletedCol.title] = false;
            }
            pendingUpdates.push(payload);
          } else {
            if (remoteDeletedCol) {
              payload[remoteDeletedCol.title] = false;
            }
            pendingInserts.push(payload);
          }
        }

        if (rows.length < SYNC_PAGE_SIZE) break;
        offset += SYNC_PAGE_SIZE;
      }

      // disappearance sweep — only meaningful once rows have been mirrored
      if (existingByRemoteId.size) {
        const stale = [...existingByRemoteId.entries()].filter(
          ([remoteId]) => !seenRemoteIds.has(remoteId),
        );
        for (const [remoteId, row] of stale) {
          if (markDeleted && remoteDeletedCol) {
            pendingUpdates.push({
              [pkKey]: row[pkKey],
              [remoteDeletedCol.title]: true,
            });
          } else {
            pendingDeletes.push({ [pkKey]: row[pkKey] });
          }
        }
      }
    }

    this.logger.log(
      `Table sync ${sync.id} [${jobData?.mode || 'full'}]: source rows=${seenRemoteIds.size} inserts=${pendingInserts.length} updates=${pendingUpdates.length} deletes=${pendingDeletes.length}`,
    );

    // flush in chunks to bound memory on large mirrors
    const CHUNK = 200;
    for (let i = 0; i < pendingInserts.length; i += CHUNK) {
      await destBaseModel.bulkInsert(pendingInserts.slice(i, i + CHUNK), {
        ...engineWriteParams,
        chunkSize: 50,
        typecast: true,
      });
    }
    for (let i = 0; i < pendingUpdates.length; i += CHUNK) {
      await destBaseModel.bulkUpdate(pendingUpdates.slice(i, i + CHUNK), {
        cookie: req,
        allowSystemColumn: true,
        skip_hooks: true,
        typecast: true,
      });
    }
    for (let i = 0; i < pendingDeletes.length; i += CHUNK) {
      await destBaseModel.bulkDelete(pendingDeletes.slice(i, i + CHUNK), {
        cookie: req,
        allowSystemColumn: true,
      });
    }
  }

  private async getBaseModel(
    context: NcContext,
    model: Model,
  ): Promise<BaseModelSqlv2> {
    const source = await Source.get(context, model.source_id);
    const dbDriver = await NcConnectionMgrv2.get(source);
    return Model.getBaseModelSQL(context, {
      model,
      source,
      dbDriver,
    }) as Promise<BaseModelSqlv2>;
  }
}
