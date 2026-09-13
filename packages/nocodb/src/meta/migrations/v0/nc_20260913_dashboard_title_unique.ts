import type { Knex } from 'knex';
import { MetaTable } from '~/utils/globals';

// [CE-EE] F10: enforce unique dashboard titles per base at the DB level —
// the service pre-check is check-then-insert and races under concurrency.
// R1 (F08 review) fix: registered in the v0 source (fresh installs only run
// v0); guarded so installs that already got the index via the former v2
// registration don't fail on re-run.

// R2 (F08 review) fix: index re-run guard is dialect-agnostic now — a
// non-pg install that executed the former v2 registration would otherwise
// abort the whole v0 batch on duplicate index creation.

const rowsFromRaw = (res: any): any[] => {
  if (!res) return [];
  if (Array.isArray(res)) return Array.isArray(res[0]) ? res[0] : res;
  return res.rows || res.recordset || [];
};

const indexExists = async (knex: Knex, indexName: string): Promise<boolean> => {
  const clientType = ((knex as any).client?.config?.client || '') as string;
  if (clientType.includes('pg') || clientType.includes('postgres')) {
    const res = await knex.raw(`SELECT 1 FROM pg_indexes WHERE indexname = ?`, [
      indexName,
    ]);
    return rowsFromRaw(res).length > 0;
  }
  if (clientType.includes('mysql')) {
    const res = await knex.raw(
      `SELECT 1 FROM information_schema.statistics WHERE index_name = ? AND table_schema = DATABASE() LIMIT 1`,
      [indexName],
    );
    return rowsFromRaw(res).length > 0;
  }
  if (clientType.includes('sqlite')) {
    const res = await knex.raw(
      `SELECT 1 FROM sqlite_master WHERE type = 'index' AND name = ?`,
      [indexName],
    );
    return rowsFromRaw(res).length > 0;
  }
  if (clientType.includes('mssql')) {
    const res = await knex.raw(`SELECT 1 FROM sys.indexes WHERE name = ?`, [
      indexName,
    ]);
    return rowsFromRaw(res).length > 0;
  }
  // unknown dialect: keep the pre-guard behavior and attempt creation
  return false;
};

const up = async (knex: Knex) => {
  // deduplicate first so the unique index can be created: keep the earliest
  // row per (base_id, title) — no-op when the index is already in place
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
  if (await indexExists(knex, 'nc_dashboards_base_title_unique')) {
    return;
  }

  await knex.schema.alterTable(MetaTable.DASHBOARDS, (table) => {
    table.unique(['base_id', 'title'], 'nc_dashboards_base_title_unique');
  });
};

const down = async (knex: Knex) => {
  if (!(await indexExists(knex, 'nc_dashboards_base_title_unique'))) {
    return;
  }

  await knex.schema.alterTable(MetaTable.DASHBOARDS, (table) => {
    table.dropUnique(['base_id', 'title'], 'nc_dashboards_base_title_unique');
  });
};

export { up, down };
