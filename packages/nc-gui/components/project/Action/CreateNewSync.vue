<script setup lang="ts">
// [CE-EE] F09: "New sync" creation wizard (browse mode, manual trigger — P1).
// Replaces the upstream EE stub: pick a source base/table in another base the
// user can read, pick a grid view with allow_sync enabled, select fields,
// choose the on-delete policy, then create. The mirror table is created
// synchronously (synced:true) and the first full copy runs as a job.
import { TableSyncOnDeleteAction } from 'nocodb-sdk'
import type { TableType } from 'nocodb-sdk'

const props = defineProps<{
  baseId?: string
}>()

const { $api } = useNuxtApp()
const { t } = useI18n()

const { openedProject } = storeToRefs(useBases())
// [CE-EE] F09 R7(lane5): alias the store loader — the wizard already has a
// local loadTables(baseId) for source tables, and a bare destructure would
// shadow it into a duplicate-identifier compile error
const { loadTables: refreshBaseTables } = useBase()

const open = ref(false)
const step = ref<0 | 1 | 2>(0)
const isLoading = ref(false)
const isCreating = ref(false)

const bases = ref<{ id: string; title: string }[]>([])
const tables = ref<TableType[]>([])
const schema = ref<{
  sourceBase: { id: string; title: string }
  sourceTable: { id: string; title: string }
  view: { id: string; title: string; allow_sync: boolean } | null
  views: { id: string; title: string; allow_sync: boolean }[]
  columns: { id: string; title: string; uidt: string }[]
} | null>(null)

const selectedBaseId = ref<string>()
const selectedTableId = ref<string>()

// [CE-EE] F09 P2: paste mode state (shared view url + optional password)
const sourceMode = ref<'browse' | 'paste'>('browse')
const sharedViewUrl = ref<string>()
const sharedViewPassword = ref<string>()

// [CE-EE] F09 R5(lane1/4/5): NcSelect 只认 show-search + filter-option，
// 按选项 label（base/table 标题）过滤
const filterSelectOption = (input: string, option: any) => {
  const query = input.toLowerCase()
  return (
    option.label?.toLowerCase().includes(query) ||
    String(option.value ?? '')
      .toLowerCase()
      .includes(query)
  )
}
const selectedViewId = ref<string>()
const fieldMode = ref<'all' | 'specific'>('all')
const selectedFields = ref<string[]>([])
const deleteAction = ref<TableSyncOnDeleteAction>(TableSyncOnDeleteAction.Delete)
const syncTitle = ref('')

const destBaseId = computed(() => props.baseId || openedProject.value?.id)

const allowSyncViews = computed(
  () => schema.value?.views.filter((v) => v.allow_sync) ?? [],
)

const loadBases = async () => {
  isLoading.value = true
  try {
    const res = await $api.instance.get('/api/v2/meta/bases/')
    const list = res.data?.list ?? res.data ?? []
    bases.value = list.filter(
      (b: any) => b.id !== destBaseId.value && b.deleted !== true,
    )
  } catch (e: any) {
    message.error(await extractSdkResponseErrorMsg(e))
  } finally {
    isLoading.value = false
  }
}

const loadTables = async (baseId: string) => {
  isLoading.value = true
  schema.value = null
  selectedTableId.value = undefined
  try {
    const res = await $api.instance.get(`/api/v2/meta/bases/${baseId}/tables`)
    tables.value = (res.data?.list ?? []).filter((t: any) => t.type === 'table')
  } catch (e: any) {
    tables.value = []
    message.error(await extractSdkResponseErrorMsg(e))
  } finally {
    isLoading.value = false
  }
}

const loadSchema = async () => {
  if (!selectedTableId.value) return
  isLoading.value = true
  try {
    const res = await $api.instance.post(
      `/api/v2/meta/bases/${destBaseId.value}/table-syncs/source-schema`,
      // [CE-EE] F09 P2: paste mode previews by shared view url (+ password),
      // browse mode by base/table ids
      sourceMode.value === 'paste'
        ? {
            sharedViewUrl: sharedViewUrl.value,
            sharedViewPassword: sharedViewPassword.value,
          }
        : {
            sourceBaseId: selectedBaseId.value,
            sourceTableId: selectedTableId.value,
          },
    )
    schema.value = res.data
    if (schema.value?.view) {
      selectedViewId.value = schema.value.view.id
    }
    selectedFields.value = []
    fieldMode.value = 'all'
    syncTitle.value = schema.value?.sourceTable?.title ?? ''
  } catch (e: any) {
    message.error(await extractSdkResponseErrorMsg(e))
  } finally {
    isLoading.value = false
  }
}

const createSync = async () => {
  if (!destBaseId.value) return
  isCreating.value = true
  try {
    await $api.instance.post(
      `/api/v2/meta/bases/${destBaseId.value}/table-syncs`,
      {
        title: syncTitle.value,
        // [CE-EE] F09 P2: paste mode sends the share credential; browse mode
        // keeps the direct source ids
        ...(sourceMode.value === 'paste'
          ? {
              sourceInputMode: 'paste',
              sharedViewUrl: sharedViewUrl.value,
              sharedViewPassword: sharedViewPassword.value,
            }
          : {
              sourceBaseId: selectedBaseId.value,
              sourceTableId: selectedTableId.value,
              sourceViewId: selectedViewId.value,
            }),
        selectedFields: fieldMode.value === 'all' ? null : selectedFields.value,
        onDeleteAction: deleteAction.value,
        syncTrigger: 'manual',
      },
    )
    message.success(t('labels.createSyncTable'))
    open.value = false
    // the mirror table exists immediately (created before the copy job runs)
    // [CE-EE] F09 R6(lane1/3/4): loadTables lives on the useBase store —
    // the earlier useBases().loadTables() threw inside this try block and
    // the tree never refreshed after creating a sync
    await refreshBaseTables()
  } catch (e: any) {
    message.error(await extractSdkResponseErrorMsg(e))
  } finally {
    isCreating.value = false
  }
}

// [CE-EE] F09 P2: paste mode — resolve the shared view, then reuse the
// browse flow with the resolved ids
const resolvePasteLink = async () => {
  isLoading.value = true
  try {
    const res = await $api.instance.post(
      `/api/v2/meta/bases/${destBaseId.value}/table-syncs/resolve-link`,
      {
        sharedViewUrl: sharedViewUrl.value,
        sharedViewPassword: sharedViewPassword.value,
      },
    )
    selectedBaseId.value = res.data.sourceBaseId
    selectedTableId.value = res.data.sourceTableId
    selectedViewId.value = res.data.sourceViewId
    await loadSchema()
    step.value = 1
  } catch (e: any) {
    message.error(await extractSdkResponseErrorMsg(e))
  } finally {
    isLoading.value = false
  }
}

const nextFromStep0 = async () => {
  if (sourceMode.value === 'paste') {
    await resolvePasteLink()
  } else {
    step.value = 1
  }
}

const openWizard = () => {
  step.value = 0
  bases.value = []
  tables.value = []
  schema.value = null
  selectedBaseId.value = undefined
  selectedTableId.value = undefined
  selectedViewId.value = undefined
  sharedViewUrl.value = undefined
  sharedViewPassword.value = undefined
  open.value = true
  loadBases()
}

watch(selectedBaseId, (id) => {
  if (id) loadTables(id)
})

watch(selectedTableId, (id) => {
  if (id && selectedBaseId.value) loadSchema()
})
</script>

<template>
  <div>
    <ProjectActionItem
      v-e="['c:sync:create']"
      data-testid="proj-view-btn__create-new-sync"
      :label="$t('labels.tableSync')"
      :subtext="$t('labels.tableSyncDesc')"
      @click="openWizard()"
    >
      <template #icon>
        <GeneralIcon icon="refresh" class="!h-8 !w-8 !text-nc-content-teal-medium" />
      </template>
    </ProjectActionItem>

    <NcModal
      v-model:visible="open"
      :title="$t('labels.tableSync')"
      size="medium"
      class="nc-table-sync-wizard"
      data-testid="table-sync-wizard"
    >
      <div class="text-sm text-nc-content-gray-subtle2 mb-4">
        {{ $t('labels.tableSyncDesc') }}
      </div>

      <!-- Step 0: source base + table -->
      <div v-if="step === 0" class="flex flex-col gap-4">
        <!-- [CE-EE] F09 P2: source mode picker — browse (own bases) or paste
             (shared view url from another base) -->
        <a-radio-group v-model:value="sourceMode" class="flex gap-4">
          <a-radio value="browse">{{ $t('labels.sourceModeBrowse') }}</a-radio>
          <a-radio value="paste">{{ $t('labels.sourceModePasteLink') }}</a-radio>
        </a-radio-group>
        <template v-if="sourceMode === 'paste'">
          <div>
            <div class="mb-1 font-medium">{{ $t('labels.sharedViewLink') }}</div>
            <a-input
              v-model:value="sharedViewUrl"
              :placeholder="$t('labels.sourceModePasteLinkDesc')"
              data-testid="table-sync-shared-view-url"
            />
          </div>
          <div v-if="sharedViewUrl">
            <div class="mb-1 font-medium">{{ $t('labels.password') }}</div>
            <a-input-password
              v-model:value="sharedViewPassword"
              :placeholder="$t('optional')"
              data-testid="table-sync-shared-view-password"
            />
          </div>
        </template>
        <template v-else>
        <div>
          <div class="mb-1 font-medium">{{ $t('labels.sourceModeBrowse') }}</div>
          <div class="mb-2 text-xs text-nc-content-gray-subtle2">
            {{ $t('labels.sourceModeBrowseDesc') }}
          </div>
          <NcSelect
            v-model:value="selectedBaseId"
            :options="bases.map((b) => ({ label: b.title, value: b.id }))"
            :placeholder="$t('title.newBase')"
            data-testid="table-sync-source-base"
            class="w-full"
            show-search
            :filter-option="filterSelectOption"
            :loading="isLoading"
          />
        </div>
        <div v-if="selectedBaseId">
          <div class="mb-2 font-medium">{{ $t('objects.table') }}</div>
          <NcSelect
            v-model:value="selectedTableId"
            :options="tables.map((tb) => ({ label: tb.title, value: tb.id }))"
            :placeholder="$t('objects.table')"
            data-testid="table-sync-source-table"
            class="w-full"
            show-search
            :filter-option="filterSelectOption"
            :loading="isLoading"
          />
        </div>
        <div v-if="selectedTableId && schema && !schema.view" class="text-xs text-nc-content-orange-dark">
          {{ $t('tooltip.allowSyncDescription') }}
        </div>
        </template>
      </div>

      <!-- Step 1: view + fields -->
      <div v-else-if="step === 1" class="flex flex-col gap-4">
        <div v-if="allowSyncViews.length">
          <div class="mb-2 font-medium">{{ $t('objects.view') }}</div>
          <NcSelect
            v-model:value="selectedViewId"
            :options="allowSyncViews.map((v) => ({ label: v.title, value: v.id }))"
            class="w-full"
            data-testid="table-sync-source-view"
          />
        </div>
        <div>
          <div class="mb-2 font-medium">{{ $t('labels.fieldsToSync') }}</div>
          <a-radio-group v-model:value="fieldMode" class="flex flex-col gap-2">
            <a-radio value="all">{{ $t('labels.allFieldsAreSyncedByDefault') }}</a-radio>
            <a-radio value="specific">{{ $t('labels.selectSpecificFieldsToSync') }}</a-radio>
          </a-radio-group>
          <div v-if="fieldMode === 'specific'" class="mt-2 flex flex-col gap-1 max-h-60 overflow-auto">
            <a-checkbox
              v-for="col in schema?.columns ?? []"
              :key="col.id"
              :checked="selectedFields.includes(col.title)"
              data-testid="table-sync-field"
              @change="(e: any) => {
                selectedFields = e.target.checked
                  ? [...selectedFields, col.title]
                  : selectedFields.filter((f) => f !== col.title)
              }"
            >
              {{ col.title }}
            </a-checkbox>
          </div>
        </div>
      </div>

      <!-- Step 2: settings -->
      <div v-else class="flex flex-col gap-4">
        <div>
          <div class="mb-2 font-medium">{{ $t('labels.syncSettings') }}</div>
          <a-input
            v-model:value="syncTitle"
            :placeholder="$t('objects.table')"
            data-testid="table-sync-title"
          />
        </div>
        <div>
          <div class="mb-2 font-medium">{{ $t('labels.syncMethod') }}</div>
          <div>{{ $t('labels.manually') }} — {{ $t('labels.manuallyDesc') }}</div>
        </div>
        <div>
          <div class="mb-2 font-medium">{{ $t('labels.recordsDeletedInSourceWillBe') }}</div>
          <a-radio-group v-model:value="deleteAction" class="flex flex-col gap-2">
            <a-radio :value="TableSyncOnDeleteAction.Delete">
              {{ $t('labels.deletedInMirroredTable') }}
            </a-radio>
            <a-radio :value="TableSyncOnDeleteAction.MarkDeleted">
              {{ $t('labels.retainedInMirroredTable') }}
            </a-radio>
          </a-radio-group>
        </div>
      </div>

      <!-- [CE-EE] F09 R1(lane2/3/4): buttons moved from #footer into the body —
           nc/Modal hardcodes :footer="null" without a footer slot outlet, so
           footer-slot content never rendered -->
      <div class="flex justify-end gap-2 mt-4">
        <NcButton
          v-if="step > 0"
          type="secondary"
          data-testid="table-sync-back"
          @click="step = (step - 1) as 0 | 1"
        >
          {{ $t('general.back') }}
        </NcButton>
        <NcButton
          v-if="step < 2"
          type="primary"
          :loading="step === 0 && isLoading"
          :disabled="
            step === 0
              ? sourceMode === 'paste'
                ? !sharedViewUrl
                : !selectedTableId || !schema?.view
              : false
          "
          data-testid="table-sync-next"
          @click="step === 0 ? nextFromStep0() : (step = 2)"
        >
          {{ $t('general.next') }}
        </NcButton>
        <NcButton
          v-else
          type="primary"
          :loading="isCreating"
          data-testid="table-sync-create"
          @click="createSync()"
        >
          {{ $t('labels.createSyncTable') }}
        </NcButton>
      </div>
    </NcModal>
  </div>
</template>
