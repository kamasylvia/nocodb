import {
  Body,
  Controller,
  Delete,
  Get,
  HttpCode,
  Param,
  Patch,
  Post,
  UseGuards,
} from '@nestjs/common';
import type { NcContext } from '~/interface/config';
import { GlobalGuard } from '~/guards/global/global.guard';
import { MetaApiLimiterGuard } from '~/guards/meta-api-limiter.guard';
import { Acl } from '~/middlewares/extract-ids/extract-ids.middleware';
import { TenantContext } from '~/decorators/tenant-context.decorator';
import { PermissionsService } from '~/services/permissions.service';

// [CE-EE] F02: meta API surface for field edit permissions (CRUD). The
// permission names are enforced through the standard role ACL (creator+ only).
// F03 (table record add/delete/visibility) reuses these endpoints with
// entity=table — the surface is intentionally generic.

@UseGuards(MetaApiLimiterGuard, GlobalGuard)
@Controller()
export class PermissionsController {
  constructor(private readonly permissionsService: PermissionsService) {}

  @Get([
    '/api/v1/db/meta/bases/:baseId/permissions',
    '/api/v2/meta/bases/:baseId/permissions',
  ])
  @HttpCode(200)
  @Acl('permissionList')
  async list(
    @TenantContext() context: NcContext,
    @Param('baseId') baseId: string,
  ) {
    return this.permissionsService.list(context, baseId);
  }

  @Post([
    '/api/v1/db/meta/bases/:baseId/permissions',
    '/api/v2/meta/bases/:baseId/permissions',
  ])
  @HttpCode(200)
  @Acl('permissionCreate')
  async create(
    @TenantContext() context: NcContext,
    @Param('baseId') baseId: string,
    @Body() body: any,
  ) {
    return this.permissionsService.create(context, baseId, body);
  }

  @Patch([
    '/api/v1/db/meta/bases/:baseId/permissions/:permissionId',
    '/api/v2/meta/bases/:baseId/permissions/:permissionId',
  ])
  @Acl('permissionUpdate')
  async update(
    @TenantContext() context: NcContext,
    @Param('baseId') baseId: string,
    @Param('permissionId') permissionId: string,
    @Body() body: any,
  ) {
    return this.permissionsService.update(
      context,
      baseId,
      permissionId,
      body,
    );
  }

  @Delete([
    '/api/v1/db/meta/bases/:baseId/permissions/:permissionId',
    '/api/v2/meta/bases/:baseId/permissions/:permissionId',
  ])
  @Acl('permissionDelete')
  async delete(
    @TenantContext() context: NcContext,
    @Param('baseId') baseId: string,
    @Param('permissionId') permissionId: string,
  ) {
    return this.permissionsService.delete(context, baseId, permissionId);
  }
}
