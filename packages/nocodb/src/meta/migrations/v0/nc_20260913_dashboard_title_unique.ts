import type { Knex } from 'knex';
import { MetaTable } from '~/utils/globals';

// [CE-EE] F10: enforce unique dashboard titles per base at the DB level —
// the service pre-check is check-then-insert and races under concurrency.
// R1 (F08 review) fix: registered in the v0 source (fresh installs only run
// v0); guarded so installs that already got the index via the former v2
// registration don't fail on re-run.

const up = async (knex: Knex) => {
  // deduplicate first so the unique index can be created: keep the earliest
  // row per (base_id, title)
  await knex.raw(
    `DELETE FROM ?? WHERE id IN (
      SELECT id FROM (
        SELECT id, ROW_NUMBER() OVER (
          PARTITION BY base_id, title ORDER BY created_at ASC
        ) AS rn
        FROM ??
      ) d
      WHERE d.rn > 1
    )`,
    [MetaTable.DASHBOARDS, MetaTable.DASHBOARDS],
  );

  // re-run guard: installs that executed the former v2 registration already
  // carry the index — recreating it would abort the whole v0 batch
  const clientType = ((knex as any).client?.config?.client || '') as string;
  if (clientType.includes('pg') || clientType.includes('postgres')) {
    const res = await knex.raw(`SELECT 1 FROM pg_indexes WHERE indexname = ?`, [
      'nc_dashboards_base_title_unique',
    ]);
    if ((res?.rows || []).length > 0) {
      return;
    }
  }

  await knex.schema.alterTable(MetaTable.DASHBOARDS, (table) => {
    table.unique(['base_id', 'title'], 'nc_dashboards_base_title_unique');
  });
};

const down = async (knex: Knex) => {
  const clientType = ((knex as any).client?.config?.client || '') as string;
  if (clientType.includes('pg') || clientType.includes('postgres')) {
    const res = await knex.raw(`SELECT 1 FROM pg_indexes WHERE indexname = ?`, [
      'nc_dashboards_base_title_unique',
    ]);
    if ((res?.rows || []).length === 0) {
      return;
    }
  }

  await knex.schema.alterTable(MetaTable.DASHBOARDS, (table) => {
    table.dropUnique(['base_id', 'title'], 'nc_dashboards_base_title_unique');
  });
};

export { up, down };
