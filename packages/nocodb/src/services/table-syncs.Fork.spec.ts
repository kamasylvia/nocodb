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
  default: { list: jest.fn().mockResolvedValue([]) },
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
  const service = new TableSyncsService(tablesService, jobsService as any);

  it('resync enqueues a TableSyncRun job and flips the row to syncing', async () => {
    (TableSync.get as any).mockResolvedValue(syncRow());
    (TableSync.update as any).mockImplementation(async (_c, _b, _id, patch) => ({
      ...syncRow(),
      ...patch,
    }));

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

  it('updateSync rejects selected_fields mutation (P2 scope)', async () => {
    (TableSync.get as any).mockResolvedValue(syncRow());
    await expect(
      service.updateSync(ctx, 'dest1', 'sync1', { selected_fields: ['A'] }, req),
    ).rejects.toThrow(/not supported/i);
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
    list: jest.fn().mockResolvedValue({ list: rows }),
    bulkInsert: jest.fn().mockResolvedValue(undefined),
    bulkUpdate: jest.fn().mockResolvedValue(undefined),
    bulkDelete: jest.fn().mockResolvedValue(undefined),
    extractPksValues: (d: any) => d?.Id ?? null,
  });

  const srcCols = [
    { id: 'c1', title: 'Title', column_name: 'title' },
    { id: 'c2', title: 'Qty', column_name: 'qty' },
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
    const [marked] = destBaseModel.bulkUpdate.mock.calls.at(-1);
    expect(marked).toEqual([{ Id: 12, RemoteDeleted: true }]);
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

  it('rejects realtime trigger at the API boundary (auto sync stays paywalled)', async () => {
    const jobsService = { add: jest.fn() };
    const service = new TableSyncsService({} as any, jobsService as any);
    baseUserGet.mockResolvedValue({ roles: 'owner' });
    await expect(
      service.createSync(
        ctx,
        'dest1',
        {
          sourceBaseId: 'src1',
          sourceTableId: 't1',
          syncTrigger: 'realtime',
        },
        req,
      ),
    ).rejects.toThrow(/manual/i);
    expect(jobsService.add).not.toHaveBeenCalled();
  });
});
