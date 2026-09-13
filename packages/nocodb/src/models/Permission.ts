import {
  evaluatePermission,
  PermissionEntity,
  PermissionGrantedType,
  PermissionKey,
  PermissionRole,
  PermissionRoleMap,
  PermissionRolePower,
  SubjectType,
} from 'nocodb-sdk';
import type {
  EvaluablePermission,
  ProjectRoles,
  WorkspaceUserRoles,
} from 'nocodb-sdk';
import type { NcContext } from '~/interface/config';
import Noco from '~/Noco';
import { extractProps } from '~/helpers/extractProps';
import { NcError } from '~/helpers/ncError';
import {
  CacheGetType,
  CacheScope,
  MetaTable,
} from '~/utils/globals';
import NocoCache from '~/cache/NocoCache';

// [CE-EE] F02: real permission store over nc_permissions / nc_permission_subjects.
// Semantics (upstream contract, see mcp.controller loadPermissions):
//   - no grant row for (entity, entityId, permission) => allowed (fail-open)
//   - grant present => SDK evaluatePermission decides (role power compare or
//     subject id match); NOBODY denies everyone but base owners, who always
//     pass (mirrors hasTableVisibilityAccess owner shortcut).

export default class Permission {
  id: string;
  fk_workspace_id: string;
  base_id: string;
  entity: PermissionEntity;
  entity_id: string;
  permission: PermissionKey;
  created_by: string;
  enforce_for_form: boolean;
  enforce_for_automation: boolean;
  granted_type: PermissionGrantedType;
  granted_role: PermissionRole;

  subjects?: {
    type: 'user' | 'team';
    id: string;
  }[];

  constructor(permission: Permission) {
    Object.assign(this, permission);
  }

  protected static castType(permission: any): Permission {
    return permission && new Permission(permission);
  }

  private static baseListCacheKey(baseId: string) {
    return `${CacheScope.PERMISSION}:base:${baseId}`;
  }

  private static async evictBaseCache(context: NcContext, baseId: string) {
    await NocoCache.del(context, Permission.baseListCacheKey(baseId));
  }

  private static async evictPermissionCache(
    context: NcContext,
    baseId: string,
    permissionId: string,
  ) {
    await NocoCache.del(context, `${CacheScope.PERMISSION}:${permissionId}`);
    await Permission.evictBaseCache(context, baseId);
  }

  private static async insertSubjects(
    context: NcContext,
    permissionId: string,
    subjects: { type: 'user' | 'team'; id: string }[],
    ncMeta = Noco.ncMeta,
  ) {
    for (const s of subjects) {
      await ncMeta.metaInsert2(
        context.workspace_id,
        context.base_id,
        MetaTable.PERMISSION_SUBJECTS,
        {
          fk_permission_id: permissionId,
          subject_type: s.type,
          subject_id: s.id,
          fk_workspace_id: context.workspace_id,
          base_id: context.base_id,
        },
        true,
      );
    }
  }

  public static async list(
    context: NcContext,
    baseId: string,
    ncMeta = Noco.ncMeta,
  ): Promise<Permission[]> {
    // per-request cache. extract-ids pre-seeds context.permissions = [] for
    // every request, so an empty array is NOT a valid "already loaded" signal
    // on its own — pair it with a load marker.
    const ctxAny = context as any;
    if (ctxAny.permissions?.length || ctxAny.__permissionsLoaded) {
      return ctxAny.permissions ?? [];
    }

    // cache convention (mirrors appendToList users): the list key holds the
    // permission ids (strings), each row lives under its own key. Caching
    // object arrays directly is broken — CacheMgr routes arrays to sadd.
    const listKey = Permission.baseListCacheKey(baseId);

    const cachedIds: string[] = await NocoCache.get(
      context,
      listKey,
      CacheGetType.TYPE_ARRAY,
    );

    let permissions: Permission[] = [];

    if (cachedIds?.length) {
      if (cachedIds[0] === 'NONE') {
        // valid cached empty set
        ctxAny.permissions = permissions;
        ctxAny.__permissionsLoaded = true;
        return permissions;
      }
      for (const id of cachedIds) {
        const row = await NocoCache.get(
          context,
          `${CacheScope.PERMISSION}:${id}`,
          CacheGetType.TYPE_OBJECT,
        );
        if (row) {
          permissions.push(Permission.castType(row));
        }
      }
    }

    if (!permissions.length) {
      const rows = await ncMeta.metaList2(
        context.workspace_id,
        baseId,
        MetaTable.PERMISSIONS,
        { condition: { base_id: baseId } },
      );

      for (const row of rows) {
        const subjectRows = await ncMeta.metaList2(
          context.workspace_id,
          baseId,
          MetaTable.PERMISSION_SUBJECTS,
          { condition: { fk_permission_id: row.id } },
        );
        permissions.push(
          Permission.castType({
            ...row,
            subjects: subjectRows.map((s) => ({
              type: s.subject_type,
              id: s.subject_id,
            })),
          }),
        );
      }

      await NocoCache.del(context, listKey);

      if (permissions.length) {
        for (const p of permissions) {
          await NocoCache.set(
            context,
            `${CacheScope.PERMISSION}:${p.id}`,
            { ...p },
          );
        }
        await NocoCache.set(
          context,
          listKey,
          permissions.map((p) => p.id),
        );
      } else {
        await NocoCache.set(context, listKey, ['NONE']);
      }
    }

    ctxAny.permissions = permissions;
    ctxAny.__permissionsLoaded = true;
    return permissions;
  }

  public static async get(
    context: NcContext,
    permissionId: string,
    ncMeta = Noco.ncMeta,
  ): Promise<Permission> {
    let permission = (
      await Permission.list(context, context.base_id, ncMeta)
    ).find((p) => p.id === permissionId);

    if (!permission) {
      const row = await ncMeta.metaGet2(
        context.workspace_id,
        context.base_id,
        MetaTable.PERMISSIONS,
        permissionId,
      );
      if (!row) {
        NcError.get(context).recordNotFound(permissionId);
      }
      const subjectRows = await ncMeta.metaList2(
        context.workspace_id,
        context.base_id,
        MetaTable.PERMISSION_SUBJECTS,
        { condition: { fk_permission_id: permissionId } },
      );
      permission = Permission.castType({
        ...row,
        subjects: subjectRows.map((s) => ({
          type: s.subject_type,
          id: s.subject_id,
        })),
      });
    }

    return permission;
  }

  public static async insert(
    context: NcContext,
    data: Partial<Permission> & {
      subjects?: { type: 'user' | 'team'; id: string }[];
    },
    ncMeta = Noco.ncMeta,
  ): Promise<Permission> {
    const insertObj = extractProps(data, [
      'fk_workspace_id',
      'base_id',
      'entity',
      'entity_id',
      'permission',
      'created_by',
      'enforce_for_form',
      'enforce_for_automation',
      'granted_type',
      'granted_role',
    ]);

    insertObj.id = await ncMeta.genNanoid(MetaTable.PERMISSIONS);
    insertObj.fk_workspace_id = context.workspace_id;
    insertObj.base_id = context.base_id;

    if (!Object.values(PermissionEntity).includes(insertObj.entity)) {
      NcError.get(context).badRequest(`Invalid entity ${insertObj.entity}`);
    }
    if (!insertObj.entity_id) {
      NcError.get(context).badRequest('entity_id is required');
    }
    if (!insertObj.permission) {
      NcError.get(context).badRequest('permission is required');
    }
    if (
      ![
        PermissionGrantedType.ROLE,
        PermissionGrantedType.USER,
        PermissionGrantedType.NOBODY,
      ].includes(insertObj.granted_type)
    ) {
      NcError.get(context).badRequest(
        `Invalid granted_type ${insertObj.granted_type}`,
      );
    }
    if (
      insertObj.granted_type === PermissionGrantedType.ROLE &&
      !insertObj.granted_role
    ) {
      NcError.get(context).badRequest(
        'granted_role is required for role grants',
      );
    }
    if (
      insertObj.granted_type === PermissionGrantedType.USER &&
      !data.subjects?.length
    ) {
      NcError.get(context).badRequest(
        'subjects are required for user grants',
      );
    }

    await ncMeta.metaInsert2(
      context.workspace_id,
      context.base_id,
      MetaTable.PERMISSIONS,
      insertObj,
      true,
    );

    if (data.subjects?.length) {
      await Permission.insertSubjects(
        context,
        insertObj.id,
        data.subjects.filter((s) => s.type === 'user' || s.type === 'team'),
        ncMeta,
      );
    }

    await Permission.evictBaseCache(context, context.base_id);

    return Permission.get(context, insertObj.id, ncMeta);
  }

  public static async update(
    context: NcContext,
    permissionId: string,
    data: Partial<Permission> & {
      subjects?: { type: 'user' | 'team'; id: string }[];
    },
    ncMeta = Noco.ncMeta,
  ): Promise<Permission> {
    const existing = await Permission.get(context, permissionId, ncMeta);

    const updateObj = extractProps(data, [
      'granted_type',
      'granted_role',
      'enforce_for_form',
      'enforce_for_automation',
    ]);

    if (
      updateObj.granted_type &&
      ![
        PermissionGrantedType.ROLE,
        PermissionGrantedType.USER,
        PermissionGrantedType.NOBODY,
      ].includes(updateObj.granted_type)
    ) {
      NcError.get(context).badRequest(
        `Invalid granted_type ${updateObj.granted_type}`,
      );
    }

    if (Object.keys(updateObj).length) {
      await ncMeta.metaUpdate(
        context.workspace_id,
        context.base_id,
        MetaTable.PERMISSIONS,
        updateObj,
        permissionId,
      );
    }

    if (data.subjects) {
      await ncMeta.metaDelete(
        context.workspace_id,
        context.base_id,
        MetaTable.PERMISSION_SUBJECTS,
        { fk_permission_id: permissionId },
      );
      if (data.subjects.length) {
        await Permission.insertSubjects(
          context,
          permissionId,
          data.subjects.filter((s) => s.type === 'user' || s.type === 'team'),
          ncMeta,
        );
      }
    }

    await Permission.evictPermissionCache(context, context.base_id, permissionId);

    return Permission.get(context, permissionId, ncMeta);
  }

  public static async delete(
    context: NcContext,
    permissionId: string,
    ncMeta = Noco.ncMeta,
  ): Promise<boolean> {
    const existing = await Permission.get(context, permissionId, ncMeta);

    await ncMeta.metaDelete(
      context.workspace_id,
      context.base_id,
      MetaTable.PERMISSION_SUBJECTS,
      { fk_permission_id: permissionId },
    );

    await ncMeta.metaDelete(
      context.workspace_id,
      context.base_id,
      MetaTable.PERMISSIONS,
      permissionId,
    );

    await Permission.evictPermissionCache(context, context.base_id, permissionId);

    return !!existing;
  }

  public static async deleteByBaseId(
    context: NcContext,
    baseId: string,
    ncMeta = Noco.ncMeta,
  ) {
    await ncMeta.metaDelete(
      context.workspace_id,
      baseId,
      MetaTable.PERMISSION_SUBJECTS,
      { base_id: baseId },
    );

    await ncMeta.metaDelete(
      context.workspace_id,
      baseId,
      MetaTable.PERMISSIONS,
      { base_id: baseId },
    );

    await Permission.evictBaseCache(context, baseId);
  }

  // placeholder for actual permission check logic
  static async isAllowed(
    context: NcContext,
    permissionObj: Permission | EvaluablePermission,
    user: {
      id: string;
      role: ProjectRoles | WorkspaceUserRoles;
      is_agent?: boolean;
    },
  ): Promise<boolean> {
    if (!permissionObj) {
      return true;
    }

    const mappedRole = PermissionRoleMap[
      user?.role as keyof typeof PermissionRoleMap
    ] as PermissionRole | undefined;

    // base owners always pass (mirrors hasTableVisibilityAccess)
    if (mappedRole === PermissionRole.OWNER) {
      return true;
    }

    return evaluatePermission(
      permissionObj as EvaluablePermission,
      {
        userId: user?.id,
        subjectType: user?.is_agent ? SubjectType.AGENT : SubjectType.USER,
        permissionRole: mappedRole,
      },
    );
  }

  /**
   * [CE-EE] F02: fetch the applicable grant(s) for an entity/permission pair.
   * Returns undefined when no grant is configured (fail-open at the caller).
   */
  static findGrants(
    context: NcContext,
    params: {
      entity: PermissionEntity;
      entityId: string;
      permission: PermissionKey;
    },
  ): Permission[] {
    const permissions = context.permissions || [];
    return permissions.filter(
      (p) =>
        p.entity === params.entity &&
        p.entity_id === params.entityId &&
        p.permission === params.permission,
    );
  }

  static rolePowerOfRole(role: string): number | undefined {
    return PermissionRolePower[role as keyof typeof PermissionRolePower];
  }
}
