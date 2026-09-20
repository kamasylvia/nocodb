import type { NcContext } from '~/interface/config';
import Noco from '~/Noco';
import { extractProps } from '~/helpers/extractProps';
import { MetaTable } from '~/utils/globals';
import type { TableSyncType, TableSyncMappingType } from 'nocodb-sdk';

// [CE-EE] F09: Table Sync (base-to-base mirror). The sync row lives in the
// destination base (nc_table_syncs), the main mapping pins the source
// workspace/base/table/view and the destination mirror table
// (nc_table_sync_mappings), and per-column identity is kept in
// nc_table_sync_column_mappings. All three tables ship in CE migrations —
// this model is the first consumer.

export default class TableSync {
  id?: string;
  base_id?: string;
  fk_workspace_id?: string;
  title?: string;
  selected_fields?: string[] | null;
  on_delete_action?: string;
  sync_trigger?: string;
  status?: string;
  last_error?: string | null;
  last_synced_at?: string | null;
  sync_job_id?: string | null;
  source_input_mode?: string;
  created_by?: string | null;
  updated_by?: string | null;
  deleted?: boolean;

  constructor(sync: Partial<TableSync>) {
    Object.assign(this, sync);
  }

  public static async get(
    context: NcContext,
    tableSyncId: string,
    ncMeta = Noco.ncMeta,
  ): Promise<TableSync | null> {
    if (!tableSyncId) return null;

    const sync = await ncMeta.metaGet2(
      context.workspace_id,
      context.base_id,
      MetaTable.TABLE_SYNCS,
      tableSyncId,
    );
    if (!sync) return null;

    return new TableSync(parseSyncRow(sync));
  }

  /** Fetch a sync regardless of the caller's base context (engine jobs
   *  resolve the row first, then build contexts from the row itself). */
  public static async getAny(
    tableSyncId: string,
    ncMeta = Noco.ncMeta,
  ): Promise<TableSync | null> {
    if (!tableSyncId) return null;

    const sync = await ncMeta
      .knex(MetaTable.TABLE_SYNCS)
      .where({ id: tableSyncId })
      .first();
    if (!sync) return null;

    return new TableSync(parseSyncRow(sync));
  }

  public static async list(
    context: NcContext,
    baseId: string,
    ncMeta = Noco.ncMeta,
  ): Promise<TableSync[]> {
    const syncs = await ncMeta.metaList2(
      context.workspace_id,
      baseId,
      MetaTable.TABLE_SYNCS,
      {
        condition: { base_id: baseId },
        orderBy: { created_at: 'asc' },
      },
    );

    return syncs.map((s) => new TableSync(parseSyncRow(s)));
  }

  public static async insert(
    context: NcContext,
    sync: Partial<TableSync>,
    ncMeta = Noco.ncMeta,
  ) {
    const insertObj = extractProps(sync, [
      'title',
      'base_id',
      'fk_workspace_id',
      'selected_fields',
      'on_delete_action',
      'sync_trigger',
      'status',
      'source_input_mode',
      'created_by',
    ]);

    if (Array.isArray(insertObj.selected_fields)) {
      (insertObj as any).selected_fields = JSON.stringify(
        insertObj.selected_fields,
      );
    }

    const { id } = await ncMeta.metaInsert2(
      context.workspace_id,
      context.base_id,
      MetaTable.TABLE_SYNCS,
      insertObj,
    );

    return this.get(context, id, ncMeta);
  }

  public static async update(
    context: NcContext,
    baseId: string,
    tableSyncId: string,
    sync: Partial<TableSync>,
    ncMeta = Noco.ncMeta,
  ) {
    const updateObj = extractProps(sync, [
      'title',
      'selected_fields',
      'on_delete_action',
      'status',
      'last_error',
      'last_synced_at',
      'sync_job_id',
      'updated_by',
    ]);

    if (Array.isArray(updateObj.selected_fields)) {
      (updateObj as any).selected_fields = JSON.stringify(
        updateObj.selected_fields,
      );
    }

    await ncMeta.metaUpdate(
      context.workspace_id,
      baseId,
      MetaTable.TABLE_SYNCS,
      updateObj,
      tableSyncId,
    );

    return this.get(context, tableSyncId, ncMeta);
  }

  public static async delete(
    context: NcContext,
    baseId: string,
    tableSyncId: string,
    ncMeta = Noco.ncMeta,
  ) {
    // mappings + column mappings cascade first (caller wraps in txn where it
    // matters); the sync row goes last
    await ncMeta.knex(MetaTable.TABLE_SYNC_COLUMN_MAPPINGS)
      .where({ fk_table_sync_id: tableSyncId })
      .del();
    await ncMeta.knex(MetaTable.TABLE_SYNC_MAPPINGS)
      .where({ fk_table_sync_id: tableSyncId })
      .del();
    await ncMeta.metaDelete(
      context.workspace_id,
      baseId,
      MetaTable.TABLE_SYNCS,
      tableSyncId,
    );
  }

  public static async listMappings(
    context: NcContext,
    baseId: string,
    tableSyncId: string,
    ncMeta = Noco.ncMeta,
  ): Promise<TableSyncMappingType[]> {
    return (await ncMeta.metaList2(
      context.workspace_id,
      baseId,
      MetaTable.TABLE_SYNC_MAPPINGS,
      {
        condition: { fk_table_sync_id: tableSyncId },
        orderBy: { created_at: 'asc' },
      },
    )) as TableSyncMappingType[];
  }

  public static async getMainMapping(
    context: NcContext,
    baseId: string,
    tableSyncId: string,
    ncMeta = Noco.ncMeta,
  ): Promise<TableSyncMappingType | null> {
    const mapping = await ncMeta.metaGet2(
      context.workspace_id,
      baseId,
      MetaTable.TABLE_SYNC_MAPPINGS,
      { fk_table_sync_id: tableSyncId, role: 'main' },
    );
    return (mapping as TableSyncMappingType) || null;
  }

  /** source_column_id → dest_column_id identity of this sync's mirror.
   *  [CE-EE] F09 P4: also returns fk_table_sync_mapping_id + source_table_id
   *  so the engine can partition column mappings per table mapping (main vs
   *  linked_shadow) — the existing two-key shape is a subset, so previous
   *  callers are unaffected. */
  public static async listColumnMappings(
    context: NcContext,
    baseId: string,
    tableSyncId: string,
    ncMeta = Noco.ncMeta,
  ): Promise<
    {
      source_column_id: string;
      dest_column_id: string;
      fk_table_sync_mapping_id: string;
      source_table_id: string;
    }[]
  > {
    const rows = await ncMeta
      .knex(MetaTable.TABLE_SYNC_COLUMN_MAPPINGS)
      .where({ fk_table_sync_id: tableSyncId, base_id: baseId })
      .select(
        'source_column_id',
        'dest_column_id',
        'fk_table_sync_mapping_id',
        'source_table_id',
      );
    return rows;
  }

  public static async insertColumnMappings(
    context: NcContext,
    rows: Partial<{
      base_id: string;
      fk_workspace_id: string;
      fk_table_sync_id: string;
      fk_table_sync_mapping_id: string;
      source_workspace_id: string;
      source_base_id: string;
      source_table_id: string;
      source_column_id: string;
      dest_base_id: string;
      dest_table_id: string;
      dest_column_id: string;
    }>[],
    ncMeta = Noco.ncMeta,
  ) {
    if (!rows?.length) return;
    const insertRows = [];
    for (const r of rows) {
      insertRows.push({
        ...extractProps(r, [
          'base_id',
          'fk_workspace_id',
          'fk_table_sync_id',
          'fk_table_sync_mapping_id',
          'source_workspace_id',
          'source_base_id',
          'source_table_id',
          'source_column_id',
          'dest_base_id',
          'dest_table_id',
          'dest_column_id',
        ]),
        id: await ncMeta.genNanoid(MetaTable.TABLE_SYNC_COLUMN_MAPPINGS),
      });
    }
    await ncMeta.knex(MetaTable.TABLE_SYNC_COLUMN_MAPPINGS).insert(insertRows);
  }

  public static async deleteColumnMappings(
    context: NcContext,
    baseId: string,
    tableSyncId: string,
    ncMeta = Noco.ncMeta,
  ) {
    await ncMeta.knex(MetaTable.TABLE_SYNC_COLUMN_MAPPINGS)
      .where({ fk_table_sync_id: tableSyncId, base_id: baseId })
      .del();
  }

  /** API shape — mirrors TableSyncType from the SDK */
  public toType(): TableSyncType {
    return {
      id: this.id,
      base_id: this.base_id,
      fk_workspace_id: this.fk_workspace_id,
      title: this.title,
      selected_fields: this.selected_fields ?? null,
      on_delete_action: this.on_delete_action as TableSyncType['on_delete_action'],
      sync_trigger: this.sync_trigger as TableSyncType['sync_trigger'],
      source_input_mode: this.source_input_mode as TableSyncType['source_input_mode'],
      status: this.status as TableSyncType['status'],
      last_error: this.last_error ?? null,
      last_synced_at: this.last_synced_at ?? null,
      sync_job_id: this.sync_job_id ?? null,
      deleted: !!this.deleted,
      created_at: (this as any).created_at,
      updated_at: (this as any).updated_at,
      created_by: this.created_by ?? null,
      updated_by: this.updated_by ?? null,
    } as TableSyncType;
  }
}

function parseSyncRow(row: Record<string, any>) {
  if (row.selected_fields && typeof row.selected_fields === 'string') {
    try {
      row.selected_fields = JSON.parse(row.selected_fields);
    } catch {
      row.selected_fields = null;
    }
  }
  return row;
}
