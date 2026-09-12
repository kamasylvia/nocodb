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
import type { BaseVariableType } from 'nocodb-sdk';
import type { NcContext } from '~/interface/config';
import { GlobalGuard } from '~/guards/global/global.guard';
import { MetaApiLimiterGuard } from '~/guards/meta-api-limiter.guard';
import { Acl } from '~/middlewares/extract-ids/extract-ids.middleware';
import { TenantContext } from '~/decorators/tenant-context.decorator';
import { BaseVariablesService } from '~/services/base-variables.service';

// [CE-EE] F05: meta API surface for base variables (CRUD). The permission
// names are enforced through the standard role ACL (creator+ only).

@UseGuards(MetaApiLimiterGuard, GlobalGuard)
@Controller()
export class BaseVariablesController {
  constructor(private readonly baseVariablesService: BaseVariablesService) {}

  @Get(['/api/v1/db/meta/bases/:baseId/variables', '/api/v2/meta/bases/:baseId/variables'])
  @HttpCode(200)
  @Acl('baseVariableList')
  async list(
    @TenantContext() context: NcContext,
    @Param('baseId') baseId: string,
  ) {
    return this.baseVariablesService.list(context, baseId);
  }

  @Get([
    '/api/v1/db/meta/bases/:baseId/variables/:variableId',
    '/api/v2/meta/bases/:baseId/variables/:variableId',
  ])
  @HttpCode(200)
  @Acl('baseVariableList')
  async get(
    @TenantContext() context: NcContext,
    @Param('baseId') baseId: string,
    @Param('variableId') variableId: string,
  ) {
    return this.baseVariablesService.get(context, baseId, variableId);
  }

  @Post(['/api/v1/db/meta/bases/:baseId/variables', '/api/v2/meta/bases/:baseId/variables'])
  @HttpCode(200)
  @Acl('baseVariableCreate')
  async create(
    @TenantContext() context: NcContext,
    @Param('baseId') baseId: string,
    @Body() body: Partial<BaseVariableType>,
  ) {
    return this.baseVariablesService.create(context, baseId, body);
  }

  @Patch([
    '/api/v1/db/meta/bases/:baseId/variables/:variableId',
    '/api/v2/meta/bases/:baseId/variables/:variableId',
  ])
  @Acl('baseVariableUpdate')
  async update(
    @TenantContext() context: NcContext,
    @Param('baseId') baseId: string,
    @Param('variableId') variableId: string,
    @Body() body: Partial<BaseVariableType>,
  ) {
    return this.baseVariablesService.update(context, baseId, variableId, body);
  }

  @Delete([
    '/api/v1/db/meta/bases/:baseId/variables/:variableId',
    '/api/v2/meta/bases/:baseId/variables/:variableId',
  ])
  @Acl('baseVariableDelete')
  async delete(
    @TenantContext() context: NcContext,
    @Param('baseId') baseId: string,
    @Param('variableId') variableId: string,
  ) {
    return this.baseVariablesService.delete(context, baseId, variableId);
  }
}
