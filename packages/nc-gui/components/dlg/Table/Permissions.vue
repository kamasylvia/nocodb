<script setup lang="ts">
// [CE-EE] F03: table-level data permission configuration (replaces the CE
// stub). Three keys on one grant each: TABLE_RECORD_ADD / TABLE_RECORD_DELETE
// / TABLE_VISIBILITY. Visibility "Everyone" is the absence of a grant row.
import {
  PermissionEntity,
  PermissionGrantedType,
  PermissionKey,
  PermissionOptionValue,
  PermissionRole,
} from 'nocodb-sdk'

const props = defineProps<{
  visible: boolean
  tableId: string
  title?: string
}>()

const emit = defineEmits(['update:visible'])

const { $api } = useNuxtApp()
const { t } = useI18n()
const { base } = storeToRefs(useBase())
const basesStore = useBases()

const { permissionOptions, permissions, loadPermissions, getPermissionLabel } = usePermissions()

const isSaving = ref(false)
const members = ref<{ id: string; label: string }[]>([])

type KeyState = {
  option: PermissionOptionValue
  users: string[]
  grantId: string | null
  enforceForForm: boolean
  dirty: boolean
}

// per-key editor state (TABLE_RECORD_ADD / TABLE_RECORD_DELETE / TABLE_VISIBILITY)
const states = ref<Record<string, KeyState>>({})

const addDeleteOptions = computed(() =>
  permissionOptions.filter(
    (o) =>
      o.value !== PermissionOptionValue.EVERYONE &&
      o.value !== PermissionOptionValue.VIEWERS_AND_UP &&
      o.value !== PermissionOptionValue.COMMENTERS_AND_UP,
  ),
)

const visibilityOptions = computed(() =>
  permissionOptions.filter(
    (o) =>
      o.value !== PermissionOptionValue.EDITORS_AND_UP &&
      o.value !== PermissionOptionValue.CREATORS_AND_UP &&
      o.value !== PermissionOptionValue.COMMENTERS_AND_UP,
  ),
)

const optionLabel = (o: PermissionOptionValue) =>
  getPermissionLabel(o) || o

const loadMembers = async () => {
  if (!base.value?.id) return
  try {
    const { users } = await basesStore.getBaseUsers({
      baseId: base.value.id,
      force: true,
    })
    members.value = (users || [])
      .filter((u: any) => !u?.deleted)
      .map((u: any) => ({ id: u.id, label: u.display_name || u.email }))
  } catch (e) {
    members.value = []
  }
}

const grantFor = (permission: PermissionKey) =>
  (permissions.value ?? []).find(
    (p) =>
      p.entity === PermissionEntity.TABLE &&
      p.entity_id === props.tableId &&
      p.permission === permission,
  )

const OPTION_FOR_ROLE: Record<string, PermissionOptionValue> = {
  viewer: PermissionOptionValue.VIEWERS_AND_UP,
  commenter: PermissionOptionValue.COMMENTERS_AND_UP,
  editor: PermissionOptionValue.EDITORS_AND_UP,
  creator: PermissionOptionValue.CREATORS_AND_UP,
  owner: PermissionOptionValue.CREATORS_AND_UP,
}

const loadCurrent = async () => {
  states.value = {}
  if (!base.value?.id || !props.tableId) return
  await loadPermissions(true)

  for (const permission of [
    PermissionKey.TABLE_RECORD_ADD,
    PermissionKey.TABLE_RECORD_DELETE,
    PermissionKey.TABLE_VISIBILITY,
  ]) {
    const grant = grantFor(permission)
    const key = permission as string
    const st: KeyState = {
      // VISIBILITY default is EVERYONE (no grant = everyone can see); other
      // keys default to EDITORS_AND_UP (no grant = editors and up)
      option:
        permission === PermissionKey.TABLE_VISIBILITY
          ? PermissionOptionValue.EVERYONE
          : PermissionOptionValue.EDITORS_AND_UP,
      users: [],
      grantId: grant?.id ?? null,
      enforceForForm: grant ? grant.enforce_for_form !== false : true,
      dirty: false,
    }
    if (grant) {
      if (grant.granted_type === PermissionGrantedType.NOBODY) {
        st.option = PermissionOptionValue.NOBODY
      } else if (grant.granted_type === PermissionGrantedType.USER) {
        st.option = PermissionOptionValue.SPECIFIC_USERS
        st.users = (grant.subjects ?? [])
          .filter((s: any) => s.type === 'user')
          .map((s: any) => s.id)
      } else {
        st.option =
          OPTION_FOR_ROLE[grant.granted_role as PermissionRole] ??
          PermissionOptionValue.EDITORS_AND_UP
      }
    }
    states.value[key] = st
  }
}

const buildPayload = (
  permission: PermissionKey,
  st: KeyState,
): any | null => {
  if (permission === PermissionKey.TABLE_VISIBILITY) {
    if (st.option === PermissionOptionValue.EVERYONE) return 'DELETE'
    if (st.option === PermissionOptionValue.NOBODY) {
      return {
        entity: PermissionEntity.TABLE,
        entity_id: props.tableId,
        permission,
        granted_type: PermissionGrantedType.NOBODY,
      }
    }
    if (st.option === PermissionOptionValue.SPECIFIC_USERS) {
      if (!st.users.length) return undefined
      return {
        entity: PermissionEntity.TABLE,
        entity_id: props.tableId,
        permission,
        granted_type: PermissionGrantedType.USER,
        subjects: st.users.map((id) => ({ type: 'user', id })),
      }
    }
    const role = {
      [PermissionOptionValue.VIEWERS_AND_UP]: PermissionRole.VIEWER,
      [PermissionOptionValue.CREATORS_AND_UP]: PermissionRole.CREATOR,
    }[st.option as PermissionOptionValue]
    if (!role) return undefined
    return {
      entity: PermissionEntity.TABLE,
      entity_id: props.tableId,
      permission,
      granted_type: PermissionGrantedType.ROLE,
      granted_role: role,
    }
  }

  // ADD / DELETE
  if (st.option === PermissionOptionValue.EDITORS_AND_UP) return 'DELETE'
  if (st.option === PermissionOptionValue.NOBODY) {
    return {
      entity: PermissionEntity.TABLE,
      entity_id: props.tableId,
      permission,
      granted_type: PermissionGrantedType.NOBODY,
    }
  }
  if (st.option === PermissionOptionValue.SPECIFIC_USERS) {
    if (!st.users.length) return undefined
    return {
      entity: PermissionEntity.TABLE,
      entity_id: props.tableId,
      permission,
      granted_type: PermissionGrantedType.USER,
      subjects: st.users.map((id) => ({ type: 'user', id })),
    }
  }
  const role = {
    [PermissionOptionValue.CREATORS_AND_UP]: PermissionRole.CREATOR,
  }[st.option as PermissionOptionValue]
  if (!role) return undefined
  return {
    entity: PermissionEntity.TABLE,
    entity_id: props.tableId,
    permission,
    granted_type: PermissionGrantedType.ROLE,
    granted_role: role,
  }
}

const save = async () => {
  if (!base.value?.id || !props.tableId) return
  isSaving.value = true
  try {
    const url = `/api/v2/meta/bases/${base.value.id}/permissions`

    for (const permission of [
      PermissionKey.TABLE_RECORD_ADD,
      PermissionKey.TABLE_RECORD_DELETE,
      PermissionKey.TABLE_VISIBILITY,
    ]) {
      const st = states.value[permission as string]
      if (!st || !st.dirty) continue

      const existingId = st.grantId
      const payload = buildPayload(permission, st)

      if (!payload || payload === 'DELETE') {
        if (existingId) {
          await $api.instance.delete(`${url}/${existingId}`)
        }
        st.grantId = null
        continue
      }

      if (existingId) {
        await $api.instance.patch(`${url}/${existingId}`, payload)
      } else {
        const created = await $api.instance.post(url, payload)
        st.grantId = created?.data?.id ?? null
      }
    }

    await loadPermissions(true)
    message.success(t('msg.success.permissionUpdated'))
    emit('update:visible', false)
  } catch (e: any) {
    message.error(await extractSdkResponseErrorMsg(e))
  } finally {
    isSaving.value = false
  }
}

const resetAll = async () => {
  if (!base.value?.id) return
  isSaving.value = true
  try {
    for (const permission of [
      PermissionKey.TABLE_RECORD_ADD,
      PermissionKey.TABLE_RECORD_DELETE,
      PermissionKey.TABLE_VISIBILITY,
    ]) {
      const grant = grantFor(permission)
      if (grant) {
        await $api.instance.delete(
          `/api/v2/meta/bases/${base.value.id}/permissions/${grant.id}`,
        )
      }
    }
    await loadPermissions(true)
    await loadCurrent()
    message.success(t('msg.success.permissionUpdated'))
  } catch (e: any) {
    message.error(await extractSdkResponseErrorMsg(e))
  } finally {
    isSaving.value = false
  }
}

const hasAnyGrant = computed(() =>
  [
    PermissionKey.TABLE_RECORD_ADD,
    PermissionKey.TABLE_RECORD_DELETE,
    PermissionKey.TABLE_VISIBILITY,
  ].some((permission) =>
    (permissions.value ?? []).some(
      (p) =>
        p.entity === PermissionEntity.TABLE &&
        p.entity_id === props.tableId &&
        p.permission === permission,
    ),
  ),
)

watch(
  () => props.visible,
  (v) => {
    if (v) {
      void loadCurrent()
      void loadMembers()
    }
  },
  { immediate: true },
)
</script>

<template>
  <NcModal
    :visible="visible"
    :header="`${$t('title.tablePermissions')} — ${title ?? ''}`"
    size="small"
    @update:visible="emit('update:visible', $event)"
  >
    <div class="flex flex-col gap-5 px-1">
      <a-spin :spinning="isSaving">
        <div
          v-for="permission of [
            PermissionKey.TABLE_RECORD_ADD,
            PermissionKey.TABLE_RECORD_DELETE,
            PermissionKey.TABLE_VISIBILITY,
          ]"
          :key="permission"
          class="flex flex-col gap-2 border-b border-nc-border-gray-200 pb-4 mb-2 last:border-b-0"
          :data-testid="`nc-table-permission-${permission}`"
        >
          <div class="font-medium text-sm">
            {{
              permission === PermissionKey.TABLE_RECORD_ADD
                ? $t('objects.permissions.whoCanAddRecords')
                : permission === PermissionKey.TABLE_RECORD_DELETE
                  ? $t('objects.permissions.whoCanDeleteRecords')
                  : $t('title.tableVisibility')
            }}
          </div>

          <template
            v-for="opt of (permission === PermissionKey.TABLE_VISIBILITY
              ? visibilityOptions
              : addDeleteOptions)"
            :key="opt.value"
          >
            <div
              v-if="
                opt.value !== PermissionOptionValue.SPECIFIC_USERS ||
                states[permission]?.option === PermissionOptionValue.SPECIFIC_USERS
              "
              class="flex items-center gap-2"
            >
              <div
                class="flex items-center gap-2 cursor-pointer py-1 px-2 rounded"
                :data-testid="`nc-table-permission-${permission}-${opt.value}`"
                @click="states[permission].option = opt.value; states[permission].dirty = true"
              >
                <span
                  class="w-4 h-4 rounded-full border-2 flex items-center justify-center flex-shrink-0"
                  :class="states[permission]?.option === opt.value ? 'border-nc-border-brand' : 'border-nc-border-gray-400'"
                >
                  <span
                    v-if="states[permission]?.option === opt.value"
                    class="w-2 h-2 rounded-full bg-nc-fill-brand"
                  />
                </span>
                <span class="text-sm">{{ optionLabel(opt.value) }}</span>
              </div>
            </div>

            <div
              v-if="
                opt.value === PermissionOptionValue.SPECIFIC_USERS &&
                states[permission]?.option === PermissionOptionValue.SPECIFIC_USERS
              "
              class="pl-6"
            >
              <a-select
                v-model:value="states[permission].users"
                mode="multiple"
                class="w-full"
                option-filter-prop="label"
                :placeholder="$t('objects.permissions.inlineUserSelector.selectUsers')"
                :options="members.map((m) => ({ value: m.id, label: m.label }))"
                :data-testid="`nc-table-permission-${permission}-users`"
              />
            </div>
          </template>
        </div>
      </a-spin>
    </div>

    <div class="flex items-center justify-end gap-2 pt-2">
      <NcButton
        v-if="hasAnyGrant"
        type="text"
        size="small"
        :disabled="isSaving"
        data-testid="nc-table-permission-reset"
        @click="resetAll"
      >
        {{ $t('objects.permissions.resetTablePermissions') }}
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
          data-testid="nc-table-permission-save"
          @click="save"
        >
          {{ $t('general.save') }}
        </NcButton>
      </div>
    </div>
  </NcModal>
</template>
