import { Injectable } from '@nestjs/common';
import type { NcContext, NcRequest } from '~/interface/config';
import Dashboard from '~/models/Dashboard';
import { NcError } from '~/helpers/catchError';

// [CE-EE] F10: dashboards CRUD — implements the EE "Create Dashboard"
// surface on CE. Widget rendering is deferred; a dashboard is a titled
// container scoped to its base.

const MAX_TITLE_LENGTH = 255;

@Injectable()
export class DashboardsService {
  async list(context: NcContext, baseId: string) {
    return Dashboard.list(context, baseId);
  }

  async get(context: NcContext, baseId: string, dashboardId: string) {
    return this.getDashboardWithBaseCheck(context, baseId, dashboardId);
  }

  async create(
    context: NcContext,
    baseId: string,
    req: NcRequest,
    body: { title?: string; description?: string },
  ) {
    if (body?.title !== undefined && typeof body.title !== 'string') {
      NcError.badRequest('Dashboard title must be a string');
    }
    const title = body?.title?.trim();
    if (!title) {
      NcError.badRequest('Dashboard title is required');
    }
    if (title.length > MAX_TITLE_LENGTH) {
      NcError.badRequest(
        `Dashboard title exceeds ${MAX_TITLE_LENGTH} characters limit`,
      );
    }
    if (
      body?.description !== undefined &&
      body.description !== null &&
      typeof body.description !== 'string'
    ) {
      NcError.badRequest('Dashboard description must be a string');
    }

    // duplicate titles within a base are allowed but confusing — reject
    const existing = await Dashboard.list(context, baseId);
    if (existing.some((d) => d.title === title)) {
      NcError.badRequest(
        `Dashboard title ${title} already exists in this base`,
      );
    }

    return Dashboard.insert(context, {
      base_id: baseId,
      title,
      description: body?.description,
      created_by: req.user.id,
      owned_by: req.user.id,
    });
  }

  async update(
    context: NcContext,
    baseId: string,
    dashboardId: string,
    body: { title?: string; description?: string },
  ) {
    // [CE-EE] F10 R1: description must be a string (or null to clear)
    if (
      body?.description !== undefined &&
      body.description !== null &&
      typeof body.description !== 'string'
    ) {
      NcError.badRequest('Dashboard description must be a string');
    }
    const dashboard = await this.getDashboardWithBaseCheck(
      context,
      baseId,
      dashboardId,
    );

    if (body?.title !== undefined) {
      if (typeof body.title !== 'string' || !body.title.trim()) {
        NcError.badRequest('Dashboard title must be a non-empty string');
      }
      if (body.title.length > MAX_TITLE_LENGTH) {
        NcError.badRequest(
          `Dashboard title exceeds ${MAX_TITLE_LENGTH} characters limit`,
        );
      }
      const existing = await Dashboard.list(context, baseId);
      if (
        existing.some(
          (d) => d.id !== dashboardId && d.title === body.title!.trim(),
        )
      ) {
        NcError.badRequest(
          `Dashboard title ${body.title.trim()} already exists in this base`,
        );
      }
    }

    await Dashboard.update(context, dashboardId, {
      ...(body.title !== undefined ? { title: body.title.trim() } : {}),
      ...(body.description !== undefined
        ? { description: body.description }
        : {}),
    });

    return Dashboard.get(context, dashboardId);
  }

  async delete(
    context: NcContext,
    baseId: string,
    dashboardId: string,
  ) {
    const dashboard = await this.getDashboardWithBaseCheck(
      context,
      baseId,
      dashboardId,
    );
    await Dashboard.delete(context, dashboardId);
    return true;
  }

  private async getDashboardWithBaseCheck(
    context: NcContext,
    baseId: string | null | undefined,
    dashboardId: string,
  ): Promise<Dashboard> {
    const dashboard = await Dashboard.get(context, dashboardId);
    // [CE-EE] F10: baseId may be absent on dashboard-only routes — match on
    // the row itself when the route does not carry a base segment
    if (!dashboard || (baseId && dashboard.base_id !== baseId)) {
      NcError.notFound('Dashboard not found');
    }
    return dashboard;
  }
}
