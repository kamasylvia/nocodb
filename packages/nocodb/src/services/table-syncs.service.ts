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
import { ColumnsService } from '~/services/columns.service';
import bcrypt from 'bcryptjs';
import { CacheDelDirection, CacheScope, MetaTable } from '~/utils/globals';
import Noco from '~/Noco';

// [CE-EE] F09: Table Sync (P1 = manual "NocoDB Sync" minimum loop). The sync
// mirrors one source table (browse mode: a table in another base the creator
// can read, whose grid view has allow_sync on) into a read-only `synced`
// destination table. P1 covers full-copy + manual resync + freeze/resume +
// delete. P2 adds: paste mode (shared-view uuid + password), field-selection
// change propagation, source column type propagation, detach (convert to
// regular table), create-time atomicity cleanup, and resync-time source
// re-validation. Realtime/incremental (FEATURE_TABLE_SYNC_AUTO) stay P3.

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
    protected readonly columnsService: ColumnsService,
    @Inject('JobsService') protected readonly jobsService: IJobsService,
  ) {}

  /** [CE-EE] F09 P2: pull the shared-view uuid out of a pasted URL (or accept
   *  a bare uuid). Handles both the path form (…/nc/grid/<uuid>) and the
   *  legacy hash-route form (…/#/nc/grid/<uuid>) — R3(lane4 M-1). */
  private extractSharedViewUuid(input?: string): string | null {
    if (!input || typeof input !== 'string') return null;
    const trimmed = input.trim();
    if (!trimmed) return null;
    const uuidLike = (s?: string) =>
      s && /^[0-9a-f-]{36}$/i.test(s) ? s : null;
    if (uuidLike(trimmed)) return trimmed;
    try {
      const url = new URL(trimmed);
      // hash-route form: the uuid lives after '#', not in pathname
      const candidates = [
        ...url.pathname.split('/').filter(Boolean),
        ...url.hash.replace(/^#/, '').split('/').filter(Boolean),
      ];
      for (const seg of candidates.reverse()) {
        const hit = uuidLike(seg);
        if (hit) return hit;
      }
      return null;
    } catch {
      const last = trimmed.split('/').filter(Boolean).pop();
      return uuidLike(last);
    }
  }

  private async assertSourceReadAccess(
    sourceContext: NcContext,
    sourceBaseId: string,
    userId: string,
  ) {
    const baseUser = await BaseUser.get(sourceContext, sourceBaseId, userId);
    // BaseUser.get joins workspace/main roles in but castType drops them from
    // the declared type — read them off the raw row
    const raw = baseUser as any;
    // [CE-EE] F09 R5(lane1/2/3/5): mirror the platform predicate
    // (BaseUser.ts:563-631 / User.getWithRoles) exactly:
    // 1. explicit base role ∉ {no_access, NO_ACCESS, inherit} → read
    // 2. base role null/''/inherit ∧ workspace role ≠ no-access → read
    //    (workspace inheritance, non-private bases only)
    // 3. explicit base role = no_access → deny (overrides ws inheritance)
    // 4. no base row → deny
    // Private bases: workspace inheritance never applies — only path 1.
    const sourceBase = await Base.get(sourceContext, sourceBaseId);
    const baseRole = String(raw?.roles ?? '');
    const wsRoles = String(raw?.workspace_roles ?? '')
      .split(',')
      .filter(Boolean);

    // path 1: explicit base role, not no_access and not inherit
    const hasExplicitBaseRole =
      baseRole !== '' &&
      baseRole !== 'no_access' &&
      baseRole !== ProjectRoles.NO_ACCESS &&
      baseRole !== 'inherit';
    // path 3: explicit no_access denies regardless of ws inheritance
    const baseNoAccess =
      baseRole === 'no_access' || baseRole === ProjectRoles.NO_ACCESS;

    if (sourceBase?.is_private) {
      // private: only path 1
      if (!hasExplicitBaseRole) {
        NcError.baseNotFound(sourceBaseId);
      }
    } else if (baseNoAccess) {
      // non-private: explicit no_access denies regardless of ws role
      NcError.baseNotFound(sourceBaseId);
    } else if (!hasExplicitBaseRole) {
      // non-private: base role absent or inherit — check ws role
      const wsNoAccess =
        wsRoles.length === 0 ||
        wsRoles.every((r) => r === 'workspace-level-no-access');
      if (wsNoAccess) {
        NcError.baseNotFound(sourceBaseId);
      }
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
        // [CE-EE] F09 P2-R3(lane2): never expose the share credential — the
        // uuid identifies the link and the hash is server-side only
        for (const m of res.mappings as any[]) {
          delete m.source_uuid;
          delete m.source_password_hash;
        }
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
    // [CE-EE] F09 P2-R3(lane2): strip the share credential from responses
    for (const m of res.mappings as any[]) {
      delete m.source_uuid;
      delete m.source_password_hash;
    }
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
      sharedViewUrl?: string;
      sharedViewPassword?: string;
    },
    req: NcRequest,
  ) {
    const { sourceBaseId, sourceTableId, sourceViewId } = body || {};

    // [CE-EE] F09 P2: paste-mode schema preview — resolve the shared view by
    // uuid (+ optional password), no base-membership requirement
    if (!sourceBaseId && (body?.sharedViewUrl || (body as any)?.sourceViewUuid)) {
      const uuid = this.extractSharedViewUuid(
        body.sharedViewUrl || (body as any).sourceViewUuid,
      );
      if (!uuid) NcError.badRequest('A valid shared view URL or uuid is required');
      const view = await View.getByUUID(context, uuid);
      if (!view) NcError.badRequest('Shared view not found');
      if (!(view as any).allow_sync) {
        NcError.badRequest('Sync is not allowed on the shared view');
      }
      if (view.password) {
        if (!body.sharedViewPassword) {
          // authenticated shape: tell the caller a password is required
          return { passwordProtected: true };
        }
        const ok = await bcrypt.compare(body.sharedViewPassword, view.password);
        if (!ok) NcError.badRequest('Invalid shared view password');
      }
      const srcContext: NcContext = {
        workspace_id: (view as any).fk_workspace_id || context.workspace_id,
        base_id: (view as any).base_id,
      };
      const srcModel = await Model.get(srcContext, (view as any).fk_model_id);
      if (!srcModel) NcError.badRequest('Shared view not found');
      await srcModel.getColumns(srcContext);
      const mirrorable = this.getMirrorableColumns(srcModel);
      return {
        sourceInputMode: TableSyncInputMode.Paste,
        sourceBase: { id: (view as any).base_id, title: (view as any).base_id },
        sourceTable: { id: srcModel.id, title: srcModel.title },
        view: {
          id: (view as any).id,
          title: (view as any).title,
          allow_sync: true,
          uuid,
        },
        views: [],
        columns: mirrorable.map((c) => ({
          id: c.id,
          title: c.title,
          uidt: c.uidt,
        })),
      };
    }

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
      sourceInputMode?: string;
      sharedViewUrl?: string;
      sharedViewPassword?: string;
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
      sourceInputMode,
      sharedViewUrl,
      sharedViewPassword,
    } = body || {};

    // [CE-EE] F09 P2: paste mode resolves a shared view by uuid (+ optional
    // password) instead of by base access — EE semantics: the share link IS
    // the persistent credential, stored hashed on the mapping
    const isPaste = sourceInputMode === TableSyncInputMode.Paste;

    if (!isPaste && (!sourceBaseId || !sourceTableId)) {
      NcError.badRequest('sourceBaseId and sourceTableId are required');
    }
    if (!isPaste && sourceBaseId === baseId) {
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

    // [CE-EE] F09 P2(lane obs): paste mode resolves the shared view by uuid
    // (allow_sync + optional bcrypt password required); browse mode keeps the
    // direct source-access check. Both funnel into the same
    // {sourceContext, sourceModel, sourceView} triple below.
    let pasteUuid: string | null = null;
    let pastePasswordHash: string | null = null;
    let sourceContext: NcContext;
    let sourceModel: Model;
    let sourceView: View;

    if (isPaste) {
      const uuid = this.extractSharedViewUuid(sharedViewUrl);
      if (!uuid) {
        NcError.badRequest('A valid shared view URL or uuid is required');
      }
      const view = await View.getByUUID(context, uuid);
      if (!view) {
        NcError.badRequest('Shared view not found');
      }
      // [CE-EE] F09 P2-R1(lane1 E1): every source-model access must use the
      // SOURCE context — getColumns with the dest context resolved the wrong
      // cache scope and left mirrorable empty ("no syncable columns")
      const srcContext: NcContext = {
        workspace_id: (view as any).fk_workspace_id || context.workspace_id,
        base_id: (view as any).base_id,
      };
      const srcModel = await Model.get(srcContext, (view as any).fk_model_id);
      if (!srcModel) NcError.badRequest('Shared view not found');
      await srcModel.getColumns(srcContext);
      if (!(view as any).allow_sync) {
        NcError.badRequest('Sync is not allowed on the shared view');
      }
      if (view.password) {
        if (!sharedViewPassword) {
          NcError.badRequest('This shared view is password protected');
        }
        const ok = await bcrypt.compare(sharedViewPassword, view.password);
        if (!ok) NcError.badRequest('Invalid shared view password');
        pastePasswordHash = view.password;
      }
      pasteUuid = uuid;
      sourceContext = srcContext;
      sourceModel = srcModel;
      sourceView = view as View;
    } else {
      const loaded = await this.loadSource(
        context,
        sourceBaseId,
        sourceTableId,
        req.user.id,
      );
      sourceContext = loaded.sourceContext;
      sourceModel = loaded.sourceModel;
      sourceView = await this.resolveSourceView(
        sourceContext,
        sourceModel,
        sourceViewId,
      );
    }

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
      // [CE-EE] F09 P2(lane obs): an empty array produced a zero-column
      // mirror — reject it explicitly
      if (!selectedFields.length) {
        NcError.badRequest(
          'selectedFields must not be empty — omit it to sync all fields',
        );
      }
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

    // [CE-EE] F09 P2(lane obs): creation is not atomic — a failure after the
    // mirror table exists (mapping insert, GVC patch, job enqueue) used to
    // strand an orphan synced table. Best-effort cleanup keeps the base clean.
    try {
      await mirrorModel.getColumns(context);

      // [CE-EE] F09 R1(lane5): hide the engine bookkeeping columns from the
      // mirror's default grid view (standard view-column show=false — works
      // regardless of the meta system flag path)
      const mirrorViews = (await View.list(context, mirrorModel.id)) as any[];
      const grid = (mirrorViews ?? []).find(
        (v: any) => v.view_type === ViewTypes.GRID || v.type === ViewTypes.GRID,
      );
      if (grid?.id) {
        const gcRows = (await GridViewColumn.list(context, grid.id)) as any[];
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
      // [CE-EE] F09 R2(lane5): invalidate the list key (PARENT_TO_CHILD) — the
      // previous model-scoped key never matched the actual cache entries
      // (COLUMN:<modelId>:list / COLUMN:<colId>) and was a silent no-op
      await NocoCache.deepDel(
        context,
        `${CacheScope.COLUMN}:${mirrorModel.id}:list`,
        CacheDelDirection.PARENT_TO_CHILD,
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
        source_input_mode: isPaste
          ? TableSyncInputMode.Paste
          : TableSyncInputMode.Browse,
        created_by: req.user.id,
      });

      const mainMapping = await this.insertMainMapping(
        context,
        sync,
        sourceContext,
        sourceModel,
        sourceView,
        mirrorModel,
        pasteUuid,
        pastePasswordHash,
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
            source_base_id: sourceContext.base_id,
            source_table_id: sourceModel.id,
            source_column_id: srcCol.id,
            dest_base_id: baseId,
            dest_table_id: mirrorModel.id,
            dest_column_id: destColByTitle.get(srcCol.title)?.id,
          }))
          .filter((r) => !!r.dest_column_id),
      );

      await this.enqueueSyncJob(context, sync, 'full-create', req);

      return this.getSync(context, baseId, sync.id);
    } catch (e) {
      // mirror exists but the sync could not be completed — remove it so the
      // base is not left with a stranded read-only table
      try {
        await this.tablesService.tableDelete(context, {
          tableId: mirrorModel.id,
          forceDeleteSyncs: true,
          req,
        });
      } catch {
        /* best effort — surface the original error either way */
      }
      throw e;
    }
  }

  private async insertMainMapping(
    context: NcContext,
    sync: TableSync,
    sourceContext: NcContext,
    sourceModel: Model,
    sourceView: View,
    mirrorModel: Model,
    pasteUuid?: string | null,
    pastePasswordHash?: string | null,
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
      // [CE-EE] F09 P2: paste mode persists the share-link credential —
      // uuid + bcrypt hash (never the plaintext password)
      ...(pasteUuid
        ? { source_uuid: pasteUuid, source_password_hash: pastePasswordHash }
        : {}),
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

    // [CE-EE] F09 P2: field-selection change propagation — add missing
    // mirror columns, drop removed ones (with their column mappings), then
    // persist the new selection. Runs only while active+idle (guards above).
    let selectedFieldsPatch: string[] | null | undefined;
    if (body?.selected_fields !== undefined) {
      if (
        body.selected_fields !== null &&
        (!Array.isArray(body.selected_fields) || !body.selected_fields.length)
      ) {
        NcError.badRequest(
          'selectedFields must be a non-empty array or null (all fields)',
        );
      }

      const mappings = await TableSync.listMappings(context, baseId, tableSyncId);
      const mainMapping = mappings.find(
        (m) => m.role === TableSyncMappingRole.Main,
      );
      if (!mainMapping?.dest_table_id) {
        NcError.badRequest('Main mapping is missing for this table sync');
      }
      const sourceContext: NcContext = {
        workspace_id: mainMapping.source_workspace_id,
        base_id: mainMapping.source_base_id,
      };
      const srcModel = await Model.get(sourceContext, mainMapping.source_table_id);
      if (!srcModel || srcModel.deleted) {
        NcError.badRequest(
          'Source table has been deleted — delete this sync and recreate it',
        );
      }
      await srcModel.getColumns(sourceContext);
      const destModel = await Model.get(context, mainMapping.dest_table_id);
      await destModel.getColumns(context);

      const mirrorable = this.getMirrorableColumns(srcModel);
      let desired: any[];
      if (body.selected_fields === null) {
        desired = mirrorable;
      } else {
        const available = new Set(mirrorable.map((c) => c.title));
        const unknown = (body.selected_fields as string[]).filter(
          (t) => !available.has(t),
        );
        if (unknown.length) {
          NcError.badRequest(
            `Fields cannot be synced (unsupported or unknown): ${unknown.join(', ')}`,
          );
        }
        desired = mirrorable.filter((c) =>
          (body.selected_fields as string[]).includes(c.title),
        );
      }
      if (!desired.length) {
        NcError.badRequest('The selection leaves the mirror table empty');
      }

      const colMappings = (await TableSync.listColumnMappings(
        context,
        baseId,
        tableSyncId,
      )) as any[];
      const srcColById = new Map(
        srcModel.columns.map((c: any) => [c.id, c]),
      );
      const destColById = new Map(destModel.columns.map((c: any) => [c.id, c]));
      const mappedSrcIds = new Set(colMappings.map((m) => m.source_column_id));
      const desiredSrcIds = new Set(desired.map((c: any) => c.id));

      // drops: mapped source columns leaving the selection → drop the mirror
      // column (forceDeleteSystem bypasses the synced-column delete guard —
      // the sync handler is the authority) + remove the mapping row
      for (const m of colMappings) {
        if (desiredSrcIds.has(m.source_column_id)) continue;
        const destCol = destColById.get(m.dest_column_id);
        if (destCol) {
          await this.columnsService.columnDelete(context, {
            req,
            columnId: destCol.id,
            forceDeleteSystem: true,
            skipTrash: true,
          });
        }
        // [CE-EE] F09 P2-R1(lane1 E2): listColumnMappings does not select
        // the id column — key the delete on (sync, source_column_id) instead
        await Noco.ncMeta.knex(MetaTable.TABLE_SYNC_COLUMN_MAPPINGS)
          .where({
            fk_table_sync_id: tableSyncId,
            source_column_id: m.source_column_id,
          })
          .del();
      }

      // adds: desired source columns not yet mapped → create the mirror
      // column (readonly) + insert the mapping row
      const toAdd = desired.filter((c: any) => !mappedSrcIds.has(c.id));
      for (const srcCol of toAdd) {
        // [CE-EE] F09 P2-R1(lane5 E4): columnAdd resolves to the refreshed
        // Model, not a Column — pull the created column off .columns by title
        const addedModel: any = await this.columnsService.columnAdd(context, {
          req,
          tableId: mainMapping.dest_table_id,
          user: req.user,
          column: {
            title: srcCol.title,
            column_name: srcCol.column_name || srcCol.title,
            uidt: srcCol.uidt,
            dt: srcCol.dt,
            readonly: true,
          } as any,
        });
        const addedCol: any = (addedModel?.columns ?? []).find(
          (c: any) => c.title === srcCol.title,
        );
        if (!addedCol?.id) {
          NcError.badRequest(
            `Failed to create mirror column for "${srcCol.title}"`,
          );
        }
        // columnAdd drops the readonly flag on the custom payload — force it
        // via direct meta (same pattern as the R1 system:true patch)
        if (!addedCol.readonly) {
          await Noco.ncMeta.metaUpdate(
            context.workspace_id,
            context.base_id,
            MetaTable.COLUMNS,
            { readonly: true },
            addedCol.id,
          );
        }
        await TableSync.insertColumnMappings(context, [
          {
            base_id: baseId,
            fk_workspace_id: context.workspace_id,
            fk_table_sync_id: tableSyncId,
            fk_table_sync_mapping_id: mainMapping.id,
            source_workspace_id: mainMapping.source_workspace_id,
            source_base_id: mainMapping.source_base_id,
            source_table_id: mainMapping.source_table_id,
            source_column_id: srcCol.id,
            dest_base_id: baseId,
            dest_table_id: mainMapping.dest_table_id,
            dest_column_id: addedCol?.id,
          } as any,
        ]);
      }

      selectedFieldsPatch =
        body.selected_fields === null ? null : (body.selected_fields as string[]);
    }

    const patch: Record<string, any> = { updated_by: req.user.id };
    if (selectedFieldsPatch !== undefined) {
      patch.selected_fields = selectedFieldsPatch;
    }
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

    // [CE-EE] F09 P2(lane5 O1): re-validate the source before each run —
    // allow_sync must still be on, and browse-mode callers must still read
    // the source (paste mode rides its persisted share credential instead)
    const mappings = await TableSync.listMappings(context, baseId, tableSyncId);
    const mainMapping = mappings.find(
      (m) => m.role === TableSyncMappingRole.Main,
    );
    if (!mainMapping) {
      NcError.badRequest('Main mapping is missing for this table sync');
    }
    const sourceContext: NcContext = {
      workspace_id: mainMapping.source_workspace_id,
      base_id: mainMapping.source_base_id,
    };
    const sourceView = await View.get(sourceContext, mainMapping.source_view_id);
    if (!sourceView || !(sourceView as any).allow_sync) {
      NcError.badRequest(
        'Sync is no longer allowed on the source view (allow sync is off)',
      );
    }
    if (sync.source_input_mode !== TableSyncInputMode.Paste) {
      await this.assertSourceReadAccess(
        sourceContext,
        mainMapping.source_base_id,
        req.user.id,
      );
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

  /** [CE-EE] F09 P2: paste-mode link resolution — parse a shared view URL,
   *  verify allow_sync (+ optional bcrypt password) and return the source
   *  coordinates for the wizard's next step. */
  async resolveLink(context: NcContext, _baseId: string, body: any) {
    const uuid = this.extractSharedViewUuid(
      body?.sharedViewUrl || body?.sourceViewUuid,
    );
    if (!uuid) {
      NcError.badRequest('A valid shared view URL or uuid is required');
    }
    const view = await View.getByUUID(context, uuid);
    if (!view) NcError.badRequest('Shared view not found');
    if (!(view as any).allow_sync) {
      NcError.badRequest('Sync is not allowed on the shared view');
    }
    let passwordProtected = false;
    if (view.password) {
      passwordProtected = true;
      // [CE-EE] F09 P2-R1(lane5 M1): without the password, leak nothing —
      // only the passwordProtected flag leaves the endpoint
      if (!body?.sharedViewPassword) {
        return { passwordProtected: true };
      }
      const ok = await bcrypt.compare(body.sharedViewPassword, view.password);
      if (!ok) NcError.badRequest('Invalid shared view password');
      passwordProtected = false;
    }
    const srcModel = await Model.get(
      {
        workspace_id: (view as any).fk_workspace_id || context.workspace_id,
        base_id: (view as any).base_id,
      },
      (view as any).fk_model_id,
    );
    if (!srcModel) NcError.badRequest('Shared view not found');
    return {
      sourceInputMode: TableSyncInputMode.Paste,
      sourceBaseId: (view as any).base_id,
      sourceTableId: (view as any).fk_model_id,
      sourceViewId: (view as any).id,
      sourceTableTitle: srcModel.title,
      sourceViewTitle: (view as any).title,
      passwordProtected,
    };
  }

  /** [CE-EE] F09 P2: convert the mirror into a regular editable table —
   *  synced=false, readonly flags lifted, sync + mappings removed; the
   *  mirror table and its rows stay. Mirrors the detach SQL of
   *  nc_202606121400. */
  async detachSync(
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
      NcError.badRequest('Cannot detach a sync while it is running');
    }

    const mappings = await TableSync.listMappings(context, baseId, tableSyncId);
    const mainMapping = mappings.find(
      (m) => m.role === TableSyncMappingRole.Main,
    );
    if (!mainMapping?.dest_table_id) {
      NcError.badRequest('Main mapping is missing for this table sync');
    }
    const destTableId = mainMapping.dest_table_id;

    // flips nc_models.synced=false — the synced guard chain keys off this
    await Model.updateSynced(context, destTableId, false);

    // lift the readonly flag on every mirror column (direct meta — same
    // pattern as the P1 system:true patch; Column.update's whitelist drops
    // the flag silently)
    const mirrorColumnRows = (await Noco.ncMeta.metaList2(
      context.workspace_id,
      context.base_id,
      MetaTable.COLUMNS,
      { condition: { fk_model_id: destTableId } },
    )) as any[];
    for (const colRow of mirrorColumnRows) {
      if (colRow.readonly) {
        await Noco.ncMeta.metaUpdate(
          context.workspace_id,
          context.base_id,
          MetaTable.COLUMNS,
          { readonly: false },
          colRow.id,
        );
      }
    }
    await NocoCache.deepDel(
      context,
      `${CacheScope.COLUMN}:${destTableId}:list`,
      CacheDelDirection.PARENT_TO_CHILD,
    );

    // remove the sync + its mappings; the table survives as regular
    await TableSync.deleteColumnMappings(context, baseId, tableSyncId);
    await TableSync.delete(context, baseId, tableSyncId);

    return { ok: true, tableId: destTableId };
  }
}
