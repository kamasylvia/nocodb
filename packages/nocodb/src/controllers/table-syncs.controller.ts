import {
  Body,
  Controller,
  Delete,
  Get,
  HttpCode,
  Param,
  Patch,
  Post,
  Req,
  UseGuards,
} from '@nestjs/common';
import type { NcContext, NcRequest } from '~/interface/config';
import { GlobalGuard } from '~/guards/global/global.guard';
import { MetaApiLimiterGuard } from '~/guards/meta-api-limiter.guard';
import { Acl } from '~/middlewares/extract-ids/extract-ids.middleware';
import { TenantContext } from '~/decorators/tenant-context.decorator';
import { TableSyncsService } from '~/services/table-syncs.service';

// [CE-EE] F09: Table Sync meta API. The permission names (tableSync*) are
// pre-registered in permissionScopes.base — with the creator/owner exclude
// model they resolve to creator+ automatically (same semantics as the
// legacy SyncSource surface); no explicit ACL registration needed. Routes
// carry :baseId so ExtractIdsMiddleware resolves ncBaseId directly — no
// extra :tableSyncId extraction required.

@UseGuards(MetaApiLimiterGuard, GlobalGuard)
@Controller()
export class TableSyncsController {
  constructor(private readonly tableSyncsService: TableSyncsService) {}

  @Get(['/api/v2/meta/bases/:baseId/table-syncs'])
  @HttpCode(200)
  @Acl('tableSyncList')
  async list(
    @TenantContext() context: NcContext,
    @Param('baseId') baseId: string,
  ) {
    return this.tableSyncsService.listSyncs(context, baseId);
  }

  @Get(['/api/v2/meta/bases/:baseId/table-syncs/:tableSyncId'])
  @HttpCode(200)
  @Acl('tableSyncGet')
  async get(
    @TenantContext() context: NcContext,
    @Param('baseId') baseId: string,
    @Param('tableSyncId') tableSyncId: string,
  ) {
    return this.tableSyncsService.getSync(context, baseId, tableSyncId);
  }

  @Post(['/api/v2/meta/bases/:baseId/table-syncs/source-schema'])
  @HttpCode(200)
  @Acl('tableSyncSourceSchema')
  async sourceSchema(
    @TenantContext() context: NcContext,
    @Param('baseId') baseId: string,
    @Body()
    body: {
      sourceBaseId?: string;
      sourceTableId?: string;
      sourceViewId?: string;
    },
    @Req() req: NcRequest,
  ) {
    return this.tableSyncsService.sourceSchema(context, baseId, body, req);
  }

  @Post(['/api/v2/meta/bases/:baseId/table-syncs'])
  @HttpCode(200)
  @Acl('tableSyncCreate')
  async create(
    @TenantContext() context: NcContext,
    @Param('baseId') baseId: string,
    @Body()
    body: {
      title?: string;
      sourceBaseId?: string;
      sourceTableId?: string;
      sourceViewId?: string;
      selectedFields?: string[] | null;
      onDeleteAction?: string;
      syncTrigger?: string;
    },
    @Req() req: NcRequest,
  ) {
    return this.tableSyncsService.createSync(context, baseId, body, req);
  }

  @Patch(['/api/v2/meta/bases/:baseId/table-syncs/:tableSyncId'])
  @Acl('tableSyncUpdate')
  async update(
    @TenantContext() context: NcContext,
    @Param('baseId') baseId: string,
    @Param('tableSyncId') tableSyncId: string,
    @Body()
    body: {
      title?: string;
      on_delete_action?: string;
      selected_fields?: string[];
    },
    @Req() req: NcRequest,
  ) {
    return this.tableSyncsService.updateSync(
      context,
      baseId,
      tableSyncId,
      body,
      req,
    );
  }

  @Delete(['/api/v2/meta/bases/:baseId/table-syncs/:tableSyncId'])
  @Acl('tableSyncDelete')
  async deleteSync(
    @TenantContext() context: NcContext,
    @Param('baseId') baseId: string,
    @Param('tableSyncId') tableSyncId: string,
    @Req() req: NcRequest,
  ) {
    return this.tableSyncsService.deleteSync(
      context,
      baseId,
      tableSyncId,
      req,
    );
  }

  @Post(['/api/v2/meta/bases/:baseId/table-syncs/:tableSyncId/resync'])
  @HttpCode(200)
  @Acl('tableSyncResync')
  async resync(
    @TenantContext() context: NcContext,
    @Param('baseId') baseId: string,
    @Param('tableSyncId') tableSyncId: string,
    @Req() req: NcRequest,
  ) {
    return this.tableSyncsService.resync(context, baseId, tableSyncId, req);
  }

  @Post(['/api/v2/meta/bases/:baseId/table-syncs/:tableSyncId/freeze'])
  @HttpCode(200)
  @Acl('tableSyncFreeze')
  async freeze(
    @TenantContext() context: NcContext,
    @Param('baseId') baseId: string,
    @Param('tableSyncId') tableSyncId: string,
    @Req() req: NcRequest,
  ) {
    return this.tableSyncsService.freeze(context, baseId, tableSyncId, req);
  }

  @Post(['/api/v2/meta/bases/:baseId/table-syncs/:tableSyncId/resume'])
  @HttpCode(200)
  @Acl('tableSyncResume')
  async resume(
    @TenantContext() context: NcContext,
    @Param('baseId') baseId: string,
    @Param('tableSyncId') tableSyncId: string,
    @Req() req: NcRequest,
  ) {
    return this.tableSyncsService.resume(context, baseId, tableSyncId, req);
  }

  @Post(['/api/v2/meta/bases/:baseId/table-syncs/resolve-link'])
  @HttpCode(200)
  @Acl('tableSyncResolveLink')
  async resolveLink(
    @TenantContext() context: NcContext,
    @Param('baseId') baseId: string,
    @Body() body: { link?: string },
  ) {
    // [CE-EE] F09 P2 scope: paste-mode shared-view link resolution
    return this.tableSyncsService.resolveLink(context, baseId, body);
  }
}
