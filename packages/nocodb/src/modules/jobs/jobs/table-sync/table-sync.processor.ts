import { Injectable, Logger } from '@nestjs/common';
import { Job } from 'bull';
import { TableSyncMappingRole, TableSyncStatus } from 'nocodb-sdk';
import type { NcContext, NcRequest } from '~/interface/config';
import type { TableSyncJobData } from '~/interface/Jobs';
import Model from '~/models/Model';
import Source from '~/models/Source';
import TableSync from '~/models/TableSync';
import NcConnectionMgrv2 from '~/utils/common/NcConnectionMgrv2';
import type { BaseModelSqlv2 } from '~/db/BaseModelSqlv2';
import type { Column } from '~/models';
import type LinkToAnotherRecordColumn from '~/models/LinkToAnotherRecordColumn';
import { ColumnsService } from '~/services/columns.service';
// [CE-EE] F09 P4: link column classification shared with the service layer
import { isSyncLinkColumnUidt } from '~/services/table-syncs.service';
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
// falls back to the full pass (upsert + disappearance sweep) — a full pull
// observes every row, so the sweep is safe and required there.

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
    // affectedIds-by-pk pass (realtime taps) or the full-pass catch-up
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
    // [CE-EE] F09 P4: link-typed column mappings drive the shadow/junction
    // layers and must NEVER enter the scalar payload (link columns are
    // virtual — writing their title key would corrupt the bulk write)
    const linkFieldPairs: {
      srcId: string;
      srcCol: Column;
      destCol: Column;
    }[] = [];
    for (const m of columnMappings) {
      const srcCol = srcColById.get(m.source_column_id);
      const destCol = destColById.get(m.dest_column_id);
      if (!srcCol || !destCol) continue;
      if (!isSyncLinkColumnUidt(srcCol.uidt)) continue;
      linkFieldPairs.push({ srcId: m.source_column_id, srcCol, destCol });
    }
    const fieldMap = columnMappings
      .filter((m) => !isSyncLinkColumnUidt(srcColById.get(m.source_column_id)?.uidt))
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

    // [CE-EE] F09 P3 (wording corrected P4-R4/lane1 M1): pull shape —
    // incremental runs with touched row ids pull those rows by pk;
    // incremental runs WITHOUT ids (catch-up) fall through to the FULL pass
    // (upsert + disappearance sweep — see the branch below, P3-R2); every
    // other mode is the full pass too
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

    // [CE-EE] F09 P4: LTAR layers — shadow tables + junction RemoteId
    // pairing. Every full pass (full-create / manual resync / catch-up)
    // recomputes all layers; the affectedIds incremental pass cleans junction
    // rows anchored on main-mirror rows the source no longer has — both
    // policies: hard-deleted (delete) and flagged (mark_deleted), matching
    // the full-pass recompute semantics (P4-R1 lane4b M1). Full pair
    // recomputation waits for a link event or the next full pass — the
    // sanctioned P4 simplification tier. Failures propagate so the sync
    // lands in status=error + last_error (visible + retriable via Sync now;
    // reruns are idempotent).
    if (linkFieldPairs.length) {
      const allMappings =
        (await TableSync.listMappings(context, sync.base_id, sync.id)) || [];
      const shadowMappings = allMappings.filter(
        (m: any) => m.role === TableSyncMappingRole.LinkedShadow,
      );
      const junctionMappings = allMappings.filter(
        (m: any) => m.role === TableSyncMappingRole.Junction,
      );

      if (isIncremental && affectedIds?.length) {
        // [CE-EE] F09 P4-R1(lane4b M1): junction pairs mirror the source
        // junction in BOTH tiers — main-mirror rows hard-deleted under the
        // delete policy AND rows flagged under mark_deleted lose their pairs
        // right here, exactly as the full-pass recompute would (the flagged
        // row itself stays, per the row-level on_delete policy). Previously
        // mark_deleted kept stale pairs until the next full pass — the same
        // policy behaved differently per tier.
        const orphanedMainPks = [
          ...pendingDeletes.map((d) => String(d[pkKey])),
          ...(markDeleted && remoteDeletedCol
            ? pendingUpdates
                .filter((u) => u[remoteDeletedCol.title] === true)
                .map((u) => String(u[pkKey]))
            : []),
        ];
        if (orphanedMainPks.length && junctionMappings.length) {
          await this.cleanupJunctionOrphans(
            context,
            destModel,
            junctionMappings,
            orphanedMainPks,
          );
        }
      } else {
        await this.recomputeLinkLayers({
          context,
          sourceContext,
          sync,
          req,
          markDeleted,
          engineWriteParams,
          destBaseModel,
          destModel,
          remoteIdColTitle: remoteIdCol.title,
          mainPkKey: pkKey,
          linkFieldPairs,
          shadowMappings: shadowMappings as any,
          columnMappings: columnMappings as any,
        });
      }
    }
  }

  // ────────────────────────────────────────────────────────────────────────
  // [CE-EE] F09 P4: LTAR link layers (LinkedShadow + Junction)
  // ────────────────────────────────────────────────────────────────────────

  /** RemoteId → dest pk map of a synced mirror table (paged scan). */
  private async scanDestRemoteMap(
    destBaseModel: BaseModelSqlv2,
    destModel: Model,
    remoteIdColTitle: string,
    pkKey: string,
  ): Promise<Map<string, string>> {
    const map = new Map<string, string>();
    let offset = 0;
    for (;;) {
      const rows = normalizeListResult(
        await destBaseModel.list(
          { limit: SYNC_PAGE_SIZE, offset } as any,
          { ignoreViewFilterAndSort: true, ignoreRls: true } as any,
        ),
      );
      for (const row of rows) {
        if (row[remoteIdColTitle] != null) {
          map.set(String(row[remoteIdColTitle]), String(row[pkKey]));
        }
      }
      if (rows.length < SYNC_PAGE_SIZE) break;
      offset += SYNC_PAGE_SIZE;
    }
    return map;
  }

  /** [CE-EE] F09 P4: recompute the LTAR layers of a sync — mirror every
   *  linked source table into its shadow (same RemoteId upsert + sweep
   *  semantics as the main table) and rebuild the junction RemoteId
   *  pairings for each mirrored link column. Runs in the full pass only. */
  private async recomputeLinkLayers(args: {
    context: NcContext;
    sourceContext: NcContext;
    sync: TableSync;
    req: NcRequest;
    markDeleted: boolean;
    engineWriteParams: Record<string, any>;
    destBaseModel: BaseModelSqlv2;
    destModel: Model;
    remoteIdColTitle: string;
    mainPkKey: string;
    linkFieldPairs: { srcId: string; srcCol: Column; destCol: Column }[];
    shadowMappings: any[];
    columnMappings: any[];
  }): Promise<void> {
    const {
      context,
      sourceContext,
      sync,
      req,
      markDeleted,
      engineWriteParams,
      destBaseModel,
      destModel,
      remoteIdColTitle,
      mainPkKey,
      linkFieldPairs,
      shadowMappings,
      columnMappings,
    } = args;

    if (!linkFieldPairs.length) return;

    // current main-mirror remoteId→pk (after the main pass flush — new
    // inserts carry generated pks that only exist in the DB)
    const mainRemoteToPk = await this.scanDestRemoteMap(
      destBaseModel,
      destModel,
      remoteIdColTitle,
      mainPkKey,
    );

    // 1. shadow tables: mirror of each linked source table (shared across
    //    link columns pointing at the same related table)
    const shadowRemoteToPkBySource = new Map<string, Map<string, string>>();
    for (const shadowMapping of shadowMappings) {
      const shadowSrcModel = await Model.get(
        sourceContext,
        shadowMapping.source_table_id,
      );
      if (!shadowSrcModel || shadowSrcModel.deleted) continue;
      await shadowSrcModel.getColumns(sourceContext);
      const shadowDestModel = await Model.get(
        context,
        shadowMapping.dest_table_id,
      );
      if (!shadowDestModel || shadowDestModel.deleted) continue;
      await shadowDestModel.getColumns(context);

      const rtColById = new Map<string, Column>(
        shadowSrcModel.columns.map((c) => [c.id, c as Column]),
      );
      const shadowColById = new Map<string, Column>(
        shadowDestModel.columns.map((c) => [c.id, c as Column]),
      );
      const shadowFields = columnMappings
        .filter((m) => m.fk_table_sync_mapping_id === shadowMapping.id)
        .map(({ source_column_id, dest_column_id }) => ({
          srcTitle: rtColById.get(source_column_id)?.title,
          destTitle: shadowColById.get(dest_column_id)?.title,
        }))
        .filter((m) => !!m.srcTitle && !!m.destTitle);

      const shadowRemoteToPk = await this.syncShadowTable({
        context,
        sourceContext,
        sync,
        req,
        markDeleted,
        engineWriteParams,
        srcModel: shadowSrcModel,
        destModel: shadowDestModel,
        fields: shadowFields,
      });
      shadowRemoteToPkBySource.set(
        shadowMapping.source_table_id,
        shadowRemoteToPk,
      );
    }

    // 2. junction pair recomputation per mirrored link column
    for (const pair of linkFieldPairs) {
      const srcOpt =
        await pair.srcCol.getColOptions<LinkToAnotherRecordColumn>(
          sourceContext,
        );
      if (!srcOpt?.fk_mm_model_id) continue;
      const shadowRemoteToPk = shadowRemoteToPkBySource.get(
        srcOpt.fk_related_model_id,
      );
      if (!shadowRemoteToPk) continue;
      const destOpt =
        await pair.destCol.getColOptions<LinkToAnotherRecordColumn>(context);
      if (!destOpt?.fk_mm_model_id) continue;

      await this.recomputeJunctionPairs({
        sync,
        srcOpt,
        destOpt,
        context,
        sourceContext,
        mainRemoteToPk,
        shadowRemoteToPk,
      });
    }
  }

  /** [CE-EE] F09 P4: full upsert + disappearance-sweep pass for one shadow
   *  table (mirror of a linked source table). Same RemoteId-keyed semantics
   *  as the main-table full pass; returns the post-pass remoteId→pk map
   *  needed for junction pairing. */
  private async syncShadowTable(args: {
    context: NcContext;
    sourceContext: NcContext;
    sync: TableSync;
    req: NcRequest;
    markDeleted: boolean;
    engineWriteParams: Record<string, any>;
    srcModel: Model;
    destModel: Model;
    fields: { srcTitle: string; destTitle: string }[];
  }): Promise<Map<string, string>> {
    const {
      context,
      sourceContext,
      sync,
      req,
      markDeleted,
      engineWriteParams,
      srcModel,
      destModel,
      fields,
    } = args;

    const srcBaseModel = await this.getBaseModel(sourceContext, srcModel);
    const destBaseModel = await this.getBaseModel(context, destModel);

    const remoteIdCol = destModel.columns.find((c) => c.title === 'RemoteId');
    const remoteDeletedCol = destModel.columns.find(
      (c) => c.title === 'RemoteDeleted',
    );
    const destPkCol = destModel.columns.find((c) => c.pk);
    if (!remoteIdCol || !destPkCol) {
      throw new Error('Shadow table is missing the RemoteId / pk system column');
    }
    const pkKey = destPkCol.title;

    const pendingInserts: Record<string, any>[] = [];
    const pendingUpdates: Record<string, any>[] = [];
    const pendingDeletes: Record<string, any>[] = [];
    const seenRemoteIds = new Set<string>();

    // existing shadow rows keyed by RemoteId
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

    // pull the whole linked source table (paged) and upsert
    let offset = 0;
    for (;;) {
      const rows = normalizeListResult(
        await srcBaseModel.list(
          { limit: SYNC_PAGE_SIZE, offset } as any,
          { ignoreViewFilterAndSort: true, ignoreRls: true } as any,
        ),
      );
      for (const row of rows) {
        const remoteId = String(srcBaseModel.extractPksValues(row, true) ?? '');
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

    // disappearance sweep — a linked source row that vanished follows the
    // sync's on_delete policy on the shadow too
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

    this.logger.log(
      `Table sync ${sync.id} [shadow ${destModel.title}]: source rows=${seenRemoteIds.size} inserts=${pendingInserts.length} updates=${pendingUpdates.length} deletes=${pendingDeletes.length}`,
    );

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

    return this.scanDestRemoteMap(
      destBaseModel,
      destModel,
      remoteIdCol.title,
      pkKey,
    );
  }

  /** [CE-EE] F09 P4: rebuild one dest junction so its rows mirror the
   *  source junction's RemoteId pairs. Rows are keyed by the
   *  (mainPk, shadowPk) pair — a source pair whose either side has no
   *  dest row yet is skipped (dangling source junction rows on meta
   *  sources get swept the same way). Junction writes go straight through
   *  knex on the junction table (same channel the relation manager uses);
   *  the junction is a synced table, so users keep hitting the guard chain. */
  private async recomputeJunctionPairs(args: {
    sync: TableSync;
    srcOpt: LinkToAnotherRecordColumn;
    destOpt: LinkToAnotherRecordColumn;
    context: NcContext;
    sourceContext: NcContext;
    mainRemoteToPk: Map<string, string>;
    shadowRemoteToPk: Map<string, string>;
  }): Promise<void> {
    const {
      sync,
      srcOpt,
      destOpt,
      context,
      sourceContext,
      mainRemoteToPk,
      shadowRemoteToPk,
    } = args;

    const srcJunctionModel = await srcOpt.getMMModel(sourceContext);
    const srcMainSideCol = await srcOpt.getMMChildColumn(sourceContext);
    const srcShadowSideCol = await srcOpt.getMMParentColumn(sourceContext);
    const destJunctionModel = await destOpt.getMMModel(context);
    const destMainSideCol = await destOpt.getMMChildColumn(context);
    const destShadowSideCol = await destOpt.getMMParentColumn(context);
    if (
      !srcJunctionModel ||
      !srcMainSideCol ||
      !srcShadowSideCol ||
      !destJunctionModel ||
      !destMainSideCol ||
      !destShadowSideCol
    ) {
      this.logger.warn(
        `Table sync ${sync.id}: junction meta incomplete for link column — skipping pair recompute`,
      );
      return;
    }

    const srcJunctionBm = await this.getBaseModel(
      sourceContext,
      srcJunctionModel,
    );
    const destJunctionBm = await this.getBaseModel(context, destJunctionModel);

    // source pairs (paged): main-side remoteId + shadow-side remoteId
    const srcPairs: { main: string; shadow: string }[] = [];
    {
      let offset = 0;
      for (;;) {
        const rows = normalizeListResult(
          await srcJunctionBm.execAndParse(
            srcJunctionBm
              .dbDriver(srcJunctionBm.getTnPath(srcJunctionModel.table_name))
              .select(
                `${srcMainSideCol.column_name} as __main`,
                `${srcShadowSideCol.column_name} as __shadow`,
              )
              .limit(SYNC_PAGE_SIZE)
              .offset(offset),
            null,
            { raw: true },
          ),
        );
        for (const row of rows) {
          if (row.__main == null || row.__shadow == null) continue;
          srcPairs.push({ main: String(row.__main), shadow: String(row.__shadow) });
        }
        if (rows.length < SYNC_PAGE_SIZE) break;
        offset += SYNC_PAGE_SIZE;
      }
    }

    // desired dest pairs (both sides must exist in the mirrors)
    const desired = new Map<string, { main: string; shadow: string }>();
    for (const p of srcPairs) {
      const mainPk = mainRemoteToPk.get(p.main);
      const shadowPk = shadowRemoteToPk.get(p.shadow);
      if (!mainPk || !shadowPk) continue;
      desired.set(`${mainPk}|${shadowPk}`, { main: mainPk, shadow: shadowPk });
    }

    // existing dest junction rows
    const destTn = destJunctionBm.getTnPath(destJunctionModel.table_name);
    const existing = new Map<string, { main: string; shadow: string }>();
    {
      let offset = 0;
      for (;;) {
        const rows = normalizeListResult(
          await destJunctionBm.execAndParse(
            destJunctionBm
              .dbDriver(destTn)
              .select(
                `${destMainSideCol.column_name} as __main`,
                `${destShadowSideCol.column_name} as __shadow`,
              )
              .limit(SYNC_PAGE_SIZE)
              .offset(offset),
            null,
            { raw: true },
          ),
        );
        for (const row of rows) {
          if (row.__main == null || row.__shadow == null) continue;
          const main = String(row.__main);
          const shadow = String(row.__shadow);
          existing.set(`${main}|${shadow}`, { main, shadow });
        }
        if (rows.length < SYNC_PAGE_SIZE) break;
        offset += SYNC_PAGE_SIZE;
      }
    }

    // insert missing pairs (chunked)
    const toInsert = [...desired.entries()]
      .filter(([key]) => !existing.has(key))
      .map(([, v]) => ({
        [destMainSideCol.column_name]: v.main,
        [destShadowSideCol.column_name]: v.shadow,
      }));
    const CHUNK = 200;
    for (let i = 0; i < toInsert.length; i += CHUNK) {
      await destJunctionBm.execAndParse(
        destJunctionBm.dbDriver(destTn).insert(toInsert.slice(i, i + CHUNK)),
        null,
        { raw: true },
      );
    }

    // delete pairs the source no longer has (pair-wise; extras are rare)
    let deleted = 0;
    for (const [key, v] of existing) {
      if (desired.has(key)) continue;
      await destJunctionBm.execAndParse(
        destJunctionBm
          .dbDriver(destTn)
          .where({
            [destMainSideCol.column_name]: v.main,
            [destShadowSideCol.column_name]: v.shadow,
          })
          .del(),
        null,
        { raw: true },
      );
      deleted += 1;
    }

    this.logger.log(
      `Table sync ${sync.id} [junction ${destJunctionModel.title}]: source pairs=${srcPairs.length} linked=${desired.size} inserted=${toInsert.length} removed=${deleted}`,
    );
  }

  /** [CE-EE] F09 P4: after an incremental run hard-deleted main-mirror rows,
   *  drop the junction rows that referenced them (delete policy only —
   *  mark_deleted rows stay and keep their pairs). */
  private async cleanupJunctionOrphans(
    context: NcContext,
    destModel: Model,
    junctionMappings: any[],
    deletedDestPks: string[],
  ): Promise<void> {
    for (const junctionMapping of junctionMappings) {
      const linkCol = await this.findMirrorLinkColumnByJunction(
        context,
        destModel,
        junctionMapping.dest_table_id,
      );
      if (!linkCol) continue;
      const destOpt =
        await linkCol.getColOptions<LinkToAnotherRecordColumn>(context);
      if (!destOpt?.fk_mm_model_id) continue;
      const junctionModel = await destOpt.getMMModel(context);
      const mainSideCol = await destOpt.getMMChildColumn(context);
      if (!junctionModel || !mainSideCol) continue;
      const junctionBm = await this.getBaseModel(context, junctionModel);
      await junctionBm.execAndParse(
        junctionBm
          .dbDriver(junctionBm.getTnPath(junctionModel.table_name))
          .whereIn(mainSideCol.column_name, deletedDestPks)
          .del(),
        null,
        { raw: true },
      );
    }
  }

  /** [CE-EE] F09 P4: the link column on the main mirror whose CE junction is
   *  the given table (junction mappings only carry dest_table_id). */
  private async findMirrorLinkColumnByJunction(
    context: NcContext,
    destModel: Model,
    junctionTableId: string,
  ): Promise<Column | null> {
    for (const col of destModel.columns || []) {
      if (!isSyncLinkColumnUidt(col.uidt)) continue;
      const opt = await col.getColOptions<LinkToAnotherRecordColumn>(context);
      if (opt?.fk_mm_model_id === junctionTableId) return col as Column;
    }
    return null;
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
