<script setup lang="ts">
// [CE-EE] F04: Manage Syncs panel (replaces the CE stub) — manages legacy
// SyncSource (Airtable sync) rows for this base via the internal ops API.
// The backend CRUD/engine is fully present in CE with creator+ ACL; the App
// Sync (SyncConfig) surface in store/sync.ts stays stubbed — it has no CE
// backend, so isSyncFeatureEnabled deliberately remains false.
import { JobStatus } from '#imports'

interface SyncRow {
  id: string
  title: string
  type: string
  details: any
  enabled?: boolean
}

const props = defineProps<{
  baseId?: string
}>()

const { $api } = useNuxtApp()
const { t } = useI18n()

const workspace = useWorkspace()
const { activeWorkspace } = storeToRefs(workspace)
const baseStore = useBase()
const { getJobsForBase, loadJobsForBase } = useJobs()

const syncs = ref<SyncRow[]>([])
const isLoading = ref(true)

const editingId = ref<string | null>(null)
const editTitle = ref('')
const editDetails = ref('')
const editError = ref('')
const isSaving = ref(false)

const syncingId = ref<string | null>(null)
const syncStatus = ref<Record<string, { text: string; failed?: boolean }>>({})
// [CE-EE] F04 R3(lane3/lane5): watchdog interval handles — cleared on
// unmount so a navigating-away user doesn't leave a ≤90s poller running
const watchdogTimers = ref<number[]>([])

onUnmounted(() => {
  watchdogTimers.value.forEach((t) => window.clearInterval(t))
  watchdogTimers.value = []
})

const baseId = computed(() => props.baseId)
const wsId = computed(() => activeWorkspace.value?.id ?? baseStore.base?.workspace_id ?? '')

const loadSyncs = async () => {
  if (!baseId.value) return
  isLoading.value = true
  try {
    const data: any = await $api.internal.getOperation(wsId.value, baseId.value, {
      operation: 'syncSourceList',
      sourceId: baseStore.base?.sources?.[0]?.id,
    })
    const rows: SyncRow[] = (data?.list ?? []).map((r: any) => ({
      id: r.id,
      title: r.title || r.type,
      type: r.type,
      details: r.details || {},
      enabled: r.enabled,
    }))
    // latest first when a timestamp is available
    syncs.value = rows
  } catch (e: any) {
    message.error(await extractSdkResponseErrorMsg(e))
  } finally {
    isLoading.value = false
  }
}

const startEdit = (row: SyncRow) => {
  editingId.value = row.id
  editTitle.value = row.title
  editDetails.value = JSON.stringify(row.details ?? {}, null, 2)
  editError.value = ''
}

const cancelEdit = () => {
  editingId.value = null
  editError.value = ''
}

const saveEdit = async (row: SyncRow) => {
  let details: any
  try {
    details = JSON.parse(editDetails.value || '{}')
  } catch {
    editError.value = t('labels.syncsInvalidJson')
    return
  }
  if (!editTitle.value.trim()) {
    editError.value = t('labels.syncsTitleRequired')
    return
  }
  isSaving.value = true
  try {
    // [CE-EE] F04 R1(lane5): only send the fields the endpoint consumes —
    // no id/enabled echo
    await $api.internal.postOperation(wsId.value, baseId.value, {
      operation: 'syncSourceUpdate',
      syncId: row.id,
    }, { title: editTitle.value.trim(), type: row.type, details })
    message.success(t('labels.syncsSaved'))
    editingId.value = null
    await loadSyncs()
  } catch (e: any) {
    message.error(await extractSdkResponseErrorMsg(e))
  } finally {
    isSaving.value = false
  }
}

const deleteSync = (row: SyncRow) => {
  Modal.confirm({
    title: t('labels.syncsDeleteTitle'),
    content: t('labels.syncsDeleteDescription', { title: row.title }),
    okText: t('general.delete'),
    okType: 'danger',
    cancelText: t('general.cancel'),
    async onOk() {
      try {
        await $api.internal.postOperation(wsId.value, baseId.value, {
          operation: 'syncSourceDelete',
          syncId: row.id,
        }, {})
        message.success(t('labels.syncsDeleted'))
        await loadSyncs()
      } catch (e: any) {
        message.error(await extractSdkResponseErrorMsg(e))
      }
    },
  })
}

const resync = async (row: SyncRow) => {
  if (syncingId.value) {
    // [CE-EE] F04 R3(lane3): silent return gave zero feedback — surface the
    // in-flight state instead
    message.info(t('labels.syncsSyncing'))
    return
  }
  // [CE-EE] F04 R4(lane3): set the lock optimistically BEFORE the trigger
  // call — the await window otherwise lets a double-click fire a second
  // request (backend job dedup catches it, but the UI shouldn't rely on it)
  syncingId.value = row.id
  syncStatus.value = { ...syncStatus.value, [row.id]: { text: t('labels.syncsSyncing') } }
  try {
    const jobData: any = await $api.internal.postOperation(wsId.value, baseId.value, {
      operation: 'atImportTrigger',
      syncId: row.id,
    }, {})

    // [CE-EE] F04 R2(lane1/lane4): track the resync via jobs-list polling —
    // the $poller websocket is unusable here (jobs/listen is owner-gated, so
    // a collaborator's subscribe 404s forever and deadlocks the panel, and
    // the 'close' fallback read a stale jobs store). Poll every 3s until the
    // job reaches a terminal state (or ~90s timeout).
    const targetJobId: string | null = jobData?.id ?? null
    let polls = 0
    const watchdog = window.setInterval(async () => {
      polls += 1
      try {
        await loadJobsForBase(baseId.value)
        const jobs = getJobsForBase(baseId.value) || []
        const job = targetJobId
          ? jobs.find((j: any) => j.id === targetJobId)
          : [...jobs]
              .filter(
                (j: any) =>
                  j.base_id === baseId.value &&
                  j.status !== JobStatus.COMPLETED &&
                  j.status !== JobStatus.FAILED,
              )
              .sort((a: any, b: any) => new Date(b.created_at).getTime() - new Date(a.created_at).getTime())[0]

        if (job?.status === JobStatus.COMPLETED) {
          window.clearInterval(watchdog)
          watchdogTimers.value = watchdogTimers.value.filter((t) => t !== watchdog)
          syncingId.value = null
          syncStatus.value = { ...syncStatus.value, [row.id]: { text: t('labels.syncsSyncDone') } }
        } else if (job?.status === JobStatus.FAILED) {
          window.clearInterval(watchdog)
          watchdogTimers.value = watchdogTimers.value.filter((t) => t !== watchdog)
          syncingId.value = null
          syncStatus.value = {
            ...syncStatus.value,
            [row.id]: { text: job.result?.error?.message || t('labels.syncsSyncFailed'), failed: true },
          }
        } else if (polls >= 30) {
          // ~90s without a terminal state — stop polling and surface it
          window.clearInterval(watchdog)
          watchdogTimers.value = watchdogTimers.value.filter((t) => t !== watchdog)
          syncingId.value = null
          syncStatus.value = { ...syncStatus.value, [row.id]: { text: t('labels.syncsSyncTimeout'), failed: true } }
        }
      } catch {
        /* transient poll error — retried on the next tick */
      }
    }, 3000)
    watchdogTimers.value.push(watchdog)
  } catch (e: any) {
    syncingId.value = null
    message.error(await extractSdkResponseErrorMsg(e))
  }
}

onMounted(loadSyncs)
</script>

<template>
  <div class="nc-base-syncs max-w-250">
    <div class="mb-4">
      <div class="text-lg font-weight-600">{{ $t('labels.manageSyncs') }}</div>
      <div class="text-sm text-nc-content-gray-subtle">
        {{ $t('labels.syncsSubtitle') }}
      </div>
    </div>

    <div v-if="isLoading" class="py-8 text-center text-nc-content-gray-subtle">
      <GeneralLoader />
    </div>

    <div v-else-if="!syncs.length" class="py-10 text-center text-nc-content-gray-subtle text-sm">
      {{ $t('labels.syncsEmpty') }}
    </div>

    <div v-else class="flex flex-col gap-3">
      <div
        v-for="row in syncs"
        :key="row.id"
        class="flex flex-col gap-2 border-1 border-nc-border-gray-medium rounded-lg px-4 py-3"
        :data-testid="`base-syncs-row-${row.id}`"
      >
        <div class="flex items-center gap-3">
          <GeneralIcon icon="ncZap" class="text-nc-content-brand" />
          <div class="flex-1 font-weight-600 text-sm">
            <template v-if="editingId === row.id">
              <a-input v-model:value="editTitle" data-testid="base-syncs-title-input" />
            </template>
            <template v-else>{{ row.title }}</template>
          </div>
          <div class="text-xs text-nc-content-gray-muted uppercase">{{ row.type }}</div>
          <div class="flex items-center gap-1">
            <template v-if="editingId === row.id">
              <NcButton type="primary" size="small" :loading="isSaving" :data-testid="`base-syncs-save-${row.id}`" @click="saveEdit(row)">
                {{ $t('general.save') }}
              </NcButton>
              <NcButton type="text" size="small" @click="cancelEdit">{{ $t('general.cancel') }}</NcButton>
            </template>
            <template v-else>
              <NcButton
                type="text"
                size="small"
                :loading="syncingId === row.id"
                :data-testid="`base-syncs-resync-${row.id}`"
                @click="resync(row)"
              >
                {{ $t('labels.syncsResync') }}
              </NcButton>
              <NcButton type="text" size="small" :data-testid="`base-syncs-edit-${row.id}`" @click="startEdit(row)">
                <GeneralIcon icon="edit" />
              </NcButton>
              <NcButton type="text" size="small" :data-testid="`base-syncs-delete-${row.id}`" @click="deleteSync(row)">
                <GeneralIcon icon="delete" class="text-nc-content-red-medium" />
              </NcButton>
            </template>
          </div>
        </div>

        <div v-if="editingId === row.id" class="flex flex-col gap-1">
          <div class="text-xs text-nc-content-gray-muted">{{ $t('labels.syncsDetailsJson') }}</div>
          <a-textarea v-model:value="editDetails" :rows="8" data-testid="base-syncs-details-input" />
          <div v-if="editError" class="text-xs text-nc-content-red-medium">{{ editError }}</div>
        </div>
        <div v-else-if="row.details && Object.keys(row.details).length" class="text-xs text-nc-content-gray-subtle truncate">
          {{ Object.keys(row.details).join(' · ') }}
        </div>

        <div v-if="syncStatus[row.id]" class="text-xs" :class="syncStatus[row.id].failed ? 'text-nc-content-red-medium' : 'text-nc-content-gray-subtle'">
          {{ syncStatus[row.id].text }}
        </div>
      </div>
    </div>

    <div v-if="!isLoading && syncs.length" class="mt-3 text-xs text-nc-content-gray-muted">
      {{ $t('labels.syncsCreateHint') }}
    </div>
  </div>
</template>
