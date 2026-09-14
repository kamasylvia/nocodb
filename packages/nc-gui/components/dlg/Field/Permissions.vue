<script setup lang="ts">
// [CE-EE] F02: single-field edit permission configuration (replaces the CE
// stub). One grant row per field — RECORD_FIELD_EDIT.
import {
  PermissionEntity,
  PermissionKey,
  PermissionOptionValue,
  PermissionGrantedType,
  PermissionRole,
} from 'nocodb-sdk'

const props = defineProps<{
  visible: boolean
  fieldId: string
  fieldTitle: string
  fieldUidt: string
}>()

const emit = defineEmits(['update:visible'])

const { $api } = useNuxtApp()
const { t } = useI18n()
const { base } = storeToRefs(useBase())
const basesStore = useBases()

const { permissionOptions, permissions, loadPermissions, getPermissionLabel } = usePermissions()

const selected = ref<PermissionOptionValue>(PermissionOptionValue.EDITORS_AND_UP)
const selectedUsers = ref<string[]>([])
const existingId = ref<string | null>(null)
const isSaving = ref(false)

const memberOptions = ref<{ id: string; label: string }[]>([])

// role-style options available for field edit permissions (EVERYONE is a
// table-visibility concept; viewers/commenters are read-only roles anyway)
const options = computed(() =>
  permissionOptions.filter(
    (o) =>
      o.value !== PermissionOptionValue.EVERYONE &&
      o.value !== PermissionOptionValue.COMMENTERS_AND_UP &&
      o.value !== PermissionOptionValue.VIEWERS_AND_UP,
  ),
)

const loadMembers = async () => {
  if (!base.value?.id) return
  try {
    const { users } = await basesStore.getBaseUsers({
      baseId: base.value.id,
      force: true,
    })
    memberOptions.value = (users || [])
      .filter((u: any) => !u?.deleted)
      .map((u: any) => ({
        id: u.id,
        label: u.display_name || u.email,
      }))
  } catch (e) {
    memberOptions.value = []
  }
}

const loadCurrentGrant = async () => {
  existingId.value = null
  selectedUsers.value = []
  selected.value = PermissionOptionValue.EDITORS_AND_UP

  if (!base.value?.id || !props.fieldId) return

  // make sure the composable holds the current grant set
  await loadPermissions()

  const grant = (permissions.value ?? []).find(
    (p) =>
      p.entity === PermissionEntity.FIELD &&
      p.entity_id === props.fieldId &&
      p.permission === PermissionKey.RECORD_FIELD_EDIT,
  )

  if (!grant) {
    selected.value = PermissionOptionValue.EDITORS_AND_UP
    return
  }

  existingId.value = grant.id

  if (grant.granted_type === PermissionGrantedType.NOBODY) {
    selected.value = PermissionOptionValue.NOBODY
  } else if (grant.granted_type === PermissionGrantedType.USER) {
    selected.value = PermissionOptionValue.SPECIFIC_USERS
    selectedUsers.value = (grant.subjects ?? [])
      .filter((s: any) => s.type === 'user')
      .map((s: any) => s.id)
  } else {
    selected.value =
      ({
        viewer: PermissionOptionValue.VIEWERS_AND_UP,
        commenter: PermissionOptionValue.COMMENTERS_AND_UP,
        editor: PermissionOptionValue.EDITORS_AND_UP,
        creator: PermissionOptionValue.CREATORS_AND_UP,
        owner: PermissionOptionValue.CREATORS_AND_UP,
      }[grant.granted_role as PermissionRole] as PermissionOptionValue) ??
      PermissionOptionValue.EDITORS_AND_UP
  }
}

const save = async () => {
  if (!base.value?.id || !props.fieldId) return
  isSaving.value = true
  try {
    const baseId = base.value.id
    const url = `/api/v2/meta/bases/${baseId}/permissions`

    // default state = no grant row at all
    if (selected.value === PermissionOptionValue.EDITORS_AND_UP) {
      if (existingId.value) {
        await $api.instance.delete(`${url}/${existingId.value}`)
      }
    } else {
      const payload: any = {
        entity: PermissionEntity.FIELD,
        entity_id: props.fieldId,
        permission: PermissionKey.RECORD_FIELD_EDIT,
      }

      if (selected.value === PermissionOptionValue.NOBODY) {
        payload.granted_type = PermissionGrantedType.NOBODY
      } else if (selected.value === PermissionOptionValue.SPECIFIC_USERS) {
        if (!selectedUsers.value.length) {
          message.error(t('labels.selectUsers'))
          isSaving.value = false
          return
        }
        payload.granted_type = PermissionGrantedType.USER
        payload.subjects = selectedUsers.value.map((id) => ({
          type: 'user',
          id,
        }))
      } else {
        payload.granted_type = PermissionGrantedType.ROLE
        payload.granted_role =
          ({
            [PermissionOptionValue.VIEWERS_AND_UP]: PermissionRole.VIEWER,
            [PermissionOptionValue.COMMENTERS_AND_UP]: PermissionRole.COMMENTER,
            [PermissionOptionValue.EDITORS_AND_UP]: PermissionRole.EDITOR,
            [PermissionOptionValue.CREATORS_AND_UP]: PermissionRole.CREATOR,
          }[selected.value] as PermissionRole) ?? PermissionRole.EDITOR
      }

      if (existingId.value) {
        await $api.instance.patch(`${url}/${existingId.value}`, payload)
      } else {
        const created = await $api.instance.post(url, payload)
        existingId.value = created?.data?.id ?? null
      }
    }

    // refresh the shared grant list so grid/form react immediately
    await loadPermissions(true)

    message.success(t('msg.success.permissionUpdated'))
    emit('update:visible', false)
  } catch (e: any) {
    message.error(await extractSdkResponseErrorMsg(e))
  } finally {
    isSaving.value = false
  }
}

const resetToDefault = async () => {
  if (!base.value?.id || !existingId.value) return
  isSaving.value = true
  try {
    await $api.instance.delete(
      `/api/v2/meta/bases/${base.value.id}/permissions/${existingId.value}`,
    )
    await loadPermissions(true)
    existingId.value = null
    selected.value = PermissionOptionValue.EDITORS_AND_UP
    selectedUsers.value = []
    message.success(t('msg.success.permissionUpdated'))
  } catch (e: any) {
    message.error(await extractSdkResponseErrorMsg(e))
  } finally {
    isSaving.value = false
  }
}

watch(
  () => props.visible,
  (v) => {
    if (v) {
      void loadCurrentGrant()
      void loadMembers()
    }
  },
)

// [CE-EE] F02 R2: when the host view unmounts (e.g. sign-out with the
// dialog open) the ant-modal teleport wrap must not outlive the state —
// reset visible so the wrap is torn down instead of blocking /signin
onBeforeUnmount(() => {
  if (props.visible) {
    emit('update:visible', false)
  }
})
</script>

<template>
  <NcModal
    :visible="visible"
    :header="$t('title.editFieldPermissions')"
    size="small"
    @update:visible="emit('update:visible', $event)"
  >
    <!-- [CE-EE] F02 R1: NcModal hardcodes a-modal :footer="null" — render
         actions inside the body instead of a footer slot -->
    <div class="flex flex-col gap-4 px-1">
      <div class="text-sm text-nc-content-gray-subtle">
        {{ fieldTitle }}
      </div>

      <a-spin :spinning="isSaving">
        <div class="flex flex-col gap-2">
          <div
            v-for="opt of options"
            :key="opt.value"
            v-e="['a:field:permission-select']"
            class="rounded-lg border p-3 flex items-center gap-3 cursor-pointer transition-colors"
            :class="
              selected === opt.value
                ? 'border-nc-border-brand bg-nc-bg-gray-extralight'
                : 'border-nc-border-gray-200 hover:bg-nc-bg-gray-extralight'
            "
            :data-testid="`nc-field-permission-${opt.value}`"
            @click="selected = opt.value"
          >
            <GeneralIcon :icon="opt.icon" class="w-4 h-4" />
            <div class="flex flex-col">
              <div class="font-medium">{{ getPermissionLabel(opt.value) }}</div>
              <div class="text-xs text-nc-content-gray-subtle">
                {{ opt.description }}
              </div>
            </div>
          </div>

          <div v-if="selected === PermissionOptionValue.SPECIFIC_USERS" class="mt-1">
            <a-select
              v-model:value="selectedUsers"
              mode="multiple"
              class="w-full"
              option-filter-prop="label"
              :placeholder="$t('objects.permissions.inlineUserSelector.selectUsers')"
              :options="memberOptions.map((m) => ({ value: m.id, label: m.label }))"
              data-testid="nc-field-permission-users"
            />
          </div>
        </div>
      </a-spin>

      <div class="flex items-center justify-between w-full pt-2">

        <NcButton
          v-if="existingId"
          type="text"
          size="small"
          :disabled="isSaving"
          data-testid="nc-field-permission-reset"
          @click="resetToDefault"
        >
          {{ $t('objects.permissions.resetFieldPermissions') }}
        </NcButton>
        <span v-else />
        <div class="flex items-center gap-2">
          <NcButton
            type="secondary"
            size="small"
            :disabled="isSaving"
            @click="emit('update:visible', false)"
          >
            {{ $t('general.cancel') }}
          </NcButton>
          <NcButton
            type="primary"
            size="small"
            :loading="isSaving"
            data-testid="nc-field-permission-save"
            @click="save"
          >
            {{ $t('general.save') }}
          </NcButton>
        </div>
      </div>
    </div>
  </NcModal>
</template>
