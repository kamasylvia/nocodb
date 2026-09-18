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
// P1 scope: full-create (initial) and full-resync ("Sync now") only. Both run
// the same upsert pass; incremental/realtime are later phases.

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
    // [CE-EE] F09: mode is informational in P1 — both full-create and
    // full-resync run the same RemoteId-keyed upsert pass; only the create
    // call site differs (fresh mirror, nothing to sweep)
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
      await this.applyFullSync(context, sync, req);
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
  }

  private async applyFullSync(
    context: NcContext,
    sync: TableSync,
    req: NcRequest,
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

    // existing mirror rows by RemoteId → { id, values } for upsert matching
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

    const selectedFields: string[] | null = sync.selected_fields;
    const fields = selectedFields
      ? fieldMap.filter(
          (m) => selectedFields.includes(m.srcTitle) || selectedFields.includes(m.destTitle),
        )
      : fieldMap;

    const inserts: Record<string, any>[] = [];
    const updates: Record<string, any>[] = [];
    const seenRemoteIds = new Set<string>();
    const markDeleted = sync.on_delete_action === 'mark_deleted';

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
          updates.push(payload);
        } else {
          if (remoteDeletedCol) {
            payload[remoteDeletedCol.title] = false;
          }
          inserts.push(payload);
        }
      }

      if (rows.length < SYNC_PAGE_SIZE) break;
      offset += SYNC_PAGE_SIZE;
    }

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

    this.logger.log(
      `Table sync ${sync.id}: source rows=${seenRemoteIds.size} existing=${existingByRemoteId.size} inserts=${inserts.length} updates=${updates.length}`,
    );

    // flush in chunks to bound memory on large mirrors
    const CHUNK = 200;
    for (let i = 0; i < inserts.length; i += CHUNK) {
      await destBaseModel.bulkInsert(inserts.slice(i, i + CHUNK), {
        ...engineWriteParams,
        chunkSize: 50,
        typecast: true,
      });
    }
    for (let i = 0; i < updates.length; i += CHUNK) {
      await destBaseModel.bulkUpdate(updates.slice(i, i + CHUNK), {
        cookie: req,
        allowSystemColumn: true,
        skip_hooks: true,
        typecast: true,
      });
    }

    // disappearance sweep — only meaningful once rows have been mirrored
    if (existingByRemoteId.size) {
      const stale = [...existingByRemoteId.entries()].filter(
        ([remoteId]) => !seenRemoteIds.has(remoteId),
      );
      if (stale.length) {
        if (markDeleted && remoteDeletedCol) {
          await destBaseModel.bulkUpdate(
            stale.map(([, row]) => ({
              [pkKey]: row[pkKey],
              [remoteDeletedCol.title]: true,
            })),
            {
              cookie: req,
              allowSystemColumn: true,
              skip_hooks: true,
              typecast: true,
            },
          );
        } else {
          await destBaseModel.bulkDelete(
            stale.map(([, row]) => ({ [pkKey]: row[pkKey] })),
            { cookie: req, allowSystemColumn: true },
          );
        }
      }
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
