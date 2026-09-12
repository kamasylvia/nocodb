import { Injectable } from '@nestjs/common';
import { ProjectStatus } from 'nocodb-sdk';
import type { SnapshotType } from 'nocodb-sdk';
import type { NcContext, NcRequest } from '~/interface/config';
import Base from '~/models/Base';
import BaseSnapshot from '~/models/BaseSnapshot';
import { NcError } from '~/helpers/catchError';
import { DuplicateService } from '~/modules/jobs/jobs/export-import/duplicate.service';
import { MetaTable, RootScopes } from '~/utils/globals';
import Noco from '~/Noco';

// [CE-EE] F07: base snapshots. A snapshot is a full asynchronous copy of the
// base produced by the existing DuplicateBase job; the copy is a real base
// registered in nc_snapshots (titled "Snapshot <ts> of <base>"). Restoring
// duplicates the snapshot base into the workspace as a new base — the working
// base is never modified in place.

const SNAPSHOT_PROCESSING_TIMEOUT_MS = 15 * 60 * 1000; // 15 min safety net

@Injectable()
export class BaseSnapshotsService {
  constructor(private readonly duplicateService: DuplicateService) {}

  async createSnapshot(
    context: NcContext,
    baseId: string,
    req: NcRequest,
    body: { title?: string },
  ) {
    const base = await Base.get(context, baseId);
    if (!base) NcError.notFound('Base not found');

    // [CE-EE] F07 R1: non-string titles crashed .trim() -> 500
    if (body?.title !== undefined && typeof body.title !== 'string') {
      NcError.badRequest('Snapshot title must be a string');
    }
    if (body?.title && body.title.length > 512) {
      NcError.badRequest('Snapshot title exceeds 512 characters limit');
    }

    // [CE-EE] F07 R3: derive before the mutex check — a job-failed/restarted
    // row stuck at 'processing' would otherwise block creates until an
    // unrelated GET happened to self-heal it
    const existing = await this.listSnapshots(context, baseId);
    // [CE-EE] F07 R1: mutex is check-then-insert and racy by design — worst
    // case two copies get created (no corruption); the DB has no uniqueness
    // to lean on here, documented residual risk.
    if (existing.some((s) => s.status === 'processing')) {
      NcError.badRequest(
        'Another snapshot is still being created. Try again once it completes',
      );
    }

    const title =
      body?.title?.trim() ||
      `Snapshot ${new Date().toISOString().replace(/[:.]/g, '-').slice(0, 19)}`;

    // full copy (schema + data + hooks + views); duplication runs as the
    // regular DuplicateBase job and lands as a new base in the workspace
    const { base_id: snapshotBaseId } = await this.duplicateService.duplicateBase(
      {
        context,
        req,
        baseId,
        body: {
          base: {
            // [CE-EE] F07 R7: cap at the 150-char title column limit — long
            // base titles would otherwise fail the whole snapshot creation
            title: `Snapshot ${snapshotBaseTitleSuffix()} of ${base.title}`.slice(0, 150),
            description: `Snapshot of base ${base.id} (${base.title})`,
          },
          options: {},
        },
      },
    );

    return BaseSnapshot.insert(context, {
      base_id: baseId,
      snapshot_base_id: snapshotBaseId,
      title,
      status: 'processing',
      created_by: req.user.id,
    });
  }

  async listSnapshots(context: NcContext, baseId: string) {
    const snapshots = await BaseSnapshot.list(context, baseId);

    // derive durable status from the snapshot base lifecycle: the duplicate
    // job flips the copy base from status 'job' to a live base when done
    for (const snapshot of snapshots) {
      const derived = await this.deriveStatus(context, snapshot);
      if (derived && derived !== snapshot.status) {
        await BaseSnapshot.update(context, snapshot.id, { status: derived });
        snapshot.status = derived;
      }
    }

    return snapshots;
  }

  async getSnapshot(
    context: NcContext,
    baseId: string,
    snapshotId: string,
  ) {
    const snapshot = await this.getSnapshotWithBaseCheck(
      context,
      baseId,
      snapshotId,
    );
    const derived = await this.deriveStatus(context, snapshot);
    if (derived && derived !== snapshot.status) {
      await BaseSnapshot.update(context, snapshot.id, { status: derived });
      snapshot.status = derived;
    }
    return snapshot;
  }

  /** [CE-EE] F07 R3: the copy base can disappear at any time (trash purge,
   * hard delete) even after a snapshot completed — verify it before relying
   * on it, so restore never 404-leaks internal ids. */
  private async ensureCopyExists(
    context: NcContext,
    snapshot: BaseSnapshot,
  ): Promise<void> {
    const copyRow = await this.getCopyBaseRow(
      context,
      snapshot.snapshot_base_id,
    );
    if (!copyRow) {
      await BaseSnapshot.update(context, snapshot.id, { status: 'error' });
      snapshot.status = 'error';
      NcError.badRequest(
        'Snapshot copy base no longer exists — this snapshot cannot be restored',
      );
    }
  }

  async restoreSnapshot(
    context: NcContext,
    baseId: string,
    snapshotId: string,
    req: NcRequest,
  ) {
    const snapshot = await this.getSnapshotWithBaseCheck(
      context,
      baseId,
      snapshotId,
    );

    // deriveStatus returns null when the persisted status is already
    // terminal (completed/error) — fall back to the stored status
    const derived =
      (await this.deriveStatus(context, snapshot)) ?? snapshot.status;
    if (derived !== 'completed') {
      NcError.badRequest(
        `Snapshot is not ready for restore (status: ${derived})`,
      );
    }

    await this.ensureCopyExists(context, snapshot);

    const originalBase = await Base.get(context, baseId);

    // restore = duplicate the snapshot copy back into the workspace as a new
    // base; the original working base is left untouched
    const { base_id: restoredBaseId } =
      await this.duplicateService.duplicateBase({
        context: {
          workspace_id: snapshot.fk_workspace_id,
          base_id: snapshot.snapshot_base_id,
        } as NcContext,
        req,
        baseId: snapshot.snapshot_base_id,
        body: {
          base: {
            title: `${originalBase?.title ?? baseId} (restored)`.slice(0, 150),
          },
          options: {},
        },
      });

    return { base_id: restoredBaseId };
  }

  async deleteSnapshot(
    context: NcContext,
    baseId: string,
    snapshotId: string,
  ) {
    const snapshot = await this.getSnapshotWithBaseCheck(
      context,
      baseId,
      snapshotId,
    );

    // [CE-EE] F07 R1: the copy base may be gone (failed job, manual trash
    // purge) — still allow deleting the snapshot row instead of 500-ing.
    // Soft-delete is the platform's standard deletion path (Base.delete
    // trips the "cannot delete first source" guard); it also runs our
    // deleteByBaseId hook, cleaning snapshot-base variables.
    // [CE-EE] F07 R3: cache-free probe (see getCopyBaseRow).
    const snapshotBaseRow = await this.getCopyBaseRow(
      context,
      snapshot.snapshot_base_id,
    );
    if (snapshotBaseRow) {
      await Base.softDelete(
        {
          workspace_id: snapshot.fk_workspace_id,
          base_id: snapshot.snapshot_base_id,
        } as NcContext,
        snapshot.snapshot_base_id,
      );
    }

    await BaseSnapshot.delete(context, snapshotId);
    return true;
  }

  private async deriveStatus(
    context: NcContext,
    snapshot: BaseSnapshot,
  ): Promise<string | null> {
    // [CE-EE] F07 R4: unified re-derivation — every status (including
    // terminal ones) is re-probed cache-free, so transient mislabels
    // (restart races) self-heal and genuinely purged copies degrade to
    // 'error' instead of offering restores that would 404.
    const copyRow = await this.getCopyBaseRow(
      context,
      snapshot.snapshot_base_id,
    );

    if (!copyRow) return snapshot.status === 'error' ? null : 'error';
    // [CE-EE] F07 R5 revert: empty copy status reliably means the duplicate
    // job finished (baseCreate sets 'job'; the processor clears it on
    // success) — the "pre-claim window" lane5 simulated does not exist
    if (copyRow.status === ProjectStatus.JOB) {
      // [CE-EE] F07 R2: probe first, timeout second — a slow large base must
      // not be mislabeled 'error' when the job is legitimately still running;
      // this only fires when the copy base is stuck in status 'job' far past
      // any reasonable duplication window (job crashed without its catch)
      if (
        snapshot.created_at &&
        Date.now() - new Date(snapshot.created_at).getTime() >
          SNAPSHOT_PROCESSING_TIMEOUT_MS
      ) {
        return 'error';
      }
      return 'processing';
    }
    return 'completed';
  }

  /** [CE-EE] F07 R3 (F1 fix): cache-free copy-base row probe.
   *  Base.get serves from an in-process cache that masks out-of-band DB
   *  changes (e.g. a purged copy), so probes must hit meta directly.
   *  Returns the raw nc_bases_v2 row (with deleted/status) or null. */
  private async getCopyBaseRow(
    context: NcContext,
    snapshotBaseId: string,
  ): Promise<Record<string, any> | null> {
    // [CE-EE] F07 R4 fix: base_id must be RootScopes.WORKSPACE — metaGet2's
    // contextCondition maps a plain base_id to `WHERE id = base_id` on the
    // PROJECT table, which contradicts the snapshotBaseId lookup (always null)
    const row = await Noco.ncMeta.metaGet2(
      context.workspace_id,
      RootScopes.WORKSPACE,
      MetaTable.PROJECT,
      snapshotBaseId,
    );
    if (!row || row.deleted === true) return null;
    return row;
  }

  private async getSnapshotWithBaseCheck(
    context: NcContext,
    baseId: string,
    snapshotId: string,
  ): Promise<BaseSnapshot> {
    const snapshot = await BaseSnapshot.get(context, snapshotId);
    if (!snapshot || snapshot.base_id !== baseId) {
      NcError.notFound('Snapshot not found');
    }
    return snapshot;
  }
}

function snapshotBaseTitleSuffix(): string {
  return new Date().toISOString().replace(/[:.]/g, '-').slice(0, 19);
}
