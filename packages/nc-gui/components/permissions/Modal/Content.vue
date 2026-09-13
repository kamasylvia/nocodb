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

const { permissions, loadPermissions, getPermissionSummary } = usePermissions()

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

onMounted(async () => {
  await loadPermissions()
})
</script>

<template>
  <div class="flex flex-col gap-6 pt-4">
    <!-- Table-level permissions (F03 scope) — defaults for now -->
    <div
      class="rounded-lg border border-nc-border-gray-200 bg-nc-bg-gray-extralight p-4 text-sm text-nc-content-gray-subtle"
      data-testid="nc-table-permissions-defaults"
    >
      {{ $t('objects.permissions.resetTablePermissionsDescription') }}
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
  </div>
</template>
