import { ProjectRoles, TableSyncStatus } from 'nocodb-sdk';
import type { NcContext, NcRequest } from '~/interface/config';
import { JobTypes } from '~/interface/Jobs';
import rolePermissions, { permissionScopes } from '~/utils/acl';
import { NcError } from '~/helpers/catchError';

// [CE-EE] F09: Table Sync P1 unit/integration tests — ACL creator+ semantics,
// service state machine (resync/freeze/resume/update), and the engine job's
// full-copy behaviour incl. the allowSystemColumn whitelist channel.
// (file suffix matches jest testRegex '(Integration|Source|Fork)\.spec\.ts$')

// ── module mocks (heavy DI graphs stay out of the jest node env) ──
jest.mock('~/services/tables.service', () => ({ TablesService: class {} }));
jest.mock('~/Noco', () => ({ default: { ncMeta: {} } }));
jest.mock('~/helpers/exportImportHelpers', () => ({
  generateUniqueName: (name: string, names: string[]) =>
    names.includes(name) ? `${name}_1` : name,
}));

const tableSyncState = {
  get: jest.fn(),
  getAny: jest.fn(),
  list: jest.fn(),
  insert: jest.fn(),
  update: jest.fn(),
  delete: jest.fn(),
  listMappings: jest.fn(),
  getMainMapping: jest.fn(),
  listColumnMappings: jest.fn(),
  insertColumnMappings: jest.fn(),
  deleteColumnMappings: jest.fn(),
};
jest.mock('~/models/TableSync', () => ({ __esModule: true, default: tableSyncState }));

const baseUserGet = jest.fn();
jest.mock('~/models/BaseUser', () => ({
  __esModule: true,
  default: { get: (...a: any[]) => baseUserGet(...a) },
}));

const baseGet = jest.fn();
jest.mock('~/models/Base', () => ({
  __esModule: true,
  default: { get: baseGet, getWithInfo: baseGet },
}));

jest.mock('~/models/Model', () => ({
  __esModule: true,
  default: {
    get: jest.fn(),
    list: jest.fn().mockResolvedValue([]),
    getBaseModelSQL: jest.fn(),
  },
}));
jest.mock('~/models/View', () => ({
  __esModule: true,
  default: {
    list: jest.fn().mockResolvedValue([]),
    // [CE-EE] F09 P2: resync re-validates the source view (allow_sync on)
    get: jest.fn().mockResolvedValue({ allow_sync: true, id: 'view1' }),
    getByUUID: jest.fn(),
  },
}));
jest.mock('~/models/Source', () => ({
  __esModule: true,
  default: { get: jest.fn() },
}));
jest.mock('~/utils/common/NcConnectionMgrv2', () => ({
  __esModule: true,
  default: { get: jest.fn() },
}));

import { TableSyncsService, isMirrorableSourceColumn } from '~/services/table-syncs.service';
import { TableSyncProcessor } from '~/modules/jobs/jobs/table-sync/table-sync.processor';
import TableSync from '~/models/TableSync';
import Model from '~/models/Model';

const ctx = { workspace_id: 'ws1', base_id: 'dest1' } as NcContext;
const req = { user: { id: 'u1' } } as unknown as NcRequest;

const syncRow = (over: Partial<any> = {}) => ({
  id: 'sync1',
  base_id: 'dest1',
  fk_workspace_id: 'ws1',
  title: 'mirror',
  selected_fields: null,
  on_delete_action: 'delete',
  sync_trigger: 'manual',
  status: TableSyncStatus.Active,
  source_input_mode: 'browse',
  // service.getSync calls this on the model instance
  toType() {
    return { ...this, toType: undefined };
  },
  ...over,
});

beforeEach(() => {
  jest.clearAllMocks();
});

describe('[CE-EE] F09 ACL semantics', () => {
  it('registers all ten tableSync ops in the base permission scope', () => {
    for (const op of [
      'tableSyncList',
      'tableSyncGet',
      'tableSyncSourceSchema',
      'tableSyncCreate',
      'tableSyncUpdate',
      'tableSyncDelete',
      'tableSyncResync',
      'tableSyncFreeze',
      'tableSyncResume',
      'tableSyncResolveLink',
    ]) {
      expect(permissionScopes.base).toContain(op);
    }
  });

  it('resolves to creator+ via the exclude model (editor lacks the ops, creator is not excluded)', () => {
    // editor uses the include model — tableSync* must NOT be in its includes
    expect(rolePermissions[ProjectRoles.EDITOR].include!.tableSyncCreate).toBeUndefined();
    expect(rolePermissions[ProjectRoles.EDITOR].include!.tableSyncDelete).toBeUndefined();
    // creator/owner use the exclude model — tableSync* must NOT be excluded
    expect(rolePermissions[ProjectRoles.CREATOR].exclude!.tableSyncCreate).toBeUndefined();
    expect(rolePermissions[ProjectRoles.OWNER].exclude!.tableSyncResume).toBeUndefined();
  });
});

describe('[CE-EE] F09 mirrorable column filter', () => {
  it('keeps plain static columns', () => {
    expect(
      isMirrorableSourceColumn({ uidt: 'SingleLineText' } as any),
    ).toBe(true);
    expect(isMirrorableSourceColumn({ uidt: 'Number' } as any)).toBe(true);
  });

  it('drops virtual / LTAR / pk / auto-managed / attachment columns', () => {
    expect(isMirrorableSourceColumn({ uidt: 'LinkToAnotherRecord' } as any)).toBe(false);
    expect(isMirrorableSourceColumn({ uidt: 'Lookup' } as any)).toBe(false);
    expect(isMirrorableSourceColumn({ uidt: 'Formula' } as any)).toBe(false);
    expect(isMirrorableSourceColumn({ uidt: 'SingleLineText', pk: true } as any)).toBe(false);
    expect(isMirrorableSourceColumn({ uidt: 'CreatedTime' } as any)).toBe(false);
    expect(isMirrorableSourceColumn({ uidt: 'LastModifiedTime' } as any)).toBe(false);
    expect(isMirrorableSourceColumn({ uidt: 'Order' } as any)).toBe(false);
    expect(isMirrorableSourceColumn({ uidt: 'ID' } as any)).toBe(false);
    expect(isMirrorableSourceColumn({ uidt: 'Attachment' } as any)).toBe(false);
  });
});

describe('[CE-EE] F09 service state machine', () => {
  const jobsService = { add: jest.fn().mockResolvedValue({ id: 'job-1' }) };
  const tablesService = {} as any;
  const service = new TableSyncsService(tablesService, { columnAdd: jest.fn(), columnDelete: jest.fn(), columnUpdate: jest.fn() } as any, jobsService as any);

  it('resync enqueues a TableSyncRun job and flips the row to syncing', async () => {
    (TableSync.get as any).mockResolvedValue(syncRow());
    (TableSync.update as any).mockImplementation(async (_c, _b, _id, patch) => ({
      ...syncRow(),
      ...patch,
    }));
    // [CE-EE] F09 P2: resync re-validates the source (mapping + allow_sync +
    // browse-mode base access)
    (TableSync.listMappings as any).mockResolvedValue([
      {
        role: 'main',
        source_workspace_id: 'w1',
        source_base_id: 'src1',
        source_table_id: 'srctbl',
        source_view_id: 'view1',
        dest_table_id: 'mirror1',
      },
    ]);
    baseUserGet.mockResolvedValue({ roles: 'editor' });

    await service.resync(ctx, 'dest1', 'sync1', req);

    expect(jobsService.add).toHaveBeenCalledWith(
      JobTypes.TableSyncRun,
      expect.objectContaining({ syncId: 'sync1', mode: 'full-resync' }),
    );
    expect(TableSync.update).toHaveBeenCalledWith(
      ctx,
      'dest1',
      'sync1',
      expect.objectContaining({
        sync_job_id: 'job-1',
        status: TableSyncStatus.Syncing,
      }),
    );
  });

  it('resync is rejected while the sync is paused or already running', async () => {
    (TableSync.get as any).mockResolvedValue(
      syncRow({ status: TableSyncStatus.Paused }),
    );
    await expect(service.resync(ctx, 'dest1', 'sync1', req)).rejects.toThrow(
      /paused/i,
    );

    (TableSync.get as any).mockResolvedValue(
      syncRow({ status: TableSyncStatus.Syncing }),
    );
    await expect(service.resync(ctx, 'dest1', 'sync1', req)).rejects.toThrow(
      /already running/i,
    );
    expect(jobsService.add).not.toHaveBeenCalled();
  });

  it('freeze only from a non-running state; resume only from paused', async () => {
    (TableSync.get as any).mockResolvedValue(syncRow());
    (TableSync.update as any).mockResolvedValue(syncRow());
    await service.freeze(ctx, 'dest1', 'sync1', req);
    expect(TableSync.update).toHaveBeenCalledWith(
      ctx,
      'dest1',
      'sync1',
      expect.objectContaining({ status: TableSyncStatus.Paused }),
    );

    (TableSync.get as any).mockResolvedValue(
      syncRow({ status: TableSyncStatus.Syncing }),
    );
    await expect(service.freeze(ctx, 'dest1', 'sync1', req)).rejects.toThrow(
      /running/i,
    );

    (TableSync.get as any).mockResolvedValue(syncRow());
    await expect(service.resume(ctx, 'dest1', 'sync1', req)).rejects.toThrow(
      /not paused/i,
    );
    (TableSync.get as any).mockResolvedValue(
      syncRow({ status: TableSyncStatus.Paused }),
    );
    await service.resume(ctx, 'dest1', 'sync1', req);
    expect(TableSync.update).toHaveBeenCalledWith(
      ctx,
      'dest1',
      'sync1',
      expect.objectContaining({ status: TableSyncStatus.Active }),
    );
  });

  it('updateSync rejects an empty selected_fields array (P2: empty mirrors are invalid)', async () => {
    (TableSync.get as any).mockResolvedValue(syncRow());
    await expect(
      service.updateSync(ctx, 'dest1', 'sync1', { selected_fields: [] }, req),
    ).rejects.toThrow(/non-empty array or null/i);
  });

  it('sourceSchema requires read access on the source base', async () => {
    baseUserGet.mockResolvedValue(null);
    await expect(
      service.sourceSchema(
        ctx,
        'dest1',
        { sourceBaseId: 'src1', sourceTableId: 't1' },
        req,
      ),
    ).rejects.toThrow();
  });
});

describe('[CE-EE] F09 engine job (full copy)', () => {
  const makeBaseModel = (rows: any[]) => ({
    // [CE-EE] F09 P3: support the `(RemoteId,eq,<id>)` lookups the incremental
    // partial pull makes against the mirror (full passes pass no where)
    list: jest.fn().mockImplementation((args: any = {}) => {
      const where = typeof args?.where === 'string' ? args.where : '';
      const m = where.match(/\(RemoteId,eq,([^)]+)\)/);
      if (m) {
        return Promise.resolve({
          list: rows.filter((r) => String(r.RemoteId) === m[1]),
        });
      }
      return Promise.resolve({ list: rows });
    }),
    bulkInsert: jest.fn().mockResolvedValue(undefined),
    bulkUpdate: jest.fn().mockResolvedValue(undefined),
    bulkDelete: jest.fn().mockResolvedValue(undefined),
    readByPk: jest.fn().mockResolvedValue(null),
    extractPksValues: (d: any) => d?.Id ?? null,
  });

  const srcCols = [
    { id: 'c1', title: 'Title', column_name: 'title' },
    { id: 'c2', title: 'Qty', column_name: 'qty' },
    // [CE-EE] F09 P3: watermark anchor — excluded from mirroring (not mapped)
    { id: 'c3', title: 'UpdatedAt', column_name: 'updated_at', uidt: 'LastModifiedTime' },
  ];
  const destCols = [
    { id: 'd0', title: 'Id', column_name: 'id', pk: true },
    { id: 'd1', title: 'Title', column_name: 'title' },
    { id: 'd2', title: 'Qty', column_name: 'qty' },
    { id: 'd3', title: 'RemoteId', column_name: 'remoteid' },
    { id: 'd4', title: 'RemoteDeleted', column_name: 'remotedeleted' },
  ];
  const asModel = (id: string, columns: any[]) => ({
    id,
    deleted: false,
    source_id: 's1',
    columns,
    getColumns: jest.fn(),
  });

  const setup = (srcRows: any[], destRows: any[]) => {
    const srcBaseModel = makeBaseModel(srcRows);
    const destBaseModel = makeBaseModel(destRows);
    (TableSync.getAny as any).mockResolvedValue(syncRow());
    (TableSync.getMainMapping as any).mockResolvedValue({
      source_workspace_id: 'ws1',
      source_base_id: 'src1',
      source_table_id: 't_src',
      dest_table_id: 't_dest',
    });
    (TableSync.listColumnMappings as any).mockResolvedValue([
      { source_column_id: 'c1', dest_column_id: 'd1' },
      { source_column_id: 'c2', dest_column_id: 'd2' },
    ]);
    (TableSync.update as any).mockResolvedValue(null);
    (Model.get as any).mockImplementation(async (_ctx, id) =>
      id === 't_src' ? asModel('t_src', srcCols) : asModel('t_dest', destCols),
    );
    (Model.getBaseModelSQL as any).mockImplementation(async (_ctx, args) =>
      args.model.id === 't_src' ? srcBaseModel : destBaseModel,
    );
    return { srcBaseModel, destBaseModel };
  };

  it('full-create inserts source rows keyed by RemoteId through the whitelist channel', async () => {
    const { destBaseModel } = setup(
      [
        { Id: 1, Title: 'row1', Qty: 1 },
        { Id: 2, Title: 'row2', Qty: 2 },
      ],
      [],
    );
    const processor = new TableSyncProcessor();

    await processor.job({ data: { syncId: 'sync1', req } } as any);

    expect(destBaseModel.bulkInsert).toHaveBeenCalledTimes(1);
    const [inserted, params] = destBaseModel.bulkInsert.mock.calls[0];
    expect(inserted).toHaveLength(2);
    expect(inserted[0]).toMatchObject({ Title: 'row1', Qty: 1, RemoteId: '1' });
    // [CE-EE] F09: the engine whitelist channel must be on and the trusted
    // internal-copy flags set — regular HTTP callers never get these
    expect(params.allowSystemColumn).toBe(true);
    expect(params.skipPermissionCheck).toBe(true);
    expect(params.skipAttachmentOwnershipCheck).toBe(true);
    expect(TableSync.update).toHaveBeenCalledWith(
      expect.anything(),
      'dest1',
      'sync1',
      expect.objectContaining({ status: TableSyncStatus.Active }),
    );
  });

  it('resync upserts changed rows and deletes rows missing from the source (delete policy)', async () => {
    const { destBaseModel } = setup(
      [{ Id: 1, Title: 'row1-updated', Qty: 1 }],
      [
        { Id: 11, Title: 'row1', Qty: 1, RemoteId: '1' },
        { Id: 12, Title: 'gone', Qty: 9, RemoteId: '2' },
      ],
    );
    const processor = new TableSyncProcessor();

    await processor.job({ data: { syncId: 'sync1', req } } as any);

    expect(destBaseModel.bulkInsert).not.toHaveBeenCalled();
    expect(destBaseModel.bulkUpdate).toHaveBeenCalledTimes(1);
    const [updated] = destBaseModel.bulkUpdate.mock.calls[0];
    expect(updated).toHaveLength(1);
    expect(updated[0]).toMatchObject({ Id: 11, Title: 'row1-updated', RemoteId: '1' });
    expect(destBaseModel.bulkDelete).toHaveBeenCalledTimes(1);
    expect(destBaseModel.bulkDelete.mock.calls[0][0]).toEqual([{ Id: 12 }]);
  });

  it('marks missing rows via RemoteDeleted under the mark_deleted policy', async () => {
    const { destBaseModel } = setup(
      [{ Id: 1, Title: 'row1', Qty: 1 }],
      [
        { Id: 11, Title: 'row1', Qty: 1, RemoteId: '1' },
        { Id: 12, Title: 'gone', Qty: 9, RemoteId: '2' },
      ],
    );
    // after setup(): setup pins the default sync row on getAny
    (TableSync.getAny as any).mockResolvedValue(
      syncRow({ on_delete_action: 'mark_deleted' }),
    );
    const processor = new TableSyncProcessor();

    await processor.job({ data: { syncId: 'sync1', req } } as any);

    expect(destBaseModel.bulkDelete).not.toHaveBeenCalled();
    // [CE-EE] F09 P3: the sweep flags are aggregated into the same chunked
    // bulkUpdate batch as the upserts — the mark for Id 12 must be in it
    const [marked] = destBaseModel.bulkUpdate.mock.calls.at(-1);
    expect(marked).toEqual(
      expect.arrayContaining([{ Id: 12, RemoteDeleted: true }]),
    );
  });

  it('records engine failures on the sync row (status error + last_error)', async () => {
    const { destBaseModel } = setup(
      [{ Id: 1, Title: 'row1', Qty: 1 }],
      [],
    );
    destBaseModel.bulkInsert.mockRejectedValue(new Error('db exploded'));
    const processor = new TableSyncProcessor();

    await processor.job({ data: { syncId: 'sync1', req } } as any);

    expect(TableSync.update).toHaveBeenCalledWith(
      expect.anything(),
      'dest1',
      'sync1',
      expect.objectContaining({
        status: TableSyncStatus.Error,
        last_error: 'db exploded',
      }),
    );
  });

  it('skips paused syncs', async () => {
    (TableSync.getAny as any).mockResolvedValue(
      syncRow({ status: TableSyncStatus.Paused }),
    );
    const processor = new TableSyncProcessor();
    await processor.job({ data: { syncId: 'sync1', req } } as any);
    expect(Model.get).not.toHaveBeenCalled();
  });

  // [CE-EE] F09 P3: incremental mode — realtime taps (affectedIdsBySource)
  // and the watermark catch-up pull
  it('incremental run pulls affected rows by pk and applies the delete policy to vanished ids', async () => {
    const { srcBaseModel, destBaseModel } = setup(
      [{ Id: 1, Title: 'row1-updated', Qty: 1 }],
      [
        { Id: 11, Title: 'row1', Qty: 1, RemoteId: '1' },
        { Id: 99, Title: 'stale', Qty: 9, RemoteId: '77' },
      ],
    );
    srcBaseModel.readByPk.mockImplementation(async (id: any) =>
      String(id) === '1' ? { Id: 1, Title: 'row1-updated', Qty: 1 } : null,
    );

    await processor_job({
      mode: 'incremental',
      affectedIdsBySource: { t_src: ['1', '77'] },
    });

    // row 1 was upserted in place; id 77 is gone from the source and the
    // delete policy removes its mirror row
    expect(destBaseModel.bulkInsert).not.toHaveBeenCalled();
    expect(destBaseModel.bulkUpdate).toHaveBeenCalledTimes(1);
    expect(destBaseModel.bulkUpdate.mock.calls[0][0]).toEqual([
      { Id: 11, Title: 'row1-updated', Qty: 1, RemoteId: '1' },
    ]);
    expect(destBaseModel.bulkDelete).toHaveBeenCalledTimes(1);
    expect(destBaseModel.bulkDelete.mock.calls[0][0]).toEqual([{ Id: 99 }]);
    // the disappearance sweep never runs on a partial pull
    expect(srcBaseModel.list).not.toHaveBeenCalled();
  });

  it('mark_deleted policy flags vanished affected ids instead of deleting them', async () => {
    const { srcBaseModel, destBaseModel } = setup(
      [],
      [{ Id: 99, Title: 'stale', Qty: 9, RemoteId: '77' }],
    );
    srcBaseModel.readByPk.mockResolvedValue(null);
    (TableSync.getAny as any).mockResolvedValue(
      syncRow({ on_delete_action: 'mark_deleted' }),
    );

    await processor_job({
      mode: 'incremental',
      affectedIdsBySource: { t_src: ['77'] },
    });

    expect(destBaseModel.bulkDelete).not.toHaveBeenCalled();
    expect(destBaseModel.bulkUpdate.mock.calls.at(-1)[0]).toEqual([
      { Id: 99, RemoteDeleted: true },
    ]);
  });

  it('incremental run without ids falls back to the full pass with sweep (R2 lane4 E1\')', async () => {
    const { destBaseModel } = setup(
      [
        { Id: 1, Title: 'row1-changed', Qty: 1, UpdatedAt: '2026-09-19T01:00:00Z' },
        { Id: 2, Title: 'row2-changed', Qty: 2, UpdatedAt: '2026-09-19T02:00:00Z' },
      ],
      [
        { Id: 11, Title: 'row1', Qty: 1, RemoteId: '1' },
        { Id: 12, Title: 'row2', Qty: 2, RemoteId: '2' },
      ],
    );
    (TableSync.getAny as any).mockResolvedValue(
      syncRow({ last_synced_at: '2026-09-19T00:30:00.000Z' }),
    );

    await processor_job({ mode: 'incremental' });

    // watermark pull: both mock rows update in place — and the sweep that
    // would touch unobserved mirror rows is skipped entirely
    expect(destBaseModel.bulkInsert).not.toHaveBeenCalled();
    expect(destBaseModel.bulkDelete).not.toHaveBeenCalled();
    expect(destBaseModel.bulkUpdate).toHaveBeenCalledTimes(1);
    const [updated] = destBaseModel.bulkUpdate.mock.calls[0];
    expect(updated).toEqual(
      expect.arrayContaining([
        expect.objectContaining({ Id: 11, Title: 'row1-changed', RemoteId: '1' }),
        expect.objectContaining({ Id: 12, Title: 'row2-changed', RemoteId: '2' }),
      ]),
    );
    expect(TableSync.update).toHaveBeenCalledWith(
      expect.anything(),
      'dest1',
      'sync1',
      expect.objectContaining({
        status: TableSyncStatus.Active,
        last_synced_at: expect.any(String),
      }),
    );
  });

  // small wrapper: run the processor job with extra job data merged in
  async function processor_job(extra: Record<string, any>) {
    const processor = new TableSyncProcessor();
    await processor.job({
      data: { syncId: 'sync1', req, ...extra },
    } as any);
  }

  it('rejects an unknown sync trigger at the API boundary', async () => {
    // [CE-EE] F09 P3: realtime was unlocked (previously rejected as
    // paywalled) — manual and realtime are both accepted, everything else 400s
    const jobsService = { add: jest.fn() };
    const service = new TableSyncsService({} as any, {} as any, jobsService as any);
    await expect(
      service.createSync(
        ctx,
        'dest1',
        {
          sourceBaseId: 'src1',
          sourceTableId: 't1',
          syncTrigger: 'hourly',
        },
        req,
      ),
    ).rejects.toThrow(/invalid sync trigger/i);
    expect(jobsService.add).not.toHaveBeenCalled();
  });
});

// ──────────────────────────────────────────────────────────────────────────
// [CE-EE] F09 P4: LTAR link layers — LinkedShadow pass + junction RemoteId
// pair recomputation + junction orphan cleanup on incremental deletes
// ──────────────────────────────────────────────────────────────────────────
describe('[CE-EE] F09 P4 engine (link layers)', () => {
  const makeBaseModel = (rows: any[]) => ({
    list: jest.fn().mockImplementation((args: any = {}) => {
      const where = typeof args?.where === 'string' ? args.where : '';
      const m = where.match(/\(RemoteId,eq,([^)]+)\)/);
      if (m) {
        return Promise.resolve({
          list: rows.filter((r) => String(r.RemoteId) === m[1]),
        });
      }
      return Promise.resolve({ list: rows });
    }),
    bulkInsert: jest.fn().mockResolvedValue(undefined),
    bulkUpdate: jest.fn().mockResolvedValue(undefined),
    bulkDelete: jest.fn().mockResolvedValue(undefined),
    readByPk: jest.fn().mockResolvedValue(null),
    extractPksValues: (d: any) => d?.Id ?? null,
  });

  /** knex-style chainable query builder recorder for junction writes */
  const makeJunctionBm = (rows: any[]) => {
    const qbs: any[] = [];
    const bm: any = {
      qbs,
      getTnPath: jest.fn(() => 'junction_tn'),
      dbDriver: jest.fn(() => {
        const qb: any = {};
        for (const m of ['select', 'where', 'whereIn', 'del', 'insert', 'limit', 'offset', 'first']) {
          qb[m] = jest.fn().mockReturnValue(qb);
        }
        qbs.push(qb);
        return qb;
      }),
      // selects and writes both funnel through execAndParse — writes ignore
      // the return value, selects read the junction rows
      execAndParse: jest.fn().mockResolvedValue(rows),
    };
    return bm;
  };

  const mmOpt = (
    mmModelId: string,
    relatedModelId: string,
    mainSideColName: string,
    shadowSideColName: string,
    junctionModel: any,
  ) => ({
    type: 'mm',
    fk_mm_model_id: mmModelId,
    fk_related_model_id: relatedModelId,
    getMMModel: jest.fn().mockResolvedValue(junctionModel),
    getMMChildColumn: jest
      .fn()
      .mockResolvedValue({ column_name: mainSideColName }),
    getMMParentColumn: jest
      .fn()
      .mockResolvedValue({ column_name: shadowSideColName }),
  });

  const asModel = (id: string, columns: any[]) => ({
    id,
    deleted: false,
    source_id: 's1',
    title: id,
    columns,
    getColumns: jest.fn(),
  });

  it('full pass mirrors the linked table into its shadow and rebuilds junction RemoteId pairs', async () => {
    // main source (T) rows; main mirror (M) rows already synced; row 3 is
    // new so the main pass takes the insert path (payload assertions)
    const srcBaseModel = makeBaseModel([
      { Id: 1, Title: 'row1', Qty: 1 },
      { Id: 2, Title: 'row2', Qty: 2 },
      { Id: 3, Title: 'row3' },
    ]);
    const destBaseModel = makeBaseModel([
      { Id: 11, Title: 'row1', Qty: 1, RemoteId: '1' },
      { Id: 12, Title: 'row2', Qty: 2, RemoteId: '2' },
    ]);
    // linked table (RT) + its shadow (S) — rt row 101 already mirrored so
    // the shadow pass takes the update path
    const rtBaseModel = makeBaseModel([{ Id: 101, Title: 'rt1' }]);
    const shadowBaseModel = makeBaseModel([
      { Id: 21, Title: 'rt1', RemoteId: '101' },
    ]);
    // source junction (T×RT pairs) + dest junction (M×S pairs)
    const srcJunctionBm = makeJunctionBm([
      { __main: '1', __shadow: '101' },
      { __main: '2', __shadow: '102' }, // rt row 102 not mirrored yet → skipped
    ]);
    const destJunctionBm = makeJunctionBm([
      { __main: '11', __shadow: '21' }, // existing pair stays
      { __main: '19', __shadow: '21' }, // source dropped it → removed
    ]);

    const srcCols = [
      { id: 'c1', title: 'Title', column_name: 'title' },
      { id: 'cl1', title: 'RTs', column_name: 'rts', uidt: 'Links', getColOptions: async () => srcLinkOpt },
    ];
    const destCols = [
      { id: 'd0', title: 'Id', column_name: 'id', pk: true },
      { id: 'd1', title: 'Title', column_name: 'title' },
      { id: 'd3', title: 'RemoteId', column_name: 'remoteid' },
      { id: 'd4', title: 'RemoteDeleted', column_name: 'remotedeleted' },
      { id: 'dl1', title: 'RTs', column_name: 'rts', uidt: 'Links', getColOptions: async () => destLinkOpt },
    ];
    const rtModel = asModel('t_rt', [
      { id: 'r1', title: 'Title', column_name: 'title' },
    ]);
    const shadowModel = asModel('t_shadow', [
      { id: 's0', title: 'Id', column_name: 'id', pk: true },
      { id: 's1', title: 'Title', column_name: 'title' },
      { id: 's3', title: 'RemoteId', column_name: 'remoteid' },
      { id: 's4', title: 'RemoteDeleted', column_name: 'remotedeleted' },
    ]);
    const srcJuncModel = asModel('src_junc', []);
    const destJuncModel = asModel('dest_junc', []);
    const srcLinkOpt = mmOpt('src_junc', 't_rt', 't_src_id', 't_rt_id', srcJuncModel);
    const destLinkOpt = mmOpt('dest_junc', 't_shadow', 'd_main', 'd_shadow', destJuncModel);

    (TableSync.getAny as any).mockResolvedValue(syncRow());
    (TableSync.getMainMapping as any).mockResolvedValue({
      source_workspace_id: 'ws1',
      source_base_id: 'src1',
      source_table_id: 't_src',
      dest_table_id: 't_dest',
    });
    (TableSync.listMappings as any).mockResolvedValue([
      { id: 'map_main', role: 'main', source_table_id: 't_src', dest_table_id: 't_dest' },
      { id: 'map_shadow', role: 'linked_shadow', source_table_id: 't_rt', dest_table_id: 't_shadow' },
      { id: 'map_junc', role: 'junction', dest_table_id: 'dest_junc' },
    ]);
    (TableSync.listColumnMappings as any).mockResolvedValue([
      { source_column_id: 'c1', dest_column_id: 'd1', fk_table_sync_mapping_id: 'map_main', source_table_id: 't_src' },
      { source_column_id: 'cl1', dest_column_id: 'dl1', fk_table_sync_mapping_id: 'map_main', source_table_id: 't_src' },
      { source_column_id: 'r1', dest_column_id: 's1', fk_table_sync_mapping_id: 'map_shadow', source_table_id: 't_rt' },
    ]);
    (TableSync.update as any).mockResolvedValue(null);
    (Model.get as any).mockImplementation(async (_ctx, id) => {
      if (id === 't_src') return asModel('t_src', srcCols);
      if (id === 't_dest') return asModel('t_dest', destCols);
      if (id === 't_rt') return rtModel;
      if (id === 't_shadow') return shadowModel;
      return null;
    });
    (Model.getBaseModelSQL as any).mockImplementation(async (_ctx, args) => {
      switch (args.model.id) {
        case 't_src': return srcBaseModel;
        case 't_dest': return destBaseModel;
        case 't_rt': return rtBaseModel;
        case 't_shadow': return shadowBaseModel;
        case 'src_junc': return srcJunctionBm;
        case 'dest_junc': return destJunctionBm;
        default: return null;
      }
    });

    const processor = new TableSyncProcessor();
    await processor.job({ data: { syncId: 'sync1', req } } as any);

    // shadow pass: rt row 101 already mirrored → in-place update via the
    // whitelist channel, keyed by RemoteId
    expect(shadowBaseModel.bulkUpdate).toHaveBeenCalledTimes(1);
    const [shadowUpdated] = shadowBaseModel.bulkUpdate.mock.calls[0];
    expect(shadowUpdated).toEqual([
      expect.objectContaining({ Id: 21, Title: 'rt1', RemoteId: '101' }),
    ]);

    // link column never enters the scalar payload of the main mirror
    // (row 3 took the main insert path)
    expect(destBaseModel.bulkInsert).toHaveBeenCalledTimes(1);
    const [mainInserted] = destBaseModel.bulkInsert.mock.calls[0];
    expect(mainInserted).toEqual([
      expect.objectContaining({ Title: 'row3', RemoteId: '3' }),
    ]);
    expect(mainInserted[0].RTs).toBeUndefined();

    // junction recompute: rt row 102 has no shadow row → its pair is
    // SKIPPED (dangling source pair); the existing pair ('11'|'21') stays;
    // the source-dropped pair ('19'|'21') is removed
    const inserts = destJunctionBm.qbs.filter((q) => q.insert.mock.calls.length);
    expect(inserts).toHaveLength(0);
    const dels = destJunctionBm.qbs.filter((q) => q.del.mock.calls.length);
    expect(dels).toHaveLength(1);
    expect(dels[0].where).toHaveBeenCalledWith({ d_main: '19', d_shadow: '21' });

    expect(TableSync.update).toHaveBeenCalledWith(
      expect.anything(),
      'dest1',
      'sync1',
      expect.objectContaining({ status: TableSyncStatus.Active }),
    );
  });

  it('full pass inserts junction rows when the shadow gained the missing side', async () => {
    const srcBaseModel = makeBaseModel([{ Id: 1, Title: 'row1' }]);
    const destBaseModel = makeBaseModel([{ Id: 11, Title: 'row1', RemoteId: '1' }]);
    const rtBaseModel = makeBaseModel([{ Id: 101, Title: 'rt1' }]);
    // shadow starts empty and the mock must reflect the bulkInsert so the
    // post-pass RemoteId scan sees the new row (the real engine re-reads)
    const shadowRows: any[] = [];
    const shadowBaseModel = makeBaseModel(shadowRows);
    shadowBaseModel.bulkInsert.mockImplementation(async (rows: any[]) => {
      rows.forEach((r, i) => shadowRows.push({ Id: 30 + i, ...r }));
    });
    const srcJunctionBm = makeJunctionBm([{ __main: '1', __shadow: '101' }]);
    const destJunctionBm = makeJunctionBm([]);

    const srcCols = [
      { id: 'cl1', title: 'RTs', column_name: 'rts', uidt: 'Links', getColOptions: async () => srcLinkOpt },
    ];
    const destCols = [
      { id: 'd0', title: 'Id', column_name: 'id', pk: true },
      { id: 'd3', title: 'RemoteId', column_name: 'remoteid' },
      { id: 'd4', title: 'RemoteDeleted', column_name: 'remotedeleted' },
      { id: 'dl1', title: 'RTs', column_name: 'rts', uidt: 'Links', getColOptions: async () => destLinkOpt },
    ];
    const srcJuncModel = asModel('src_junc', []);
    const destJuncModel = asModel('dest_junc', []);
    const srcLinkOpt = mmOpt('src_junc', 't_rt', 't_src_id', 't_rt_id', srcJuncModel);
    const destLinkOpt = mmOpt('dest_junc', 't_shadow', 'd_main', 'd_shadow', destJuncModel);

    (TableSync.getAny as any).mockResolvedValue(syncRow());
    (TableSync.getMainMapping as any).mockResolvedValue({
      source_workspace_id: 'ws1',
      source_base_id: 'src1',
      source_table_id: 't_src',
      dest_table_id: 't_dest',
    });
    (TableSync.listMappings as any).mockResolvedValue([
      { id: 'map_main', role: 'main', source_table_id: 't_src', dest_table_id: 't_dest' },
      { id: 'map_shadow', role: 'linked_shadow', source_table_id: 't_rt', dest_table_id: 't_shadow' },
      { id: 'map_junc', role: 'junction', dest_table_id: 'dest_junc' },
    ]);
    (TableSync.listColumnMappings as any).mockResolvedValue([
      { source_column_id: 'cl1', dest_column_id: 'dl1', fk_table_sync_mapping_id: 'map_main', source_table_id: 't_src' },
      { source_column_id: 'r1', dest_column_id: 's1', fk_table_sync_mapping_id: 'map_shadow', source_table_id: 't_rt' },
    ]);
    (TableSync.update as any).mockResolvedValue(null);
    (Model.get as any).mockImplementation(async (_ctx, id) => {
      if (id === 't_src') return asModel('t_src', srcCols);
      if (id === 't_dest') return asModel('t_dest', destCols);
      if (id === 't_rt') return asModel('t_rt', [{ id: 'r1', title: 'Title', column_name: 'title' }]);
      if (id === 't_shadow') return asModel('t_shadow', [
        { id: 's0', title: 'Id', column_name: 'id', pk: true },
        { id: 's1', title: 'Title', column_name: 'title' },
        { id: 's3', title: 'RemoteId', column_name: 'remoteid' },
        { id: 's4', title: 'RemoteDeleted', column_name: 'remotedeleted' },
      ]);
      return null;
    });
    (Model.getBaseModelSQL as any).mockImplementation(async (_ctx, args) => {
      switch (args.model.id) {
        case 't_src': return srcBaseModel;
        case 't_dest': return destBaseModel;
        case 't_rt': return rtBaseModel;
        case 't_shadow': return shadowBaseModel;
        case 'src_junc': return srcJunctionBm;
        case 'dest_junc': return destJunctionBm;
        default: return null;
      }
    });

    const processor = new TableSyncProcessor();
    await processor.job({ data: { syncId: 'sync1', req } } as any);

    // shadow row inserted first, then the junction pair lands
    expect(shadowBaseModel.bulkInsert).toHaveBeenCalledTimes(1);
    const inserts = destJunctionBm.qbs.filter((q) => q.insert.mock.calls.length);
    expect(inserts).toHaveLength(1);
    // '30' is the mock's generated pk for the inserted shadow row — the pair
    // is keyed by the DEST pks (mirror row 11 ↔ shadow row of rt 101)
    expect(inserts[0].insert).toHaveBeenCalledWith([
      { d_main: '11', d_shadow: '30' },
    ]);
  });

  it('incremental deletes clean the junction rows referencing the removed mirror rows', async () => {
    const srcBaseModel = makeBaseModel([]);
    const destBaseModel = makeBaseModel([
      { Id: 11, Title: 'gone', RemoteId: '77' },
    ]);
    const srcJunctionBm = makeJunctionBm([]);
    const destJunctionBm = makeJunctionBm([]);

    const srcCols = [
      { id: 'cl1', title: 'RTs', column_name: 'rts', uidt: 'Links', getColOptions: async () => srcLinkOpt },
    ];
    const destCols = [
      { id: 'd0', title: 'Id', column_name: 'id', pk: true },
      { id: 'd3', title: 'RemoteId', column_name: 'remoteid' },
      { id: 'd4', title: 'RemoteDeleted', column_name: 'remotedeleted' },
      { id: 'dl1', title: 'RTs', column_name: 'rts', uidt: 'Links', getColOptions: async () => destLinkOpt },
    ];
    const srcJuncModel = asModel('src_junc', []);
    const destJuncModel = asModel('dest_junc', []);
    const srcLinkOpt = mmOpt('src_junc', 't_rt', 't_src_id', 't_rt_id', srcJuncModel);
    const destLinkOpt = mmOpt('dest_junc', 't_shadow', 'd_main', 'd_shadow', destJuncModel);

    (TableSync.getAny as any).mockResolvedValue(syncRow());
    (TableSync.getMainMapping as any).mockResolvedValue({
      source_workspace_id: 'ws1',
      source_base_id: 'src1',
      source_table_id: 't_src',
      dest_table_id: 't_dest',
    });
    (TableSync.listMappings as any).mockResolvedValue([
      { id: 'map_main', role: 'main', source_table_id: 't_src', dest_table_id: 't_dest' },
      { id: 'map_junc', role: 'junction', dest_table_id: 'dest_junc' },
    ]);
    (TableSync.listColumnMappings as any).mockResolvedValue([
      { source_column_id: 'cl1', dest_column_id: 'dl1', fk_table_sync_mapping_id: 'map_main', source_table_id: 't_src' },
    ]);
    (TableSync.update as any).mockResolvedValue(null);
    (Model.get as any).mockImplementation(async (_ctx, id) => {
      if (id === 't_src') return asModel('t_src', srcCols);
      if (id === 't_dest') return asModel('t_dest', destCols);
      return null;
    });
    (Model.getBaseModelSQL as any).mockImplementation(async (_ctx, args) => {
      switch (args.model.id) {
        case 't_src': return srcBaseModel;
        case 't_dest': return destBaseModel;
        case 'src_junc': return srcJunctionBm;
        case 'dest_junc': return destJunctionBm;
        default: return null;
      }
    });
    destBaseModel.readByPk.mockResolvedValue(null); // id 77 vanished

    const processor = new TableSyncProcessor();
    await processor.job({
      data: {
        syncId: 'sync1',
        req,
        mode: 'incremental',
        affectedIdsBySource: { t_src: ['77'] },
      },
    } as any);

    // mirror row deleted (delete policy)…
    expect(destBaseModel.bulkDelete).toHaveBeenCalledTimes(1);
    // …and the junction rows referencing dest pk 11 are swept
    const dels = destJunctionBm.qbs.filter((q) => q.del.mock.calls.length);
    expect(dels).toHaveLength(1);
    expect(dels[0].whereIn).toHaveBeenCalledWith('d_main', ['11']);
  });
});
