import type { SnapshotType } from 'nocodb-sdk';
import type { NcContext } from '~/interface/config';
import Noco from '~/Noco';
import { extractProps } from '~/helpers/extractProps';
import {
  CacheDelDirection,
  CacheGetType,
  CacheScope,
  MetaTable,
} from '~/utils/globals';
import NocoCache from '~/cache/NocoCache';

// [CE-EE] F07: base snapshots — a snapshot is a full async copy of a base
// (reusing the DuplicateBase job) recorded in nc_snapshots. Restoring
// duplicates the snapshot base back into the workspace as a new base.

export default class BaseSnapshot implements SnapshotType {
  id?: string;
  title?: string;
  base_id?: string;
  snapshot_base_id?: string;
  fk_workspace_id?: string;
  created_by?: string;
  status?: string;
  is_auto?: boolean;
  created_at?: string;

  constructor(data: Partial<BaseSnapshot>) {
    Object.assign(this, data);
  }

  public static async get(context: NcContext, snapshotId: string) {
    let data = await NocoCache.get(
      context,
      `${CacheScope.SNAPSHOT}:${snapshotId}`,
      CacheGetType.TYPE_OBJECT,
    );

    if (!data) {
      data = await Noco.ncMeta.metaGet2(
        context.workspace_id,
        context.base_id,
        MetaTable.SNAPSHOT,
        snapshotId,
      );

      if (data) {
        await NocoCache.set(
          context,
          `${CacheScope.SNAPSHOT}:${snapshotId}`,
          data,
        );
      }
    }

    return data && new BaseSnapshot(data);
  }

  public static async list(context: NcContext, baseId: string) {
    const cachedList = await NocoCache.getList(
      context,
      CacheScope.SNAPSHOT,
      [baseId],
    );
    let { list } = cachedList;
    const { isNoneList } = cachedList;

    if (!isNoneList && !list.length) {
      list = await Noco.ncMeta.metaList2(
        context.workspace_id,
        context.base_id,
        MetaTable.SNAPSHOT,
        { condition: { base_id: baseId }, orderBy: { created_at: 'desc' } },
      );

      if (list) {
        await NocoCache.setList(context, CacheScope.SNAPSHOT, [baseId], list);
      }
    }

    return (list || []).map((s) => new BaseSnapshot(s));
  }

  public static async insert(
    context: NcContext,
    data: Partial<BaseSnapshot>,
  ) {
    const insertObj = extractProps(data, [
      'title',
      'base_id',
      'snapshot_base_id',
      'created_by',
      'status',
      'is_auto',
    ]);

    const { id } = await Noco.ncMeta.metaInsert2(
      context.workspace_id,
      context.base_id,
      MetaTable.SNAPSHOT,
      insertObj,
    );

    // [CE-EE] F07 R1: materialize the cached object first, then append its
    // key to the scope list (appending before the object exists made every
    // create throw CacheMgr errors and invalidate the list fallback)
    const res = await this.get(context, id);

    await NocoCache.appendToList(
      context,
      CacheScope.SNAPSHOT,
      [data.base_id],
      `${CacheScope.SNAPSHOT}:${id}`,
    );

    return res;
  }

  public static async update(
    context: NcContext,
    snapshotId: string,
    data: Partial<BaseSnapshot>,
  ) {
    const updateObj = extractProps(data, ['title', 'status']);

    await Noco.ncMeta.metaUpdate(
      context.workspace_id,
      context.base_id,
      MetaTable.SNAPSHOT,
      updateObj,
      snapshotId,
    );

    await NocoCache.update(
      context,
      `${CacheScope.SNAPSHOT}:${snapshotId}`,
      updateObj,
    );

    return this.get(context, snapshotId);
  }

  public static async delete(context: NcContext, snapshotId: string) {
    await Noco.ncMeta.metaDelete(
      context.workspace_id,
      context.base_id,
      MetaTable.SNAPSHOT,
      snapshotId,
    );

    await NocoCache.deepDel(
      context,
      `${CacheScope.SNAPSHOT}:${snapshotId}`,
      CacheDelDirection.CHILD_TO_PARENT,
    );
  }

  public static async deleteByBaseId(
    context: NcContext,
    baseId: string,
    ncMeta = Noco.ncMeta,
  ) {
    await ncMeta.metaDelete(
      context.workspace_id,
      context.base_id,
      MetaTable.SNAPSHOT,
      { base_id: baseId },
    );

    await NocoCache.deepDel(
      context,
      `${CacheScope.SNAPSHOT}:${baseId}:list`,
      CacheDelDirection.PARENT_TO_CHILD,
    );
  }

  /**
   * [CE-EE] F07 R3: called when a work base is deleted — soft-delete every
   * snapshot copy base (they are real bases that would otherwise linger as
   * unmanaged orphans in the workspace), then drop the registry rows.
   */
  public static async cleanupByBaseIdWithCopies(
    context: NcContext,
    baseId: string,
    ncMeta = Noco.ncMeta,
  ) {
    // dynamic import: Base.ts imports this module, avoid a static cycle
    const { default: Base } = await import('~/models/Base');

    const rows = await this.list(context, baseId);
    for (const row of rows) {
      if (!row.snapshot_base_id) continue;
      try {
        await Base.softDelete(
          {
            workspace_id: row.fk_workspace_id ?? context.workspace_id,
            base_id: row.snapshot_base_id,
          } as NcContext,
          row.snapshot_base_id,
          ncMeta,
        );
      } catch {
        // copy base may already be gone — the row cleanup below still runs
      }
    }

    await this.deleteByBaseId(context, baseId, ncMeta);
  }
}
