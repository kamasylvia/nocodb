import {
  evaluatePermission,
  PermissionEntity,
  PermissionGrantedType,
  PermissionKey,
  PermissionMeta,
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
import { MetaTable } from '~/utils/globals';

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
    // R1: deliberately cache-free. Everything about the NocoCache key space
    // (pooled contexts collapsing cacheContext prefixes, CacheMgr routing
    // arrays to sadd, TTL vs eviction interplay) produced stale or
    // cross-base lists during review; the backing query is a tiny indexed
    // meta read, so correctness wins. The result is still exposed on
    // context.permissions for same-request reuse.
    const rows = await ncMeta.metaList2(
      context.workspace_id,
      baseId,
      MetaTable.PERMISSIONS,
      { condition: { base_id: baseId } },
    );

    const permissions: Permission[] = [];

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

    context.permissions = permissions;
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
    // R1: granted_role must be a real role and respect the permission's
    // minimumRole (e.g. RECORD_FIELD_EDIT cannot be granted to viewer/commenter)
    if (insertObj.granted_type === PermissionGrantedType.ROLE) {
      if (
        !Object.values(PermissionRole).includes(
          insertObj.granted_role as PermissionRole,
        )
      ) {
        NcError.get(context).badRequest(
          `Invalid granted_role ${insertObj.granted_role}`,
        );
      }
      const minimumRole =
        PermissionMeta[
          insertObj.permission as keyof typeof PermissionMeta
        ]?.minimumRole;
      if (
        minimumRole &&
        PermissionRolePower[insertObj.granted_role as PermissionRole] <
          PermissionRolePower[minimumRole]
      ) {
        NcError.get(context).badRequest(
          `granted_role ${insertObj.granted_role} is below the minimum role for ${insertObj.permission}`,
        );
      }
    }
    if (
      insertObj.granted_type === PermissionGrantedType.USER &&
      !data.subjects?.length
    ) {
      NcError.get(context).badRequest(
        'subjects are required for user grants',
      );
    }
    if (data.subjects) {
      for (const s of data.subjects) {
        if (!(s.type === 'user' || s.type === 'team') || !s.id) {
          NcError.get(context).badRequest(
            'each subject requires a valid type and id',
          );
        }
      }
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

    // R1: switching to a user grant without subjects would silently deny
    // everyone — reject instead
    const targetType =
      updateObj.granted_type ?? (existing as Permission).granted_type;
    if (targetType === PermissionGrantedType.USER) {
      const subjects = data.subjects ?? (existing as Permission).subjects;
      if (!subjects?.length) {
        NcError.get(context).badRequest(
          'subjects are required for user grants',
        );
      }
    }

    if (Object.keys(updateObj).length) {
      // switching to nobody makes granted_role stale — clear it
      if (updateObj.granted_type === PermissionGrantedType.NOBODY) {
        updateObj.granted_role = null as any;
      }
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
