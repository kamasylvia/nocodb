import type { Knex } from 'knex';
import { MetaTable } from '~/utils/globals';

// [CE-EE] F08: add `is_private` to nc_bases_v2 — a private base is only
// visible to explicit collaborators (nc_base_users_v2 rows with a real role),
// and is hidden from workspace-inherited members entirely.
// R1 fix: registered in the v0 source (fresh installs only run v0); the up
// path is guarded so installs that already got the column via the former v2
// registration don't fail on re-run.

const up = async (knex: Knex) => {
  const hasColumn = await knex.schema.hasColumn(MetaTable.PROJECT, 'is_private');
  if (!hasColumn) {
    await knex.schema.alterTable(MetaTable.PROJECT, (table) => {
      table.boolean('is_private').defaultTo(false);
    });
  }
};

const down = async (knex: Knex) => {
  const hasColumn = await knex.schema.hasColumn(MetaTable.PROJECT, 'is_private');
  if (hasColumn) {
    await knex.schema.alterTable(MetaTable.PROJECT, (table) => {
      table.dropColumn('is_private');
    });
  }
};

export { up, down };
