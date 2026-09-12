import {
  Body,
  Controller,
  Delete,
  Get,
  HttpCode,
  Param,
  Post,
  Req,
  UseGuards,
} from '@nestjs/common';
import type { NcContext, NcRequest } from '~/interface/config';
import { GlobalGuard } from '~/guards/global/global.guard';
import { MetaApiLimiterGuard } from '~/guards/meta-api-limiter.guard';
import { Acl } from '~/middlewares/extract-ids/extract-ids.middleware';
import { TenantContext } from '~/decorators/tenant-context.decorator';
import { BaseSnapshotsService } from '~/services/base-snapshots.service';

// [CE-EE] F07: base snapshots meta API (create/list/get/restore/delete).
// Permissions follow the standard role ACL (creator+ only).

@UseGuards(MetaApiLimiterGuard, GlobalGuard)
@Controller()
export class BaseSnapshotsController {
  constructor(private readonly baseSnapshotsService: BaseSnapshotsService) {}

  @Post(['/api/v1/db/meta/bases/:baseId/snapshots', '/api/v2/meta/bases/:baseId/snapshots'])
  @HttpCode(200)
  @Acl('baseSnapshotCreate')
  async createSnapshot(
    @TenantContext() context: NcContext,
    @Param('baseId') baseId: string,
    @Body() body: { title?: string },
    @Req() req: NcRequest,
  ) {
    return this.baseSnapshotsService.createSnapshot(context, baseId, req, body);
  }

  @Get(['/api/v1/db/meta/bases/:baseId/snapshots', '/api/v2/meta/bases/:baseId/snapshots'])
  @HttpCode(200)
  @Acl('baseSnapshotList')
  async listSnapshots(
    @TenantContext() context: NcContext,
    @Param('baseId') baseId: string,
  ) {
    return this.baseSnapshotsService.listSnapshots(context, baseId);
  }

  @Get([
    '/api/v1/db/meta/bases/:baseId/snapshots/:snapshotId',
    '/api/v2/meta/bases/:baseId/snapshots/:snapshotId',
  ])
  @HttpCode(200)
  @Acl('baseSnapshotList')
  async getSnapshot(
    @TenantContext() context: NcContext,
    @Param('baseId') baseId: string,
    @Param('snapshotId') snapshotId: string,
  ) {
    return this.baseSnapshotsService.getSnapshot(context, baseId, snapshotId);
  }

  @Post([
    '/api/v1/db/meta/bases/:baseId/snapshots/:snapshotId/restore',
    '/api/v2/meta/bases/:baseId/snapshots/:snapshotId/restore',
  ])
  @HttpCode(200)
  @Acl('baseSnapshotRestore')
  async restoreSnapshot(
    @TenantContext() context: NcContext,
    @Param('baseId') baseId: string,
    @Param('snapshotId') snapshotId: string,
    @Req() req: NcRequest,
  ) {
    return this.baseSnapshotsService.restoreSnapshot(
      context,
      baseId,
      snapshotId,
      req,
    );
  }

  @Delete([
    '/api/v1/db/meta/bases/:baseId/snapshots/:snapshotId',
    '/api/v2/meta/bases/:baseId/snapshots/:snapshotId',
  ])
  @Acl('baseSnapshotDelete')
  async deleteSnapshot(
    @TenantContext() context: NcContext,
    @Param('baseId') baseId: string,
    @Param('snapshotId') snapshotId: string,
  ) {
    return this.baseSnapshotsService.deleteSnapshot(
      context,
      baseId,
      snapshotId,
    );
  }
}
