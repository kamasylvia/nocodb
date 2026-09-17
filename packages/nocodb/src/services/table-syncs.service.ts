import { Inject, Injectable } from '@nestjs/common';
import NocoCache from '~/cache/NocoCache';
import {

  isVirtualCol,
  ProjectRoles,
  UITypes,
  ViewTypes,
  TableSyncInputMode,
  TableSyncMappingRole,
  TableSyncOnDeleteAction,
  TableSyncStatus,
  TableSyncTrigger,
} from 'nocodb-sdk';
import type {
  NcContext,
  NcRequest,
} from '~/interface/config';
import type { TableSyncJobMode } from '~/interface/Jobs';
import { JobTypes } from '~/interface/Jobs';
import type { IJobsService } from '~/modules/jobs/jobs-service.interface';
import Base from '~/models/Base';
import BaseUser from '~/models/BaseUser';
import Model from '~/models/Model';
import View from '~/models/View';
import GridViewColumn from '~/models/GridViewColumn';
import TableSync from '~/models/TableSync';
import { NcError } from '~/helpers/catchError';
import { generateUniqueName } from '~/helpers/exportImportHelpers';
import { TablesService } from '~/services/tables.service';
import { CacheDelDirection, CacheScope, MetaTable } from '~/utils/globals';
import Noco from '~/Noco';

// [CE-EE] F09: Table Sync (P1 = manual "NocoDB Sync" minimum loop). The sync
// mirrors one source table (browse mode: a table in another base the creator
// can read, whose grid view has allow_sync on) into a read-only `synced`
// destination table. P1 covers full-copy + manual resync + freeze/resume +
// delete; realtime/incremental (FEATURE_TABLE_SYNC_AUTO) and paste mode /
// detach stay out of scope for this phase.

/** [CE-EE] F09: engine-managed system columns on every mirror table. Titles
 *  come from the SDK's SYNC_SYSTEM_COLUMN_TITLES set (hidden in UI via
 *  isHiddenCol); P1 only needs these two. */
export const TABLE_SYNC_SYSTEM_COLUMNS: {
  title: string;
  uidt: UITypes;
}[] = [
  { title: 'RemoteId', uidt: UITypes.SingleLineText },
  { title: 'RemoteDeleted', uidt: UITypes.Checkbox },
];

/** uidts never mirrored into a sync destination table. Virtual/LTAR is
 *  rejected upstream (P4 scope); auto-managed system uidts are excluded
 *  because the mirror re-creates its own (engine write time, not source
 *  time — documented P1 limitation); attachments are excluded because the
 *  mirror write path (bulkUpdate) has no attachment-ownership bypass, so
 *  re-copying cross-base attachment refs would trip the ownership guard. */
const EXCLUDED_SOURCE_UIDTS: UITypes[] = [
  UITypes.ForeignKey,
  UITypes.ID,
  UITypes.Order,
  UITypes.CreatedTime,
  UITypes.LastModifiedTime,
  UITypes.CreatedBy,
  UITypes.LastModifiedBy,
  UITypes.Attachment,
  // soft-delete marker column (__nc_deleted) — trashed rows are excluded from
  // the copy by the soft-delete filter, the marker itself never mirrors
  UITypes.Deleted,
];

export function isMirrorableSourceColumn(col: {
  uidt?: UITypes | string;
  pk?: boolean;
  system?: boolean;
}): boolean {
  if ((col.uidt as string) && isVirtualCol({ uidt: col.uidt } as any)) {
    return false;
  }
  if (col.pk) return false;
  return !EXCLUDED_SOURCE_UIDTS.includes(col.uidt as UITypes);
}

@Injectable()
export class TableSyncsService {
  constructor(
    protected readonly tablesService: TablesService,
    @Inject('JobsService') protected readonly jobsService: IJobsService,
  ) {}

  private async assertSourceReadAccess(
    sourceContext: NcContext,
    sourceBaseId: string,
    userId: string,
  ) {
    const baseUser = await BaseUser.get(sourceContext, sourceBaseId, userId);
    // BaseUser.get joins workspace/main roles in but castType drops them from
    // the declared type — read them off the raw row
    const raw = baseUser as any;
    const effectiveRoles = [raw?.roles, raw?.workspace_roles, raw?.main_roles]
      .filter(Boolean)
      .flatMap((r) => String(r).split(','));

    const hasReadAccess =
      baseUser &&
      effectiveRoles.some(
        (r) => r && r !== 'no_access' && r !== ProjectRoles.NO_ACCESS,
      );
    if (!hasReadAccess) {
      // hide existence of the source base
      NcError.baseNotFound(sourceBaseId);
    }
  }

  private async loadSource(
    context: NcContext,
    sourceBaseId: string,
    sourceTableId: string,
    userId: string,
  ) {
    const sourceContext: NcContext = {
      ...context,
      workspace_id: context.workspace_id,
      base_id: sourceBaseId,
    };

    await this.assertSourceReadAccess(sourceContext, sourceBaseId, userId);

    const sourceBase = await Base.get(sourceContext, sourceBaseId);
    if (!sourceBase) NcError.baseNotFound(sourceBaseId);

    const sourceModel = await Model.get(sourceContext, sourceTableId);
    if (!sourceModel || sourceModel.type !== 'table') {
      NcError.tableNotFound(sourceTableId);
    }
    await sourceModel.getColumns(sourceContext);

    return { sourceContext, sourceBase, sourceModel };
  }

  private getSourceGridViews(
    sourceContext: NcContext,
    sourceModel: Model,
  ): Promise<View[]> {
    return View.list(sourceContext, sourceModel.id).then((views) =>
      views.filter((v) => v.type === ViewTypes.GRID),
    );
  }

  /** Resolve the view the sync pulls from: the explicitly picked grid view or
   *  the first grid view with allow_sync on. Throws when none qualifies. */
  private async resolveSourceView(
    sourceContext: NcContext,
    sourceModel: Model,
    sourceViewId?: string,
  ): Promise<View> {
    const gridViews = await this.getSourceGridViews(sourceContext, sourceModel);

    if (sourceViewId) {
      const view = gridViews.find((v) => v.id === sourceViewId);
      if (!view) NcError.viewNotFound(sourceViewId);
      if (!view.allow_sync) {
        NcError.badRequest(
          'Source view does not allow sync. Enable "Allow sync" on the shared view first',
        );
      }
      return view;
    }

    const view = gridViews.find((v) => (v as any).allow_sync);
    if (!view) {
      NcError.badRequest(
        'No grid view of the source table allows sync. Enable "Allow sync" on a shared view first',
      );
    }
    return view;
  }

  private getMirrorableColumns(sourceModel: Model) {
    return (sourceModel.columns || []).filter((c) =>
      isMirrorableSourceColumn(c as any),
    );
  }

  async listSyncs(context: NcContext, baseId: string) {
    const syncs = await TableSync.list(context, baseId);

    return Promise.all(
      syncs.map(async (sync) => {
        const res = sync.toType();
        res.mappings = await TableSync.listMappings(
          context,
          baseId,
          sync.id,
        );
        return res;
      }),
    );
  }

  async getSync(context: NcContext, baseId: string, tableSyncId: string) {
    const sync = await TableSync.get(context, tableSyncId);
    if (!sync || sync.base_id !== baseId) {
      NcError.genericNotFound('TableSync', tableSyncId);
    }
    const res = sync.toType();
    res.mappings = await TableSync.listMappings(context, baseId, sync.id);
    return res;
  }

  /** Schema inspection for the creation wizard (browse mode): source table
   *  mirrorable columns + grid views with their allow_sync state. */
  async sourceSchema(
    context: NcContext,
    baseId: string,
    body: {
      sourceBaseId?: string;
      sourceTableId?: string;
      sourceViewId?: string;
    },
    req: NcRequest,
  ) {
    const { sourceBaseId, sourceTableId, sourceViewId } = body || {};
    if (!sourceBaseId || !sourceTableId) {
      NcError.badRequest('sourceBaseId and sourceTableId are required');
    }
    if (sourceBaseId === baseId) {
      NcError.badRequest('Source base must be a different base');
    }

    const { sourceContext, sourceBase, sourceModel } = await this.loadSource(
      context,
      sourceBaseId,
      sourceTableId,
      req.user.id,
    );

    const mirrorable = this.getMirrorableColumns(sourceModel);
    const gridViews = await this.getSourceGridViews(sourceContext, sourceModel);
    const selectedView = sourceViewId
      ? gridViews.find((v) => v.id === sourceViewId)
      : gridViews.find((v) => (v as any).allow_sync);

    return {
      sourceBase: { id: sourceBase.id, title: sourceBase.title },
      sourceTable: { id: sourceModel.id, title: sourceModel.title },
      view: selectedView
        ? { id: selectedView.id, title: selectedView.title, allow_sync: !!(selectedView as any).allow_sync }
        : null,
      views: gridViews.map((v) => ({
        id: v.id,
        title: v.title,
        allow_sync: !!(v as any).allow_sync,
      })),
      columns: mirrorable.map((c) => ({
        id: c.id,
        title: c.title,
        uidt: c.uidt,
      })),
    };
  }

  async createSync(
    context: NcContext,
    baseId: string,
    body: {
      title?: string;
      sourceBaseId?: string;
      sourceTableId?: string;
      sourceViewId?: string;
      selectedFields?: string[] | null;
      onDeleteAction?: string;
      syncTrigger?: string;
    },
    req: NcRequest,
  ) {
    const {
      title,
      sourceBaseId,
      sourceTableId,
      sourceViewId,
      selectedFields,
      onDeleteAction,
      syncTrigger,
    } = body || {};

    if (!sourceBaseId || !sourceTableId) {
      NcError.badRequest('sourceBaseId and sourceTableId are required');
    }
    if (sourceBaseId === baseId) {
      NcError.badRequest('Source base must be a different base');
    }

    // [CE-EE] F09: FEATURE_TABLE_SYNC covers the manual trigger; the realtime
    // trigger is FEATURE_TABLE_SYNC_AUTO territory (kept paywalled in this
    // fork) — reject it here so the API cannot bypass the UI gate.
    if (syncTrigger && syncTrigger !== TableSyncTrigger.Manual) {
      NcError.badRequest(
        'Only the manual sync trigger is supported (automatic sync is not enabled)',
      );
    }
    if (
      onDeleteAction &&
      ![TableSyncOnDeleteAction.Delete, TableSyncOnDeleteAction.MarkDeleted]
        .includes(onDeleteAction as TableSyncOnDeleteAction)
    ) {
      NcError.badRequest(`Invalid on_delete_action: ${onDeleteAction}`);
    }

    // engine/table-system titles must not collide with a mirrorable source
    // column — tableCreate's system-column repopulation would silently rename
    // the mirror column and break the title-based column mapping built below
    const reservedNames = new Set(
      [
        // engine system columns
        ...TABLE_SYNC_SYSTEM_COLUMNS.flatMap((c) => [c.title, c.title.toLowerCase()]),
        // table system columns added by repopulateCreateTableSystemColumns
        'Id',
        'id',
        'CreatedAt',
        'created_at',
        'UpdatedAt',
        'updated_at',
        'nc_created_by',
        'nc_updated_by',
        'nc_order',
      ],
    );

    const { sourceContext, sourceModel } = await this.loadSource(
      context,
      sourceBaseId,
      sourceTableId,
      req.user.id,
    );

    const sourceView = await this.resolveSourceView(
      sourceContext,
      sourceModel,
      sourceViewId,
    );

    const mirrorable = this.getMirrorableColumns(sourceModel);
    if (!mirrorable.length) {
      NcError.badRequest('Source table has no syncable columns');
    }
    const colliding = mirrorable.find(
      (c) => reservedNames.has(c.title) || reservedNames.has(c.column_name),
    );
    if (colliding) {
      NcError.badRequest(
        `Source table column "${colliding.title}" uses a name reserved for sync system columns`,
      );
    }

    // field selection: null = all (current + future P2), array = whitelist by
    // title. Virtual/LTAR picks are rejected — LTAR mirroring is P4 scope.
    let selectedFieldsFinal: string[] | null = null;
    if (Array.isArray(selectedFields)) {
      const available = new Set(mirrorable.map((c) => c.title));
      const unknown = selectedFields.filter((t) => !available.has(t));
      if (unknown.length) {
        NcError.badRequest(
          `Fields cannot be synced (unsupported or unknown): ${unknown.join(', ')}`,
        );
      }
      selectedFieldsFinal = selectedFields;
    }

    const destBase = await Base.getWithInfo(context, baseId);
    if (!destBase) NcError.baseNotFound(baseId);

    // one engine job at a time per destination base keeps mirror title
    // allocation and concurrent full-copies predictable
    const existingSyncs = await TableSync.list(context, baseId);
    if (existingSyncs.some((s) => s.status === TableSyncStatus.Syncing)) {
      NcError.badRequest(
        'Another table sync is still running in this base. Try again once it completes',
      );
    }

    // build the mirror column payload: source columns (readonly) + engine
    // system columns (RemoteId / RemoteDeleted), all readonly
    const mirroredSourceCols = selectedFieldsFinal
      ? mirrorable.filter((c) => selectedFieldsFinal.includes(c.title))
      : mirrorable;

    const mirrorColumnsPayload = [
      ...mirroredSourceCols.map((c) => ({
        title: c.title,
        column_name: c.column_name || c.title,
        uidt: c.uidt,
        dt: c.dt,
        // [CE-EE] F09: mirrored columns are readonly for users; the engine
        // writes through the allowSystemColumn whitelist channel only
        readonly: true,
      })),
      ...TABLE_SYNC_SYSTEM_COLUMNS.map((c) => ({
        title: c.title,
        column_name: c.title.toLowerCase(),
        uidt: c.uidt,
        readonly: true,
        // [CE-EE] F09 R1(lane3/lane4): system:true is required for
        // isHiddenCol to hide these from the grid (readonly alone is not
        // enough — R1 screenshot showed RemoteId exposed)
        system: true,
      })),
    ];

    // unique mirror title inside the destination base
    const destTables = await Model.list(context, {
      base_id: baseId,
      source_id: destBase.sources[0].id,
    });
    const mirrorTitle = generateUniqueName(
      title?.trim() || sourceModel.title,
      destTables.map((t: any) => t.title),
    );

    // create the read-only mirror table via the native synced:true path
    // (tables.service → nc_models.synced=true → the whole synced guard chain
    // and UI read-only layer engage automatically). System columns (Id pk,
    // CreatedAt/UpdatedAt, nc_order) are added by tableCreate's repopulation.
    const mirrorModel = (await this.tablesService.tableCreate(context, {
      baseId,
      sourceId: destBase.sources[0].id,
      user: req.user,
      req,
      synced: true,
      table: {
        title: mirrorTitle,
        table_name: mirrorTitle,
        columns: mirrorColumnsPayload as any,
      } as any,
    })) as Model;

    await mirrorModel.getColumns(context);

    // [CE-EE] F09 R1(lane5): hide the engine bookkeeping columns from the
    // mirror's default grid view (standard view-column show=false — works
    // regardless of the meta system flag path)
    const mirrorViews = (await View.list(context, mirrorModel.id)) as any[];
    console.debug(
      `[F09-hide] views=${mirrorViews?.length} shapes=${JSON.stringify((mirrorViews ?? [])[0] ? Object.keys((mirrorViews ?? [])[0]).slice(0, 12) : [])}`,
    );
    const grid = (mirrorViews ?? []).find(
      (v: any) => v.view_type === ViewTypes.GRID || v.type === ViewTypes.GRID,
    );
    console.debug(`[F09-hide] grid=${grid?.id ?? 'none'}`);
    if (grid?.id) {
      const gcRows = (await GridViewColumn.list(context, grid.id)) as any[];
      console.debug(`[F09-hide] gcRows=${gcRows?.length}`);
      // [CE-EE] F09 R1(lane5): GVC rows carry fk_column_id but NO title —
      // match against the mirror model's system column ids instead
      const sysColIds = (mirrorModel.columns ?? [])
        .filter(
          (c: any) => c.title === 'RemoteId' || c.title === 'RemoteDeleted',
        )
        .map((c: any) => c.id);
      let hidden = 0;
      for (const gc of gcRows ?? []) {
        if (sysColIds.includes(gc.fk_column_id)) {
          await GridViewColumn.update(context, gc.id, { show: false });
          hidden += 1;
        }
      }
      console.debug(`[F09-hide] hidden=${hidden}`);
    }

    // [CE-EE] F09 R1(lane3/lane4): the generic table-create meta path drops
    // the custom system flag on appended sync system columns (CreatedAt-style
    // seeds persist, customer-payload columns do not) — force it post-create
    // so isHiddenCol hides RemoteId/RemoteDeleted from the grid. Direct meta
    // list+update (bypasses the model column cache and Column.update's
    // narrow whitelist, both of which were verified to drop the flag).
    const mirrorColumnRows = (await Noco.ncMeta.metaList2(
      context.workspace_id,
      context.base_id,
      MetaTable.COLUMNS,
      { condition: { fk_model_id: mirrorModel.id } },
    )) as any[];
    for (const colRow of mirrorColumnRows) {
      if (
        (colRow.title === 'RemoteId' || colRow.title === 'RemoteDeleted') &&
        !colRow.system
      ) {
        await Noco.ncMeta.metaUpdate(
          context.workspace_id,
          context.base_id,
          MetaTable.COLUMNS,
          { system: true },
          colRow.id,
        );
      }
    }
    await NocoCache.deepDel(
      context,
      `${CacheScope.COLUMN}:${mirrorModel.id}`,
      CacheDelDirection.CHILD_TO_PARENT,
    );

    const sync = await TableSync.insert(context, {
      base_id: baseId,
      fk_workspace_id: context.workspace_id,
      title: mirrorTitle,
      selected_fields: selectedFieldsFinal,
      on_delete_action:
        onDeleteAction || TableSyncOnDeleteAction.Delete,
      sync_trigger: TableSyncTrigger.Manual,
      status: TableSyncStatus.Syncing,
      source_input_mode: TableSyncInputMode.Browse,
      created_by: req.user.id,
    });

    const mainMapping = await this.insertMainMapping(
      context,
      sync,
      sourceContext,
      sourceModel,
      sourceView,
      mirrorModel,
    );

    // column identity: mirror columns were created from the source payloads
    // above — match by title (reserved-title collision already rejected)
    const destColByTitle = new Map(
      mirrorModel.columns.map((c) => [c.title, c]),
    );
    await TableSync.insertColumnMappings(
      context,
      mirroredSourceCols
        .map((srcCol) => ({
          base_id: baseId,
          fk_workspace_id: context.workspace_id,
          fk_table_sync_id: sync.id,
          fk_table_sync_mapping_id: mainMapping.id,
          source_workspace_id: sourceContext.workspace_id,
          source_base_id: sourceBaseId,
          source_table_id: sourceTableId,
          source_column_id: srcCol.id,
          dest_base_id: baseId,
          dest_table_id: mirrorModel.id,
          dest_column_id: destColByTitle.get(srcCol.title)?.id,
        }))
        .filter((r) => !!r.dest_column_id),
    );

    await this.enqueueSyncJob(context, sync, 'full-create', req);

    return this.getSync(context, baseId, sync.id);
  }

  private async insertMainMapping(
    context: NcContext,
    sync: TableSync,
    sourceContext: NcContext,
    sourceModel: Model,
    sourceView: View,
    mirrorModel: Model,
  ) {
    const mapping = {
      base_id: context.base_id,
      fk_workspace_id: context.workspace_id,
      fk_table_sync_id: sync.id,
      source_workspace_id: sourceContext.workspace_id,
      source_base_id: sourceContext.base_id,
      source_table_id: sourceModel.id,
      source_view_id: sourceView.id,
      dest_base_id: context.base_id,
      dest_table_id: mirrorModel.id,
      role: TableSyncMappingRole.Main,
    };
    const { id } = await Noco.ncMeta.metaInsert2(
      context.workspace_id,
      context.base_id,
      MetaTable.TABLE_SYNC_MAPPINGS,
      mapping,
    );
    return { ...mapping, id } as any;
  }

  private async enqueueSyncJob(
    context: NcContext,
    sync: TableSync,
    mode: TableSyncJobMode,
    req: NcRequest,
  ) {
    const job = await this.jobsService.add(JobTypes.TableSyncRun, {
      context: {
        workspace_id: context.workspace_id,
        base_id: context.base_id,
      },
      user: { id: req.user?.id },
      syncId: sync.id,
      mode,
      req,
    } as any);

    await TableSync.update(context, context.base_id, sync.id, {
      sync_job_id: String(job?.id || ''),
      status: TableSyncStatus.Syncing,
    });
    return job;
  }

  async updateSync(
    context: NcContext,
    baseId: string,
    tableSyncId: string,
    body: {
      title?: string;
      on_delete_action?: string;
      selected_fields?: string[];
    },
    req: NcRequest,
  ) {
    const sync = await TableSync.get(context, tableSyncId);
    if (!sync || sync.base_id !== baseId) {
      NcError.genericNotFound('TableSync', tableSyncId);
    }
    if (sync.status === TableSyncStatus.Syncing) {
      NcError.badRequest('Cannot update a sync while it is running');
    }
    if (sync.status === TableSyncStatus.Paused) {
      NcError.badRequest('Resume the sync before updating its configuration');
    }

    // selected_fields mutation requires column add/drop propagation — P2 scope
    if (body?.selected_fields !== undefined) {
      NcError.badRequest(
        'Changing the synced field selection is not supported yet',
      );
    }

    const patch: Record<string, any> = { updated_by: req.user.id };
    if (body?.title !== undefined) {
      if (typeof body.title !== 'string' || !body.title.trim()) {
        NcError.badRequest('Sync title must be a non-empty string');
      }
      patch.title = body.title.trim();
    }
    if (body?.on_delete_action !== undefined) {
      if (
        ![TableSyncOnDeleteAction.Delete, TableSyncOnDeleteAction.MarkDeleted]
          .includes(body.on_delete_action as TableSyncOnDeleteAction)
      ) {
        NcError.badRequest(
          `Invalid on_delete_action: ${body.on_delete_action}`,
        );
      }
      patch.on_delete_action = body.on_delete_action;
    }

    await TableSync.update(context, baseId, tableSyncId, patch);
    return this.getSync(context, baseId, tableSyncId);
  }

  async deleteSync(
    context: NcContext,
    baseId: string,
    tableSyncId: string,
    req: NcRequest,
  ) {
    const sync = await TableSync.get(context, tableSyncId);
    if (!sync || sync.base_id !== baseId) {
      NcError.genericNotFound('TableSync', tableSyncId);
    }
    if (sync.status === TableSyncStatus.Syncing) {
      NcError.badRequest('Cannot delete a sync while it is running');
    }

    const mappings = await TableSync.listMappings(context, baseId, tableSyncId);
    const mainMapping = mappings.find((m) => m.role === TableSyncMappingRole.Main);

    // trash the mirror table with the platform-unified trash semantics;
    // forceDeleteSyncs bypasses the synced-table delete guard (this IS the
    // sync removal path the guard reserves the bypass for)
    if (mainMapping?.dest_table_id) {
      await this.tablesService.tableDelete(context, {
        tableId: mainMapping.dest_table_id,
        forceDeleteSyncs: true,
        req,
      });
    }

    await TableSync.delete(context, baseId, tableSyncId);
  }

  async resync(
    context: NcContext,
    baseId: string,
    tableSyncId: string,
    req: NcRequest,
  ) {
    const sync = await TableSync.get(context, tableSyncId);
    if (!sync || sync.base_id !== baseId) {
      NcError.genericNotFound('TableSync', tableSyncId);
    }
    if (sync.status === TableSyncStatus.Syncing) {
      NcError.badRequest('Sync is already running');
    }
    if (sync.status === TableSyncStatus.Paused) {
      NcError.badRequest('Sync is paused. Resume it before syncing');
    }
    return this.enqueueSyncJob(context, sync, 'full-resync', req);
  }

  async freeze(
    context: NcContext,
    baseId: string,
    tableSyncId: string,
    req: NcRequest,
  ) {
    const sync = await TableSync.get(context, tableSyncId);
    if (!sync || sync.base_id !== baseId) {
      NcError.genericNotFound('TableSync', tableSyncId);
    }
    if (sync.status === TableSyncStatus.Syncing) {
      NcError.badRequest('Cannot pause a sync while it is running');
    }
    if (sync.status === TableSyncStatus.Paused) {
      NcError.badRequest('Sync is already paused');
    }
    await TableSync.update(context, baseId, tableSyncId, {
      status: TableSyncStatus.Paused,
      updated_by: req.user.id,
    });
    return this.getSync(context, baseId, tableSyncId);
  }

  async resume(
    context: NcContext,
    baseId: string,
    tableSyncId: string,
    req: NcRequest,
  ) {
    const sync = await TableSync.get(context, tableSyncId);
    if (!sync || sync.base_id !== baseId) {
      NcError.genericNotFound('TableSync', tableSyncId);
    }
    if (sync.status !== TableSyncStatus.Paused) {
      NcError.badRequest('Sync is not paused');
    }
    await TableSync.update(context, baseId, tableSyncId, {
      status: TableSyncStatus.Active,
      updated_by: req.user.id,
    });
    return this.getSync(context, baseId, tableSyncId);
  }

  /** Paste-mode link resolution (shared view URL) — P2 scope. */
  async resolveLink(_context: NcContext, _baseId: string, _body: any) {
    NcError.notImplemented('tableSyncResolveLink');
  }
}
