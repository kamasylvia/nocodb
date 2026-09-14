<script setup lang="ts">
// [CE-EE] F02: table details "Permissions" tab body (replaces the CE stub).
// Shows per-field edit permission summaries for this table and opens the
// single-field configuration dialog. Table-level permissions (record
// add/delete/visibility) arrive with F03 and are shown as defaults meanwhile.
import {
  getPermissionLabel,
  PermissionEntity,
  PermissionKey,
  PermissionOptionValue,
} from 'nocodb-sdk'
import { MetaInj } from '~/context'

interface Props {
  tableId: string
  permissionsFieldWrapperClass?: string
  permissionsTableWrapperClass?: string
}

const props = defineProps<Props>()

const { t } = useI18n()
const meta = inject(MetaInj, ref())

const { permissions, loadPermissions, getPermissionSummary, getPermissionSummaryLabel } = usePermissions()

const isModalVisible = ref(false)
const activeField = ref<{ id: string; title: string; uidt: string } | null>(null)

const fields = computed(() =>
  (meta.value?.columns ?? []).filter(
    (c: any) => !c.system && !c.pk && c.uidt !== 'ForeignKey',
  ),
)

const summaryOf = (colId: string) => {
  const summary = getPermissionSummary(
    PermissionEntity.FIELD,
    colId,
    PermissionKey.RECORD_FIELD_EDIT,
  )
  return summary === PermissionOptionValue.EDITORS_AND_UP
    ? `${t('labels.default')} — ${getPermissionLabel(summary)}`
    : getPermissionLabel(summary)
}

const openField = (col: any) => {
  activeField.value = { id: col.id, title: col.title, uidt: col.uidt }
  isModalVisible.value = true
}

const isTablePermDialogVisible = ref(false)

onMounted(async () => {
  await loadPermissions()
})
</script>

<template>
  <div class="flex flex-col gap-6 pt-4">
    <!-- [CE-EE] F03: table-level data permissions (ADD / DELETE / VISIBILITY) -->
    <div
      class="rounded-lg border border-nc-border-gray-200 p-4 text-sm flex flex-col gap-2"
      data-testid="nc-table-permissions-summary"
    >
      <div class="flex items-center justify-between">
        <div class="font-medium">{{ $t('title.tablePermissions') }}</div>
        <NcButton
          type="secondary"
          size="small"
          data-testid="nc-table-permissions-configure"
          @click="isTablePermDialogVisible = true"
        >
          {{ $t('general.edit') }}
        </NcButton>
      </div>
      <div
        v-for="permission of [
          PermissionKey.TABLE_RECORD_ADD,
          PermissionKey.TABLE_RECORD_DELETE,
          PermissionKey.TABLE_VISIBILITY,
        ]"
        :key="permission"
        class="flex items-center justify-between"
      >
        <span class="text-nc-content-gray-subtle">
          {{
            permission === PermissionKey.TABLE_RECORD_ADD
              ? $t('objects.permissions.whoCanAddRecords')
              : permission === PermissionKey.TABLE_RECORD_DELETE
                ? $t('objects.permissions.whoCanDeleteRecords')
                : $t('title.tableVisibility')
          }}
        </span>
        <span>{{ getPermissionSummaryLabel(PermissionEntity.TABLE, tableId, permission) }}</span>
      </div>
    </div>

    <!-- Field permissions -->
    <div class="flex flex-col gap-2" :class="props.permissionsFieldWrapperClass">
      <div class="font-medium">{{ $t('title.fieldPermissions') }}</div>

      <div class="flex flex-col gap-1" :class="props.permissionsTableWrapperClass">
        <div
          v-for="col of fields"
          :key="col.id"
          class="flex items-center justify-between rounded-lg border border-nc-border-gray-200 px-3 py-2 hover:bg-nc-bg-gray-extralight"
          :data-testid="`nc-permissions-field-${col.title}`"
        >
          <div class="flex items-center gap-2 min-w-0">
            <SmartsheetHeaderIcon :column="col" />
            <span class="truncate">{{ col.title }}</span>
          </div>

          <div class="flex items-center gap-3">
            <span class="text-xs text-nc-content-gray-subtle">
              {{ summaryOf(col.id) }}
            </span>
            <NcButton
              type="secondary"
              size="small"
              :data-testid="`nc-permissions-configure-${col.title}`"
              @click="openField(col)"
            >
              {{ $t('general.edit') }}
            </NcButton>
          </div>
        </div>
      </div>
    </div>

    <DlgFieldPermissions
      v-if="activeField"
      v-model:visible="isModalVisible"
      :field-id="activeField.id"
      :field-title="activeField.title"
      :field-uidt="activeField.uidt"
    />

    <DlgTablePermissions
      v-if="tableId"
      v-model:visible="isTablePermDialogVisible"
      :table-id="tableId"
      :title="meta?.title"
    />
  </div>
</template>
