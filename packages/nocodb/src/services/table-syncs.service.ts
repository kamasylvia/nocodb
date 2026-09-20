import { Inject, Injectable } from '@nestjs/common';
import NocoCache from '~/cache/NocoCache';
import {
  isVirtualCol,
  ProjectRoles,
  RelationTypes,
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
import type { Column, LinkToAnotherRecordColumn } from '~/models';
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
// [CE-EE] F09 P3: realtime dispatch implementation (see notifySourceChange note)
import {
  enqueueCatchUpIfNeeded,
  notifySourceChange as notifySourceChangeImpl,
} from '~/helpers/table-sync-realtime';

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

const SYNC_LINK_UIDTS: (UITypes | string)[] = [
  UITypes.Links,
  UITypes.LinkToAnotherRecord,
];

/** [CE-EE] F09 P4: LTAR link columns are synced via the three-layer scheme
 *  (main mirror link column + LinkedShadow + Junction) instead of being
 *  rejected like the other virtual uidts. */
export function isSyncLinkColumnUidt(uidt?: UITypes | string): boolean {
  return uidt != null && SYNC_LINK_UIDTS.includes(uidt);
}

@Injectable()
export class TableSyncsService {
  constructor(
    protected readonly tablesService: TablesService,
    protected readonly columnsService: ColumnsService,
    @Inject('JobsService') protected readonly jobsService: IJobsService,
  ) {}

  /** [CE-EE] F09 P3: realtime table-sync dispatch — enqueues one incremental
   *  run per active realtime sync sourcing the touched table. Static because
   *  the BaseModelSqlv2 after* taps have no DI; the implementation lives in
   *  ~/helpers/table-sync-realtime (dependency-free — importing this service
   *  from BaseModelSqlv2 would create a value-level import cycle
   *  service -> tables.service -> Model -> BaseModelSqlv2) and resolves the
   *  jobs service through the bootstrapped app context (Noco.nestApp). */
  static notifySourceChange(
    sourceContext: NcContext,
    sourceModelId: string,
    event:
      | 'insert'
      | 'update'
      | 'bulkUpdate'
      | 'delete'
      | 'bulkDelete',
    rowIds: (string | number)[],
  ): Promise<void> {
    return notifySourceChangeImpl(sourceContext, sourceModelId, event, rowIds);
  }

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

  // ──────────────────────────────────────────────────────────────────────
  // [CE-EE] F09 P4: LTAR link layers (LinkedShadow + Junction)
  // ──────────────────────────────────────────────────────────────────────

  /** The syncable mm link columns of the source table. Only
   *  junction-based (mm) links between the source table and a regular,
   *  same-base, non-self related table are supported — everything else
   *  stays outside the selectable set and keeps the P1 "unknown/unsupported
   *  field" rejection when explicitly named (fork simplifications). */
  private async loadSyncableLinks(
    sourceContext: NcContext,
    sourceModel: Model,
  ): Promise<
    { column: Column; colOptions: LinkToAnotherRecordColumn; relatedModelId: string }[]
  > {
    const links: {
      column: Column;
      colOptions: LinkToAnotherRecordColumn;
      relatedModelId: string;
    }[] = [];
    for (const col of sourceModel.columns || []) {
      if (!isSyncLinkColumnUidt(col.uidt)) continue;
      const colOptions = await (col as Column).getColOptions<LinkToAnotherRecordColumn>(
        sourceContext,
      );
      if (!colOptions) continue;
      if (colOptions.type !== RelationTypes.MANY_TO_MANY) continue;
      if (!colOptions.fk_mm_model_id || !colOptions.fk_related_model_id)
        continue;
      const related = await Model.get(sourceContext, colOptions.fk_related_model_id);
      if (!related || related.deleted || related.type !== 'table') continue;
      if (related.id === sourceModel.id) continue;
      if (related.base_id !== sourceModel.base_id) continue;
      links.push({ column: col as Column, colOptions, relatedModelId: related.id });
    }
    return links;
  }

  /** Generic nc_table_sync_mappings row insert (all roles). */
  private async insertTableSyncMapping(
    context: NcContext,
    payload: Record<string, any>,
  ) {
    const { id } = await Noco.ncMeta.metaInsert2(
      context.workspace_id,
      context.base_id,
      MetaTable.TABLE_SYNC_MAPPINGS,
      payload,
    );
    return { ...payload, id } as any;
  }

  /** Post-create setup shared by every mirror table (main + shadows):
   *  hide the engine system columns from the default grid view and force
   *  the `system` meta flag so isHiddenCol hides them. (P1/R1 logic,
   *  extracted in P4 so shadows get identical treatment.) */
  private async setupMirrorSystemColumns(
    context: NcContext,
    mirrorModel: Model,
  ) {
    await mirrorModel.getColumns(context);

    const mirrorViews = (await View.list(context, mirrorModel.id)) as any[];
    const grid = (mirrorViews ?? []).find(
      (v: any) => v.view_type === ViewTypes.GRID || v.type === ViewTypes.GRID,
    );
    if (grid?.id) {
      const gcRows = (await GridViewColumn.list(context, grid.id)) as any[];
      const sysColIds = (mirrorModel.columns ?? [])
        .filter(
          (c: any) => c.title === 'RemoteId' || c.title === 'RemoteDeleted',
        )
        .map((c: any) => c.id);
      for (const gc of gcRows ?? []) {
        if (sysColIds.includes(gc.fk_column_id)) {
          await GridViewColumn.update(context, gc.id, { show: false });
        }
      }
    }

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
      `${CacheScope.COLUMN}:${mirrorModel.id}:list`,
      CacheDelDirection.PARENT_TO_CHILD,
    );
  }

  /** Create (once per related table) the LinkedShadow mirror for RT and
   *  register its mapping + column mappings. */
  private async ensureShadowForRelated(args: {
    context: NcContext;
    sourceContext: NcContext;
    sync: TableSync;
    relatedModelId: string;
    destSourceId: string;
    takenTitles: Set<string>;
    req: NcRequest;
    shadows: Map<string, { model: Model; mapping: any }>;
  }) {
    const {
      context,
      sourceContext,
      sync,
      relatedModelId,
      destSourceId,
      takenTitles,
      req,
      shadows,
    } = args;
    const existing = shadows.get(relatedModelId);
    if (existing) return existing;

    const rtModel = await Model.get(sourceContext, relatedModelId);
    if (!rtModel || rtModel.deleted) {
      NcError.tableNotFound(relatedModelId);
    }
    await rtModel.getColumns(sourceContext);

    const rtMirrorable = this.getMirrorableColumns(rtModel);
    const shadowColumnsPayload = [
      ...rtMirrorable.map((c) => ({
        title: c.title,
        column_name: c.column_name || c.title,
        uidt: c.uidt,
        dt: c.dt,
        readonly: true,
      })),
      ...TABLE_SYNC_SYSTEM_COLUMNS.map((c) => ({
        title: c.title,
        column_name: c.title.toLowerCase(),
        uidt: c.uidt,
        readonly: true,
        system: true,
      })),
    ];

    const destTables = await Model.list(context, {
      base_id: context.base_id,
      source_id: destSourceId,
    });
    const shadowTitle = generateUniqueName(
      `${sync.title} ${rtModel.title}`,
      destTables.map((t: any) => t.title).concat([...takenTitles]),
    );
    takenTitles.add(shadowTitle);

    const shadowModel = (await this.tablesService.tableCreate(context, {
      baseId: context.base_id,
      sourceId: destSourceId,
      user: req.user,
      req,
      synced: true,
      table: {
        title: shadowTitle,
        table_name: shadowTitle,
        columns: shadowColumnsPayload as any,
      } as any,
    })) as Model;

    const shadowMapping = await this.insertTableSyncMapping(context, {
      base_id: context.base_id,
      fk_workspace_id: context.workspace_id,
      fk_table_sync_id: sync.id,
      source_workspace_id: sourceContext.workspace_id,
      source_base_id: sourceContext.base_id,
      source_table_id: rtModel.id,
      // linked shadows ride the main sync's allow_sync credential — no
      // per-shadow view requirement
      source_view_id: null,
      dest_base_id: context.base_id,
      dest_table_id: shadowModel.id,
      role: TableSyncMappingRole.LinkedShadow,
    });

    await this.setupMirrorSystemColumns(context, shadowModel);

    // shadow column identity: RT scalar col id → shadow col id
    const shadowColByTitle = new Map(
      (shadowModel.columns || []).map((c) => [c.title, c]),
    );
    await TableSync.insertColumnMappings(
      context,
      rtMirrorable
        .map((srcCol) => ({
          base_id: context.base_id,
          fk_workspace_id: context.workspace_id,
          fk_table_sync_id: sync.id,
          fk_table_sync_mapping_id: shadowMapping.id,
          source_workspace_id: sourceContext.workspace_id,
          source_base_id: sourceContext.base_id,
          source_table_id: rtModel.id,
          source_column_id: srcCol.id,
          dest_base_id: context.base_id,
          dest_table_id: shadowModel.id,
          dest_column_id: shadowColByTitle.get(srcCol.title)?.id,
        }))
        .filter((r) => !!r.dest_column_id),
    );

    const entry = { model: shadowModel, mapping: shadowMapping };
    shadows.set(relatedModelId, entry);
    return entry;
  }

  /** Create the mirror link column on the main mirror (CE-native mm path:
   *  columnAdd also builds the junction + the reverse column on the shadow)
   *  and flip the junction to synced semantics. Returns the dest link
   *  column + junction model id. */
  private async addMirrorLinkColumn(args: {
    context: NcContext;
    sync: TableSync;
    mainMirrorId: string;
    shadowModelId: string;
    srcLinkCol: Column;
    req: NcRequest;
  }) {
    const { context, mainMirrorId, shadowModelId, srcLinkCol, req } = args;

    const addedModel: any = await this.columnsService.columnAdd(context, {
      req,
      tableId: mainMirrorId,
      user: req.user,
      column: {
        title: srcLinkCol.title,
        uidt: srcLinkCol.uidt,
        type: RelationTypes.MANY_TO_MANY,
        parentId: mainMirrorId,
        childId: shadowModelId,
        readonly: true,
      } as any,
    });
    const addedCol: any = (addedModel?.columns ?? []).find(
      (c: any) => c.title === srcLinkCol.title,
    );
    if (!addedCol?.id) {
      NcError.badRequest(
        `Failed to create mirrored link column "${srcLinkCol.title}"`,
      );
    }
    // the generic link-column insert drops the readonly flag — force it via
    // direct meta (same pattern as the P1 system:true / P2 readonly patches)
    if (!addedCol.readonly) {
      await Noco.ncMeta.metaUpdate(
        context.workspace_id,
        context.base_id,
        MetaTable.COLUMNS,
        { readonly: true },
        addedCol.id,
      );
    }

    const linkOpt = await (addedCol as Column).getColOptions<LinkToAnotherRecordColumn>(
      context,
    );
    const junctionModelId = linkOpt?.fk_mm_model_id;
    if (!junctionModelId) {
      NcError.badRequest(
        `Failed to resolve junction for mirrored link column "${srcLinkCol.title}"`,
      );
    }

    // junction becomes a synced table: the whole read-only guard chain
    // engages and the engine writes pairs through its internal channel only
    await Model.updateSynced(context, junctionModelId, true);

    return { addedCol, junctionModelId };
  }

  /** [CE-EE] F09 P4: removeSyncedLinkFieldDropsJunctionShadow — dropping a
   *  mirrored link column also drops its junction table and the mapping
   *  rows. The shadow is handled separately (dropShadowForRelated) so it
   *  survives while another link column still references the same table. */
  private async dropMirrorLinkColumn(args: {
    context: NcContext;
    baseId: string;
    tableSyncId: string;
    destModel: Model;
    linkMapping: any;
    req: NcRequest;
  }) {
    const { context, tableSyncId, destModel, linkMapping, req } = args;

    const destLinkCol: any = (destModel.columns || []).find(
      (c: any) => c.id === linkMapping.dest_column_id,
    );
    let junctionId: string | null = null;
    if (destLinkCol) {
      const opt = await (destLinkCol as Column).getColOptions<LinkToAnotherRecordColumn>(
        context,
      );
      junctionId = opt?.fk_mm_model_id ?? null;
      await this.columnsService.columnDelete(context, {
        req,
        columnId: destLinkCol.id,
        forceDeleteSystem: true,
        skipTrash: true,
      });
    }
    // drop the junction table (synced semantics — the sync handler is the
    // authority; forceDeleteSyncs bypasses the guard the same way deleteSync
    // removes the mirror itself)
    if (junctionId) {
      try {
        await this.tablesService.tableDelete(context, {
          tableId: junctionId,
          forceDeleteSyncs: true,
          req,
        });
      } catch {
        /* already gone — keep cascading */
      }
      await Noco.ncMeta.knex(MetaTable.TABLE_SYNC_MAPPINGS)
        .where({
          fk_table_sync_id: tableSyncId,
          role: TableSyncMappingRole.Junction,
          dest_table_id: junctionId,
        })
        .del();
    }
    // remove the link column identity mapping
    await Noco.ncMeta.knex(MetaTable.TABLE_SYNC_COLUMN_MAPPINGS)
      .where({
        fk_table_sync_id: tableSyncId,
        source_column_id: linkMapping.source_column_id,
      })
      .del();
  }

  /** [CE-EE] F09 P4: drop a LinkedShadow table + its mapping and column
   *  mappings — called when the last referencing link column leaves the
   *  selection. */
  private async dropShadowForRelated(args: {
    context: NcContext;
    baseId: string;
    tableSyncId: string;
    relatedModelId: string;
    req: NcRequest;
  }) {
    const { context, baseId, tableSyncId, relatedModelId, req } = args;
    const mappings = await TableSync.listMappings(context, baseId, tableSyncId);
    const shadowMapping: any = (mappings as any[]).find(
      (m) =>
        m.role === TableSyncMappingRole.LinkedShadow &&
        m.source_table_id === relatedModelId,
    );
    if (!shadowMapping) return;
    try {
      await this.tablesService.tableDelete(context, {
        tableId: shadowMapping.dest_table_id,
        forceDeleteSyncs: true,
        req,
      });
    } catch {
      /* already gone — keep deleting the registration rows */
    }
    await Noco.ncMeta.knex(MetaTable.TABLE_SYNC_COLUMN_MAPPINGS)
      .where({
        fk_table_sync_id: tableSyncId,
        fk_table_sync_mapping_id: shadowMapping.id,
      })
      .del();
    await Noco.ncMeta.knex(MetaTable.TABLE_SYNC_MAPPINGS)
      .where({ id: shadowMapping.id })
      .del();
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
      // [CE-EE] F09 P4-R1(lane3b E2): link columns are NOT offered in paste
      // mode — the paste credential is a single-view exposure and link sync
      // reads whole related tables (createSync rejects them with 400, so
      // listing them here would only set the wizard up for a dead end)
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
        columns: mirrorable
          .map((c) => ({
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
    // [CE-EE] F09 P4: syncable mm link columns for the wizard selection list
    const syncableLinks = await this.loadSyncableLinks(sourceContext, sourceModel);
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
      // [CE-EE] F09 P4: syncable mm link columns are offered with a link
      // flag (the wizard renders titles, so no UI change is required)
      columns: mirrorable
        .map((c) => ({
          id: c.id,
          title: c.title,
          uidt: c.uidt,
        }))
        .concat(
          syncableLinks.map((l) => ({
            id: l.column.id,
            title: l.column.title,
            uidt: l.column.uidt,
            link: true,
          })),
        ),
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

    // [CE-EE] F09: FEATURE_TABLE_SYNC covered the manual trigger only until
    // P3 unlocked realtime (FEATURE_TABLE_SYNC_AUTO) — both triggers are now
    // accepted; anything else is still rejected
    if (
      syncTrigger &&
      syncTrigger !== TableSyncTrigger.Manual &&
      syncTrigger !== TableSyncTrigger.Realtime
    ) {
      NcError.badRequest(`Invalid sync trigger: ${syncTrigger}`);
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
    // [CE-EE] F09 P4: mm link columns are selectable — they build the
    // three-layer structure (mirror link column + shadow + junction)
    const syncableLinks = await this.loadSyncableLinks(
      sourceContext,
      sourceModel,
    );
    const colliding = mirrorable.find(
      (c) => reservedNames.has(c.title) || reservedNames.has(c.column_name),
    );
    if (colliding) {
      NcError.badRequest(
        `Source table column "${colliding.title}" uses a name reserved for sync system columns`,
      );
    }

    // field selection: null = all (current + future), array = whitelist by
    // title. Non-mm / self / cross-base links stay out of the selectable set
    // and keep the P1 "unsupported or unknown" rejection when named.
    let selectedFieldsFinal: string[] | null = null;
    if (Array.isArray(selectedFields)) {
      // [CE-EE] F09 P2(lane obs): an empty array produced a zero-column
      // mirror — reject it explicitly
      if (!selectedFields.length) {
        NcError.badRequest(
          'selectedFields must not be empty — omit it to sync all fields',
        );
      }
      const available = new Set(
        mirrorable
          .map((c) => c.title)
          .concat(syncableLinks.map((l) => l.column.title)),
      );
      const unknown = selectedFields.filter((t) => !available.has(t));
      if (unknown.length) {
        NcError.badRequest(
          `Fields cannot be synced (unsupported or unknown): ${unknown.join(', ')}`,
        );
      }
      selectedFieldsFinal = selectedFields;
    }
    // [CE-EE] F09 P4: the link columns this sync mirrors (all of them when
    // selectedFields is null)
    const selectedLinks = selectedFieldsFinal
      ? syncableLinks.filter((l) => selectedFieldsFinal!.includes(l.column.title))
      : syncableLinks;

    // [CE-EE] F09 P4-R1(lane3b E2, security ruling = reject): paste-mode
    // credentials are a single-view exposure — the share link authorizes
    // THIS view only, while link sync pulls the whole related tables
    // (shadow tables ride the main credential with source_view_id=null).
    // Allowing links would upgrade a shared-view token into full-table read
    // access on tables the paste credential never covered. Link sync stays
    // browse-only (the creator there already holds source read access).
    if (isPaste && selectedLinks.length) {
      NcError.badRequest(
        'Linked fields cannot be synced from a pasted shared view: the share credential only exposes this single view, while syncing linked fields reads the related tables. Create the sync in browse mode to include linked fields.',
      );
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
    const createdDestTableIds: string[] = [mirrorModel.id];
    try {
      // [CE-EE] F09 P4: mirror system-column setup extracted (shared with
      // shadow tables) — GVC hide + system flag patch + cache invalidation
      await this.setupMirrorSystemColumns(context, mirrorModel);

      const sync = await TableSync.insert(context, {
        base_id: baseId,
        fk_workspace_id: context.workspace_id,
        title: mirrorTitle,
        selected_fields: selectedFieldsFinal,
        on_delete_action:
          onDeleteAction || TableSyncOnDeleteAction.Delete,
        // [CE-EE] F09 P3: manual (default) or realtime — realtime syncs get
        // incremental runs on source changes via the BaseModelSqlv2 taps
        sync_trigger: (syncTrigger as TableSyncTrigger) || TableSyncTrigger.Manual,
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

      // [CE-EE] F09 P4: the three link layers — LinkedShadow mirror per
      // related table, mirror link column (+ CE-native junction) on the
      // main mirror with synced semantics, junction mapping rows and the
      // link column identity mapping. Built BEFORE the first full-create
      // run so the engine sees the complete structure.
      if (selectedLinks.length) {
        const destSourceId = destBase.sources[0].id;
        const takenTitles = new Set<string>([mirrorTitle]);
        const shadows = new Map<string, { model: Model; mapping: any }>();
        for (const link of selectedLinks) {
          const shadow = await this.ensureShadowForRelated({
            context,
            sourceContext,
            sync,
            relatedModelId: link.relatedModelId,
            destSourceId,
            takenTitles,
            req,
            shadows,
          });
          createdDestTableIds.push(shadow.model.id);

          const { addedCol, junctionModelId } = await this.addMirrorLinkColumn({
            context,
            sync,
            mainMirrorId: mirrorModel.id,
            shadowModelId: shadow.model.id,
            srcLinkCol: link.column,
            req,
          });
          createdDestTableIds.push(junctionModelId);

          // junction mapping — source_* stay null (EE junction semantics:
          // the pairing lives in the RemoteId pairs, not a source table)
          await this.insertTableSyncMapping(context, {
            base_id: baseId,
            fk_workspace_id: context.workspace_id,
            fk_table_sync_id: sync.id,
            dest_base_id: baseId,
            dest_table_id: junctionModelId,
            role: TableSyncMappingRole.Junction,
          });

          // link column identity (main mapping scope): source link col →
          // dest link col; the engine derives junction/shadow from it
          await TableSync.insertColumnMappings(context, [
            {
              base_id: baseId,
              fk_workspace_id: context.workspace_id,
              fk_table_sync_id: sync.id,
              fk_table_sync_mapping_id: mainMapping.id,
              source_workspace_id: sourceContext.workspace_id,
              source_base_id: sourceContext.base_id,
              source_table_id: sourceModel.id,
              source_column_id: link.column.id,
              dest_base_id: baseId,
              dest_table_id: mirrorModel.id,
              dest_column_id: addedCol.id,
            } as any,
          ]);
        }
      }

      await this.enqueueSyncJob(context, sync, 'full-create', req);

      return this.getSync(context, baseId, sync.id);
    } catch (e) {
      // any structure created before the failure is removed so the base is
      // not left with stranded synced tables (mirror / shadows / junctions).
      // [CE-EE] F09 P4-R1(lane5 obs): delete in REVERSE creation order —
      // junctions hold FKs to the mirror and the shadows, so removing the
      // mirror first made the junction delete the only survivor of the
      // best-effort pass on PG
      for (const tableId of [...createdDestTableIds].reverse()) {
        try {
          await this.tablesService.tableDelete(context, {
            tableId,
            forceDeleteSyncs: true,
            req,
          });
        } catch {
          /* best effort — surface the original error either way */
        }
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
      selected_fields?: string[] | null;
      /** [CE-EE] F09 P2-R3(lane2): camelCase alias — the wizard sends
       * camelCase; a silent no-op on the snake_case-only reader was a
       * repeated review finding */
      selectedFields?: string[] | null;
    },
    req: NcRequest,
  ) {
    // [CE-EE] F09 P2-R3(lane2): normalize the camelCase alias up front
    if (body?.selected_fields === undefined && body?.selectedFields !== undefined) {
      body.selected_fields = body.selectedFields;
    }
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
    // [CE-EE] F09 P4-R1: true when this PATCH added/dropped columns or link
    // layers — drives the post-patch full-resync data backfill
    let structureChangedRecently = false;
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
      // [CE-EE] F09 P4: syncable mm link columns join the selectable set —
      // adds build the three layers, drops cascade junction + orphan shadow
      const syncableLinks = await this.loadSyncableLinks(sourceContext, srcModel);
      let desiredLinks = syncableLinks;
      let desired: any[];
      if (body.selected_fields === null) {
        desired = mirrorable;
      } else {
        const available = new Set(
          mirrorable
            .map((c) => c.title)
            .concat(syncableLinks.map((l) => l.column.title)),
        );
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
        desiredLinks = syncableLinks.filter((l) =>
          (body.selected_fields as string[]).includes(l.column.title),
        );
      }
      if (!desired.length && !desiredLinks.length) {
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
      // [CE-EE] F09 P4-R1(lane4b E1): only the MAIN mapping scope drives the
      // mirror-column lifecycle — rows under a linked_shadow mapping are the
      // shadow's own column identities and are managed by the shadow
      // lifecycle (ensure/dropShadowForRelated), never by this loop. The old
      // unfiltered loop silently deleted shadow column-identity rows.
      const mainColMappings = colMappings.filter(
        (m) => m.fk_table_sync_mapping_id === mainMapping.id,
      );
      const mappedSrcIds = new Set(mainColMappings.map((m) => m.source_column_id));
      const desiredSrcIds = new Set(desired.map((c: any) => c.id));
      // [CE-EE] F09 P4-R1(lane1/3b/4b/5 E1): link mappings are kept / dropped
      // by the DESIRED LINK set — desiredSrcIds never contains link columns
      // (they are virtual, excluded by isMirrorableSourceColumn), so the old
      // desiredSrcIds-only test classified every mapped link as dropped and
      // tore down its junction + shadow on every selection PATCH, even when
      // the link was still selected. null selection = all fields INCLUDING
      // the existing links (desiredLinks stays = all syncable links).
      const desiredLinkSrcIds = new Set(
        desiredLinks.map((l) => l.column.id),
      );

      // [CE-EE] F09 P4: related tables still referenced by KEPT link columns
      // — a shadow is only dropped when its last referencing link leaves
      // (now derived from the desired links instead of the dead
      // desiredSrcIds-join that always produced an empty set)
      const keptLinkRtIds = new Set<string>(
        desiredLinks.map((l) => l.relatedModelId),
      );

      let structureChanged = false;

      // drops: mapped source columns leaving the selection → drop the mirror
      // column (forceDeleteSystem bypasses the synced-column delete guard —
      // the sync handler is the authority) + remove the mapping row.
      // Link-typed drops cascade: junction table first, then the shadow if
      // orphaned (removeSyncedLinkFieldDropsJunctionShadow semantics). Link
      // mappings whose source column is still in the desired links are KEPT.
      for (const m of mainColMappings) {
        if (desiredSrcIds.has(m.source_column_id)) continue;
        if (desiredLinkSrcIds.has(m.source_column_id)) continue;
        const srcCol: any = srcColById.get(m.source_column_id);
        if (srcCol && isSyncLinkColumnUidt(srcCol.uidt)) {
          const opt = await (srcCol as Column).getColOptions<LinkToAnotherRecordColumn>(
            sourceContext,
          );
          const relatedModelId = opt?.fk_related_model_id ?? null;
          await this.dropMirrorLinkColumn({
            context,
            baseId,
            tableSyncId,
            destModel,
            linkMapping: m,
            req,
          });
          if (relatedModelId && !keptLinkRtIds.has(relatedModelId)) {
            await this.dropShadowForRelated({
              context,
              baseId,
              tableSyncId,
              relatedModelId,
              req,
            });
          }
          structureChanged = true;
          continue;
        }
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
        structureChanged = true;
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
      if (toAdd.length) {
        structureChanged = true;
      }

      // [CE-EE] F09 P4: link adds — build shadow (+ junction) layers for
      // newly selected link columns (shared with the createSync flow).
      // [CE-EE] F09 P4-R1(lane3b M1 / lane4b M2 / lane5 M1): the shadows map
      // and taken titles are hoisted OUT of the loop and SEEDED with the
      // existing linked_shadow mappings — a second link column pointing at
      // the same related table must reuse that table's shadow (fresh maps
      // per iteration built one shadow per link, and the engine's
      // shadowRemoteToPkBySource is keyed by source table id, so dual
      // shadows made the second one silently win and mis-key junction pairs).
      const toAddLinks = desiredLinks.filter(
        (l) => !mappedSrcIds.has(l.column.id),
      );
      if (toAddLinks.length) {
        const destSourceId = (destModel as any).source_id;
        const takenTitles = new Set<string>();
        const shadows = new Map<string, { model: Model; mapping: any }>();
        for (const m of mappings as any[]) {
          if (m.role !== TableSyncMappingRole.LinkedShadow) continue;
          if (shadows.has(m.source_table_id)) continue;
          const existingModel = await Model.get(context, m.dest_table_id);
          if (!existingModel || existingModel.deleted) continue;
          await existingModel.getColumns(context);
          shadows.set(m.source_table_id, { model: existingModel, mapping: m });
        }
        for (const link of toAddLinks) {
          const shadow = await this.ensureShadowForRelated({
            context,
            sourceContext,
            sync,
            relatedModelId: link.relatedModelId,
            destSourceId,
            takenTitles,
            req,
            shadows,
          });
          const { addedCol, junctionModelId } = await this.addMirrorLinkColumn({
            context,
            sync,
            mainMirrorId: mainMapping.dest_table_id,
            shadowModelId: shadow.model.id,
            srcLinkCol: link.column,
            req,
          });
          await this.insertTableSyncMapping(context, {
            base_id: baseId,
            fk_workspace_id: context.workspace_id,
            fk_table_sync_id: tableSyncId,
            dest_base_id: baseId,
            dest_table_id: junctionModelId,
            role: TableSyncMappingRole.Junction,
          });
          await TableSync.insertColumnMappings(context, [
            {
              base_id: baseId,
              fk_workspace_id: context.workspace_id,
              fk_table_sync_id: tableSyncId,
              fk_table_sync_mapping_id: mainMapping.id,
              source_workspace_id: mainMapping.source_workspace_id,
              source_base_id: mainMapping.source_base_id,
              source_table_id: mainMapping.source_table_id,
              source_column_id: link.column.id,
              dest_base_id: baseId,
              dest_table_id: mainMapping.dest_table_id,
              dest_column_id: addedCol.id,
            } as any,
          ]);
        }
        structureChanged = true;
      }

      selectedFieldsPatch =
        body.selected_fields === null ? null : (body.selected_fields as string[]);
      // [CE-EE] F09 P4-R1(lane1 E1④): remember whether the structure moved —
      // the data backfill job is enqueued after the selection patch persists
      structureChangedRecently = structureChanged;
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

    // [CE-EE] F09 P4-R1(lane1 E1④): any structural change (columns or link
    // layers added / dropped) is followed by one full-resync so the new
    // layers get their data backfill instead of sitting empty until the next
    // manual sync. Persisted BEFORE the enqueue so the engine job reads the
    // new selected_fields.
    if (structureChangedRecently) {
      await this.enqueueSyncJob(context, sync, 'full-resync', req);
    }

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

    // [CE-EE] F09 P4: every table the sync created goes — junctions and
    // shadows first, then the main mirror (trash semantics via
    // forceDeleteSyncs, the same authority path deleteSync always had).
    // Best-effort per table: an already-removed structure must not block
    // the sync deletion.
    // [CE-EE] F09 P4-R1(lane3b M3): the MAIN mirror is not best-effort — if
    // its delete fails while the sync row is removed, the surviving synced
    // table becomes a permanent read-only zombie (tables.service blocks
    // writes and deletes, and there is no sync left to detach). Abort with
    // the original error and KEEP the sync row so the caller can retry.
    const mainMapping = mappings.find(
      (m: any) => m.role === TableSyncMappingRole.Main,
    );
    // nothing to protect when the sync has no live main mirror left
    let mainMirrorDeleted = !mainMapping?.dest_table_id;
    const roleOrder: Record<string, number> = {
      [TableSyncMappingRole.Junction]: 0,
      [TableSyncMappingRole.LinkedShadow]: 1,
      [TableSyncMappingRole.Main]: 2,
    };
    for (const m of [...mappings]
      .sort((a: any, b: any) => (roleOrder[a.role] ?? 3) - (roleOrder[b.role] ?? 3)) as any[]) {
      if (!m.dest_table_id) continue;
      try {
        await this.tablesService.tableDelete(context, {
          tableId: m.dest_table_id,
          forceDeleteSyncs: true,
          req,
        });
        if (m.role === TableSyncMappingRole.Main) {
          mainMirrorDeleted = true;
        }
      } catch (e) {
        if (m.role !== TableSyncMappingRole.Main) {
          /* best effort — keep tearing the sync down */
          continue;
        }
        // table already gone (out-of-band hard delete / trash)? then there is
        // no zombie to protect — keep deleting the sync
        const stillThere = await Model.get(context, m.dest_table_id);
        if (!stillThere || stillThere.deleted) {
          mainMirrorDeleted = true;
          continue;
        }
        throw e;
      }
    }
    if (!mainMirrorDeleted) {
      // defensive: unreachable when mainMapping was deleted above, kept as a
      // guard against future role-order changes silently skipping main
      NcError.badRequest(
        'The mirror table could not be deleted — the sync is kept so it can be retried or detached',
      );
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

    // [CE-EE] F09 P3-R4(lane3): the queued Bull job embeds the caller's req
    // (rawHeaders incl. xc-auth JWT) — never echo it over HTTP
    const job = await this.enqueueSyncJob(context, sync, 'full-resync', req);
    return { id: job?.id, name: job?.name, status: TableSyncStatus.Syncing };
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
    // [CE-EE] F09 P3-R1(lane4): events that landed while paused were marked
    // skipped — resume re-enqueues one catch-up run so a paused window never
    // loses changes
    await enqueueCatchUpIfNeeded(tableSyncId);
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

    // [CE-EE] F09 P4: detach EVERY table the sync created (EE semantics:
    // "All tables created by the sync are kept as regular, editable tables
    // and stop syncing") — main mirror, shadows and junctions all flip to
    // regular; the mirror link columns keep working against the (now
    // regular) shadow/junction tables.
    for (const m of mappings as any[]) {
      if (!m.dest_table_id) continue;
      await Model.updateSynced(context, m.dest_table_id, false);

      // lift the readonly flag on every column of the table (direct meta —
      // same pattern as the P1 system:true patch; Column.update's whitelist
      // drops the flag silently)
      const tableColumnRows = (await Noco.ncMeta.metaList2(
        context.workspace_id,
        context.base_id,
        MetaTable.COLUMNS,
        { condition: { fk_model_id: m.dest_table_id } },
      )) as any[];
      for (const colRow of tableColumnRows) {
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
        `${CacheScope.COLUMN}:${m.dest_table_id}:list`,
        CacheDelDirection.PARENT_TO_CHILD,
      );
    }

    // remove the sync + its mappings; the tables survive as regular
    await TableSync.deleteColumnMappings(context, baseId, tableSyncId);
    await TableSync.delete(context, baseId, tableSyncId);

    return { ok: true, tableId: destTableId };
  }
}
