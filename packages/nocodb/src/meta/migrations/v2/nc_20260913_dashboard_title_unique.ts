import type { Knex } from 'knex';
import { MetaTable } from '~/utils/globals';

// [CE-EE] F10: enforce unique dashboard titles per base at the DB level —
// the service pre-check is check-then-insert and races under concurrency.

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

  await knex.schema.alterTable(MetaTable.DASHBOARDS, (table) => {
    table.unique(['base_id', 'title'], 'nc_dashboards_base_title_unique');
  });
};

const down = async (knex: Knex) => {
  await knex.schema.alterTable(MetaTable.DASHBOARDS, (table) => {
    table.dropUnique(['base_id', 'title'], 'nc_dashboards_base_title_unique');
  });
};

export { up, down };
