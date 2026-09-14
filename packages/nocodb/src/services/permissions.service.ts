import {
  Injectable,
} from '@nestjs/common';
import {
  PermissionEntity,
  PermissionGrantedType,
  PermissionKey,
} from 'nocodb-sdk';
import type { NcContext } from '~/interface/config';
import { NcError } from '~/helpers/ncError';
import { Permission } from '~/models';
import { Column } from '~/models';
import { Model } from '~/models';

// [CE-EE] F02: field edit permission CRUD. permissionList is readable by
// editors+; create/update/delete are enforced creator+ through the standard
// role ACL. F03 (table permissions) reuses the same endpoints with
// entity=table — the API is generic by design.

@Injectable()
export class PermissionsService {
  async list(context: NcContext, baseId: string) {
    return Permission.list(context, baseId);
  }

  async create(
    context: NcContext,
    baseId: string,
    body: Partial<Permission> & {
      subjects?: { type: 'user' | 'team'; id: string }[];
    },
  ) {
    // validatePayload against a swagger schema would need a new component;
    // light validation here keeps the surface small (F05 pattern for forks)
    if (
      !body.entity ||
      !Object.values(PermissionEntity).includes(body.entity)
    ) {
      NcError.badRequest(`Invalid entity ${body.entity}`);
    }

    if (body.entity === PermissionEntity.FIELD) {
      // entity_id must reference an existing column in this base
      const column = await Column.get(context, { colId: body.entity_id });
      if (!column) {
        NcError.badRequest(`Column ${body.entity_id} not found`);
      }
      const table = await Model.get(context, column.fk_model_id);
      if (table && table.synced) {
        NcError.badRequest(
          'Field permissions are not available for synced columns',
        );
      }
    }

    if (
      !body.permission ||
      !Object.values(PermissionKey).includes(body.permission)
    ) {
      NcError.badRequest(`Invalid permission ${body.permission}`);
    }

    // F02 scope: RECORD_FIELD_EDIT on fields. F03: TABLE_RECORD_ADD /
    // TABLE_RECORD_DELETE / TABLE_VISIBILITY on tables.
    if (
      body.entity === PermissionEntity.FIELD &&
      body.permission !== PermissionKey.RECORD_FIELD_EDIT
    ) {
      NcError.badRequest(
        `Permission ${body.permission} is not supported for fields`,
      );
    }
    if (
      body.entity !== PermissionEntity.TABLE &&
      body.entity !== PermissionEntity.FIELD
    ) {
      NcError.badRequest(`Entity ${body.entity} is not supported`);
    }
    if (body.entity === PermissionEntity.TABLE) {
      const tableKeys = [
        PermissionKey.TABLE_RECORD_ADD,
        PermissionKey.TABLE_RECORD_DELETE,
        PermissionKey.TABLE_VISIBILITY,
      ];
      if (!tableKeys.includes(body.permission)) {
        NcError.badRequest(
          `Permission ${body.permission} is not supported for tables`,
        );
      }
      const table = await Model.get(context, body.entity_id);
      if (!table) {
        NcError.badRequest(`Table ${body.entity_id} not found`);
      }
      if (table.base_id !== baseId) {
        NcError.badRequest('Table does not belong to this base');
      }
      if (table.synced) {
        NcError.badRequest(
          'Table permissions are not available for synced tables',
        );
      }
    }

    // R1: one grant per (entity, entity_id, permission) — duplicates make
    // evaluation order-dependent
    const allPerms = await Permission.list(context, baseId);
    const duplicates = allPerms.filter(
      (p) =>
        p.entity === body.entity &&
        p.entity_id === body.entity_id &&
        p.permission === body.permission,
    );
    if (duplicates.length) {
      NcError.badRequest(
        'A permission grant already exists for this entity and permission',
      );
    }

    if (
      body.granted_type === PermissionGrantedType.USER &&
      body.subjects?.some((s) => s.type === 'team')
    ) {
      NcError.badRequest('Team subjects are not supported yet');
    }

    return Permission.insert(context, {
      ...body,
      base_id: baseId,
      created_by: context.user?.id,
    });
  }

  async update(
    context: NcContext,
    baseId: string,
    permissionId: string,
    body: Partial<Permission> & {
      subjects?: { type: 'user' | 'team'; id: string }[];
    },
  ) {
    const existing = await Permission.get(context, permissionId);

    if (existing.base_id !== baseId) {
      NcError.badRequest('Permission does not belong to this base');
    }

    // R4: resolved target type decides — a user grant PATCHed with team
    // subjects (without re-sending granted_type) must be rejected the same
    // way as on create
    const targetType =
      body.granted_type ?? (existing as Permission).granted_type;
    if (
      targetType === PermissionGrantedType.USER &&
      body.subjects?.some((s) => s.type === 'team')
    ) {
      NcError.badRequest('Team subjects are not supported yet');
    }

    return Permission.update(context, permissionId, body);
  }

  async delete(context: NcContext, baseId: string, permissionId: string) {
    const existing = await Permission.get(context, permissionId);

    if (existing.base_id !== baseId) {
      NcError.badRequest('Permission does not belong to this base');
    }

    return Permission.delete(context, permissionId);
  }
}
