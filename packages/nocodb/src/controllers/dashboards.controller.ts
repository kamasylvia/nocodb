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
import { DashboardsService } from '~/services/dashboards.service';

// [CE-EE] F10: dashboards meta API (CRUD). Permissions follow the standard
// role ACL (creator+ only).

@UseGuards(MetaApiLimiterGuard, GlobalGuard)
@Controller()
export class DashboardsController {
  constructor(private readonly dashboardsService: DashboardsService) {}

  @Get(['/api/v2/meta/bases/:baseId/dashboards'])
  @HttpCode(200)
  @Acl('dashboardList')
  async list(
    @TenantContext() context: NcContext,
    @Param('baseId') baseId: string,
  ) {
    return this.dashboardsService.list(context, baseId);
  }

  @Get([
    '/api/v2/meta/bases/:baseId/dashboards/:dashboardId',
    '/api/v2/meta/dashboards/:dashboardId',
  ])
  @HttpCode(200)
  @Acl('dashboardList')
  async get(
    @TenantContext() context: NcContext,
    @Param('baseId') baseId: string | undefined,
    @Param('dashboardId') dashboardId: string,
  ) {
    return this.dashboardsService.get(context, baseId, dashboardId);
  }

  @Post(['/api/v2/meta/bases/:baseId/dashboards'])
  @HttpCode(200)
  @Acl('dashboardCreate')
  async create(
    @TenantContext() context: NcContext,
    @Param('baseId') baseId: string,
    @Body() body: { title?: string; description?: string },
    @Req() req: NcRequest,
  ) {
    return this.dashboardsService.create(context, baseId, req, body);
  }

  @Patch([
    '/api/v2/meta/bases/:baseId/dashboards/:dashboardId',
    '/api/v2/meta/dashboards/:dashboardId',
  ])
  @Acl('dashboardUpdate')
  async update(
    @TenantContext() context: NcContext,
    @Param('baseId') baseId: string | undefined,
    @Param('dashboardId') dashboardId: string,
    @Body() body: { title?: string; description?: string },
  ) {
    return this.dashboardsService.update(
      context,
      baseId,
      dashboardId,
      body,
    );
  }

  @Delete([
    '/api/v2/meta/bases/:baseId/dashboards/:dashboardId',
    '/api/v2/meta/dashboards/:dashboardId',
  ])
  @Acl('dashboardDelete')
  async delete(
    @TenantContext() context: NcContext,
    @Param('baseId') baseId: string | undefined,
    @Param('dashboardId') dashboardId: string,
  ) {
    return this.dashboardsService.delete(
      context,
      baseId,
      dashboardId,
    );
  }
}
