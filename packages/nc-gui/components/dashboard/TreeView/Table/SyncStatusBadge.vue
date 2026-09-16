<script lang="ts" setup>
// [CE-EE] F09: tree-node tooltip badge for synced tables — shows the owning
// sync's live status on top of the static "Synced table" label.
import { TableSyncStatus } from 'nocodb-sdk'
import type { TableType } from 'nocodb-sdk'

const props = defineProps<{
  table: TableType
}>()

const { base_id: baseId } = props.table

const { t } = useI18n()

const { sync } = useTableSync(baseId!, props.table.id!)

const statusLabel = computed(() => {
  if (!sync.value) return ''
  if (sync.value.status === TableSyncStatus.Syncing) return t('labels.syncing')
  if (sync.value.status === TableSyncStatus.Paused) return t('labels.paused')
  if (sync.value.status === TableSyncStatus.Error) return t('labels.errored')
  if (sync.value.last_synced_at) {
    return t('labels.lastSynced', {
      time: new Date(sync.value.last_synced_at).toLocaleString(),
    })
  }
  return t('labels.syncNotYetRun')
})
</script>

<template>
  <div class="flex flex-col gap-0.5 text-left">
    <div class="font-semibold">{{ $t('labels.syncedTable') }}</div>
    <div v-if="statusLabel" class="font-normal text-nc-content-gray-subtle2" data-testid="table-sync-status">
      {{ statusLabel }}
    </div>
  </div>
</template>
