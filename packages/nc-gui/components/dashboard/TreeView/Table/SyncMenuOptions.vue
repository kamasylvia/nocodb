<script lang="ts" setup>
// [CE-EE] F09: sync management menu for synced tables in the tree node
// options dropdown (Sync now / Pause / Resume / Delete). P1 scope — Edit sync
// and Convert to regular table land with P2 (field propagation / detach).
import { TableSyncStatus } from 'nocodb-sdk'
import type { TableType } from 'nocodb-sdk'

const props = defineProps<{
  baseId: string
  table: TableType
  open?: boolean
}>()

const emit = defineEmits<{
  (e: 'close'): void
}>()

const { t } = useI18n()

const { sync, isUpdating, isLoading, load, syncNow, freeze, resume, remove, detach } =
  useTableSync(props.baseId, props.table.id!)

const { baseUrl, loadTables } = useBase()
const { removeMeta } = useMetas()
const { removeFromRecentViews } = useViewsStore()
// [CE-EE] F09 R8(lane5): state refs must come via storeToRefs — a bare
// destructure of a pinia setup store unwraps them once at setup time, so
// activeTable.value was always undefined and both delete-redirect legs
// were dead code (upstream DlgTableDelete uses storeToRefs too)
const tablesStore = useTablesStore()
const { baseTables, activeTable } = storeToRefs(tablesStore)
const { openTable } = tablesStore

const isDeleteConfirmOpen = ref(false)

// [CE-EE] F09 R5(lane1/2/5): the dropdown overlay keeps this component
// mounted after the first open — reload the sync record every time the
// menu opens, or status freezes at the mount-time value (Syncing…) and
// Pause/Resume disappear until a page reload
watch(
  () => props.open,
  (isOpen) => {
    if (isOpen) load()
  },
)

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

// [CE-EE] F09 P2: convert the mirror into a regular editable table —
// the sync is removed, the table and rows stay in the tree
const onDetach = async () => {
  await detach()
  emit('close')
  removeMeta(props.baseId, props.table.id!, true)
  await loadTables()
}

const onDelete = async () => {
  isDeleteConfirmOpen.value = false
  // [CE-EE] F09 R6(lane1/2/3/4): capture the active table id before remove()
  // — loadTables() drops the deleted table from the store, so comparing
  // activeTable afterwards always misses and the redirect branch is dead
  const oldActiveTableId = activeTable.value?.id
  await remove()
  emit('close')
  // [CE-EE] F09 R5(lane2/3b): useBases() has no loadTables (the earlier
  // call threw and the tree never refreshed) — mirror DlgTableDelete's
  // post-delete flow instead: drop cached meta/recents, reload the tree,
  // and leave the deleted table's view
  removeFromRecentViews({ baseId: props.baseId, tableId: props.table.id! })
  removeMeta(props.baseId, props.table.id!, true)
  await loadTables()
  if (oldActiveTableId === props.table.id) {
    const remaining = (baseTables.value.get(props.baseId) ?? []).filter(
      (t) => t.id !== props.table.id,
    )
    if (remaining.length) {
      await openTable(remaining[0])
    } else {
      await navigateTo(baseUrl({ id: props.baseId, type: 'database' }))
    }
  }
}
</script>

<template>
  <!-- [CE-EE] F09 R5(lane5): keep the menu visible while the sync record is
       still loading, or the first open renders an empty dropdown -->
  <div v-if="!sync && isLoading" class="flex items-center gap-2 px-3 py-1.5 text-xs text-nc-content-gray-subtle2">
    <GeneralIcon icon="refresh" class="flex-none animate-spin" />
    <span>{{ $t('general.loading') }}</span>
  </div>
  <div v-else-if="sync" class="flex flex-col">
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

    <!-- [CE-EE] F09 P2: convert to regular editable table (sync removed);
         hidden while a run is active (lane5 M3 — backend 400s otherwise) -->
    <NcMenuItem
      v-if="sync.status !== TableSyncStatus.Syncing"
      data-testid="table-sync-menu-convert"
      :disabled="isUpdating"
      @click="onDetach"
    >
      <div class="flex gap-2 items-center w-full">
        <GeneralIcon icon="table" class="opacity-80" />
        <div class="flex-1">{{ $t('labels.convertToRegularTable') }}</div>
      </div>
    </NcMenuItem>

    <NcMenuItem
      v-if="sync.status !== TableSyncStatus.Syncing"
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
