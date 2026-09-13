import type { NcContext } from '~/interface/config';
import Noco from '~/Noco';
import { extractProps } from '~/helpers/extractProps';
import { NcError } from '~/helpers/catchError';
import {
  CacheDelDirection,
  CacheGetType,
  CacheScope,
  MetaTable,
} from '~/utils/globals';
import NocoCache from '~/cache/NocoCache';

// [CE-EE] F10: real CRUD over the pre-existing nc_dashboards_v2 table
// (replaces the CE stub). Widget rendering is out of scope for now.

export default class Dashboard {
  id?: string;
  title?: string;
  description?: string;
  base_id?: string;
  fk_workspace_id?: string;
  meta?: any;
  order?: number;
  created_by?: string;
  owned_by?: string;
  /** [CE-EE] F10: transient — populated by getWidgets for export/import */
  widgets?: any[];

  constructor(data: Partial<Dashboard>) {
    Object.assign(this, data);
  }

  public static async get(context: NcContext, dashboardId: string) {
    let data = await NocoCache.get(
      context,
      `${CacheScope.DASHBOARD}:${dashboardId}`,
      CacheGetType.TYPE_OBJECT,
    );

    if (!data) {
      data = await Noco.ncMeta.metaGet2(
        context.workspace_id,
        context.base_id,
        MetaTable.DASHBOARDS,
        dashboardId,
      );

      if (data) {
        await NocoCache.set(
          context,
          `${CacheScope.DASHBOARD}:${dashboardId}`,
          data,
        );
      }
    }

    return data && new Dashboard(data);
  }

  public static async list(context: NcContext, baseId: string) {
    const cachedList = await NocoCache.getList(
      context,
      CacheScope.DASHBOARD,
      [baseId],
    );
    let { list } = cachedList;
    const { isNoneList } = cachedList;

    if (!isNoneList && !list.length) {
      list = await Noco.ncMeta.metaList2(
        context.workspace_id,
        context.base_id,
        MetaTable.DASHBOARDS,
        { condition: { base_id: baseId }, orderBy: { order: 'asc' } },
      );

      if (list) {
        await NocoCache.setList(context, CacheScope.DASHBOARD, [baseId], list);
      }
    }

    return (list || [])
      .sort((a, b) => (a?.order ?? Infinity) - (b?.order ?? Infinity))
      .map((d) => new Dashboard({ ...d }));
  }

  public static async insert(context: NcContext, data: Partial<Dashboard>) {
    const insertObj = extractProps(data, [
      'title',
      'description',
      'meta',
      'order',
      'created_by',
      'owned_by',
    ]);

    if (!insertObj.title || typeof insertObj.title !== 'string') {
      NcError.badRequest('Dashboard title is required');
    }

    if (
      insertObj.order === null ||
      insertObj.order === undefined
    ) {
      insertObj.order = await Noco.ncMeta.metaGetNextOrder(
        MetaTable.DASHBOARDS,
        { base_id: data.base_id },
      );
    }

    const { id } = await Noco.ncMeta.metaInsert2(
      context.workspace_id,
      context.base_id,
      MetaTable.DASHBOARDS,
      insertObj,
    );

    // [CE-EE] F10 R1: materialize the cached object first, then append its
    // key to the scope list (appending first leaves an empty cached value
    // that silently invalidates the whole list — same fix as BaseSnapshot)
    const res = await this.get(context, id);

    await NocoCache.appendToList(
      context,
      CacheScope.DASHBOARD,
      [data.base_id],
      `${CacheScope.DASHBOARD}:${id}`,
    );

    return res;
  }

  public static async update(
    context: NcContext,
    dashboardId: string,
    data: Partial<Dashboard>,
  ) {
    const updateObj = extractProps(data, [
      'title',
      'description',
      'meta',
      'order',
    ]);

    await Noco.ncMeta.metaUpdate(
      context.workspace_id,
      context.base_id,
      MetaTable.DASHBOARDS,
      updateObj,
      dashboardId,
    );

    await NocoCache.update(
      context,
      `${CacheScope.DASHBOARD}:${dashboardId}`,
      updateObj,
    );

    return this.get(context, dashboardId);
  }

  static async softDelete(context: NcContext, dashboardId: string) {
    await Noco.ncMeta.metaDelete(
      context.workspace_id,
      context.base_id,
      MetaTable.DASHBOARDS,
      dashboardId,
    );

    await NocoCache.deepDel(
      context,
      `${CacheScope.DASHBOARD}:${dashboardId}`,
      CacheDelDirection.CHILD_TO_PARENT,
    );
  }

  static async delete(context: NcContext, dashboardId: string) {
    await Noco.ncMeta.metaDelete(
      context.workspace_id,
      context.base_id,
      MetaTable.DASHBOARDS,
      dashboardId,
    );

    await NocoCache.deepDel(
      context,
      `${CacheScope.DASHBOARD}:${dashboardId}`,
      CacheDelDirection.CHILD_TO_PARENT,
    );
  }

  async getWidgets(..._args) {
    // [CE-EE] F10: widget system deferred — dashboards render as titled
    // containers until the widget layer lands
    this.widgets = [];
    return this.widgets;
  }

  static async deleteByBaseId(
    context: NcContext,
    baseId: string,
    ncMeta = Noco.ncMeta,
  ) {
    await ncMeta.metaDelete(
      context.workspace_id,
      context.base_id,
      MetaTable.DASHBOARDS,
      { base_id: baseId },
    );

    await NocoCache.deepDel(
      context,
      `${CacheScope.DASHBOARD}:${baseId}:list`,
      CacheDelDirection.PARENT_TO_CHILD,
    );
  }
}
