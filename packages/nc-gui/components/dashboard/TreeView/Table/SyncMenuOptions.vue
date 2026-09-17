<script lang="ts" setup>
// [CE-EE] F09: sync management menu for synced tables in the tree node
// options dropdown (Sync now / Pause / Resume / Delete). P1 scope — Edit sync
// and Convert to regular table land with P2 (field propagation / detach).
import { TableSyncStatus } from 'nocodb-sdk'
import type { TableType } from 'nocodb-sdk'

const props = defineProps<{
  baseId: string
  table: TableType
}>()

const emit = defineEmits<{
  (e: 'close'): void
}>()

const { t } = useI18n()

const { sync, isUpdating, load, syncNow, freeze, resume, remove } = useTableSync(
  props.baseId,
  props.table.id!,
)

const isDeleteConfirmOpen = ref(false)

const statusLabel = computed(() => {
  if (!sync.value) return ''
  if (sync.value.status === TableSyncStatus.Syncing) return t('labels.syncing')
  if (sync.value.status === TableSyncStatus.Paused) return t('labels.paused')
  if (sync.value.status === TableSyncStatus.Error) return t('labels.errored')
  return t('labels.syncedTable')
})

const onSyncNow = async () => {
  // optimistic lock: resync flips the status to syncing server-side
  await syncNow()
  emit('close')
}

const onDelete = async () => {
  isDeleteConfirmOpen.value = false
  await remove()
  await load()
  useBases().loadTables()
  emit('close')
}
</script>

<template>
  <div v-if="sync" class="flex flex-col">
    <div class="flex items-center gap-2 px-3 py-1.5 text-xs text-nc-content-gray-subtle2">
      <GeneralIcon icon="refresh" class="flex-none" />
      <span data-testid="table-sync-menu-status">{{ statusLabel }}</span>
    </div>

    <NcMenuItem
      v-if="sync.status !== TableSyncStatus.Syncing"
      data-testid="table-sync-menu-sync-now"
      :disabled="isUpdating"
      @click="onSyncNow"
    >
      <div class="flex gap-2 items-center w-full">
        <GeneralIcon icon="refresh" class="opacity-80" />
        <div class="flex-1">{{ $t('labels.syncNow') }}</div>
      </div>
    </NcMenuItem>

    <NcMenuItem
      v-if="sync.status === TableSyncStatus.Active || sync.status === TableSyncStatus.Error"
      data-testid="table-sync-menu-freeze"
      :disabled="isUpdating"
      @click="
        () => {
          freeze()
          emit('close')
        }
      "
    >
      <div class="flex gap-2 items-center w-full">
        <GeneralIcon icon="pause" class="opacity-80" />
        <div class="flex-1">{{ $t('labels.freezeSync') }}</div>
      </div>
    </NcMenuItem>

    <NcMenuItem
      v-else-if="sync.status === TableSyncStatus.Paused"
      data-testid="table-sync-menu-resume"
      :disabled="isUpdating"
      @click="
        () => {
          resume()
          emit('close')
        }
      "
    >
      <div class="flex gap-2 items-center w-full">
        <GeneralIcon icon="play" class="opacity-80" />
        <div class="flex-1">{{ $t('labels.resumeSync') }}</div>
      </div>
    </NcMenuItem>

    <NcDivider />

    <NcMenuItem
      data-testid="table-sync-menu-delete"
      class="!text-nc-content-red-medium"
      :disabled="isUpdating"
      @click="isDeleteConfirmOpen = true"
    >
      <div class="flex gap-2 items-center w-full">
        <GeneralIcon icon="delete" class="opacity-80" />
        <div class="flex-1">{{ $t('labels.deleteSync') }}</div>
      </div>
    </NcMenuItem>

    <NcModal
      v-model:visible="isDeleteConfirmOpen"
      :title="$t('labels.deleteSync')"
      size="small"
      class="nc-table-sync-delete-modal"
    >
      <div class="text-sm">
        {{ sync.title }} — "{{ table.title }}"
      </div>
      <!-- [CE-EE] F09 R1(lane2/3/4): buttons moved from #footer into the body —
           nc/Modal hardcodes :footer="null" without a footer slot outlet -->
      <div class="flex justify-end gap-2 mt-4">
        <NcButton type="secondary" data-testid="table-sync-delete-cancel" @click="isDeleteConfirmOpen = false">
          {{ $t('general.cancel') }}
        </NcButton>
        <NcButton
          type="primary"
          class="!bg-nc-content-red-medium !text-white"
          data-testid="table-sync-delete-confirm"
          :loading="isUpdating"
          @click="onDelete"
        >
          {{ $t('labels.deleteSync') }}
        </NcButton>
      </div>
    </NcModal>
  </div>
</template>
