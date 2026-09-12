<script setup lang="ts">
// [CE-EE] F07: base snapshots management UI (replaces the CE stub)
import type { SnapshotType } from 'nocodb-sdk'

const { $api } = useNuxtApp()
const { t } = useI18n()
const { openedProject } = storeToRefs(useBases())

const snapshots = ref<SnapshotType[]>([])
const isLoading = ref(false)
const isCreating = ref(false)

const baseId = computed(() => openedProject.value?.id)

const loadSnapshots = async () => {
  if (!baseId.value) return
  isLoading.value = true
  try {
    const res = await $api.instance.get(
      `/api/v2/meta/bases/${baseId.value}/snapshots`,
    )
    snapshots.value = res.data ?? []
  } catch (e: any) {
    message.error(await extractSdkResponseErrorMsg(e))
  } finally {
    isLoading.value = false
  }
}

const createSnapshot = async () => {
  isCreating.value = true
  try {
    // [CE-EE] F07 R1: creation is async (DuplicateBase job, 10-40s) — poll
    // the new snapshot by id (not the whole list) so status converges on UI
    const res = await $api.instance.post(
      `/api/v2/meta/bases/${baseId.value}/snapshots`,
      {},
    )
    message.success(t('msg.success.baseSnapshotCreated'))
    const newId = res.data?.id
    if (newId) {
      for (let i = 0; i < 24; i++) {
        await new Promise((r) => setTimeout(r, 2500))
        const one = await $api.instance.get(
          `/api/v2/meta/bases/${baseId.value}/snapshots/${newId}`,
        )
        const list = snapshots.value
        const idx = list.findIndex((s) => s.id === newId)
        if (idx === -1) list.unshift(one.data)
        else list[idx] = one.data
        if (one.data?.status === 'completed' || one.data?.status === 'error') break
      }
    }
  } catch (e: any) {
    message.error(await extractSdkResponseErrorMsg(e))
  } finally {
    isCreating.value = false
  }
}

const restoreSnapshot = async (snapshot: SnapshotType) => {
  try {
    const res = await $api.instance.post(
      `/api/v2/meta/bases/${baseId.value}/snapshots/${snapshot.id}/restore`,
      {},
    )
    message.success(t('msg.success.baseSnapshotRestored'))
    const restoredBaseId = res.data?.base_id
    if (restoredBaseId) {
      // [CE-EE] F07 R1: mirror upstream getBaseUrl — /nc/{baseId}
      await navigateTo(`/nc/${restoredBaseId}`)
    }
  } catch (e: any) {
    message.error(await extractSdkResponseErrorMsg(e))
  }
}

const deleteSnapshot = async (snapshot: SnapshotType) => {
  Modal.confirm({
    title: t('msg.info.baseSnapshotDeleteTitle'),
    content: t('msg.info.baseSnapshotDeleteDescription', {
      title: snapshot.title,
    }),
    okText: t('general.delete'),
    okType: 'danger',
    cancelText: t('general.cancel'),
    async onOk() {
      try {
        await $api.instance.delete(
          `/api/v2/meta/bases/${baseId.value}/snapshots/${snapshot.id}`,
        )
        message.success(t('msg.success.baseSnapshotDeleted'))
        await loadSnapshots()
      } catch (e: any) {
        message.error(await extractSdkResponseErrorMsg(e))
      }
    },
  })
}

const statusColor = (status?: string) => {
  switch (status) {
    case 'completed':
      return 'text-nc-content-green-medium'
    case 'processing':
      return 'text-nc-content-orange-medium'
    default:
      return 'text-nc-content-red-medium'
  }
}

onMounted(loadSnapshots)
</script>

<template>
  <div class="nc-base-snapshots max-w-250">
    <div class="flex items-center justify-between mb-4">
      <div>
        <div class="text-lg font-weight-600">{{ $t('labels.manageSnapshots') }}</div>
        <div class="text-sm text-nc-content-gray-subtle">
          {{ $t('msg.info.baseSnapshotsSubtitle') }}
        </div>
      </div>
      <NcButton
        type="primary"
        size="small"
        :loading="isCreating"
        data-testid="base-snapshots-create"
        @click="createSnapshot"
      >
        <div class="flex items-center gap-1">
          <GeneralIcon icon="plus" />
          {{ $t('msg.info.baseSnapshotCreate') }}
        </div>
      </NcButton>
    </div>

    <div v-if="isLoading" class="py-8 text-center text-nc-content-gray-subtle">
      <GeneralLoader />
    </div>

    <div v-else-if="!snapshots.length" class="py-10 text-center text-nc-content-gray-subtle text-sm">
      {{ $t('msg.info.baseSnapshotsEmpty') }}
    </div>

    <div v-else class="flex flex-col gap-2">
      <div
        v-for="snapshot in snapshots"
        :key="snapshot.id"
        class="flex items-center gap-3 border-1 border-nc-border-gray-medium rounded-lg px-4 py-2"
        :data-testid="`base-snapshots-row-${snapshot.id}`"
      >
        <div class="w-70 truncate text-sm font-weight-600">{{ snapshot.title }}</div>
        <div class="w-40 text-xs text-nc-content-gray-muted">
          {{ new Date(snapshot.created_at).toLocaleString() }}
        </div>
        <div
          class="w-24 text-xs uppercase font-weight-600"
          :class="statusColor(snapshot.status)"
          :data-testid="`base-snapshots-status-${snapshot.id}`"
        >
          {{ snapshot.status }}
        </div>
        <div class="flex-1" />
        <div class="flex items-center gap-1">
          <NcButton
            type="text"
            size="small"
            :disabled="snapshot.status !== 'completed'"
            :data-testid="`base-snapshots-restore-${snapshot.id}`"
            @click="restoreSnapshot(snapshot)"
          >
            <div class="flex items-center gap-1 text-xs">
              <GeneralIcon icon="reload" />
              {{ $t('general.restore') }}
            </div>
          </NcButton>
          <NcButton
            type="text"
            size="small"
            :data-testid="`base-snapshots-delete-${snapshot.id}`"
            @click="deleteSnapshot(snapshot)"
          >
            <GeneralIcon icon="delete" class="text-nc-content-red-medium" />
          </NcButton>
        </div>
      </div>
    </div>

    <div class="mt-4 text-xs text-nc-content-gray-muted">
      {{ $t('msg.info.baseSnapshotsRestoreHint') }}
    </div>
  </div>
</template>
