<script setup lang="ts">
// [CE-EE] F05: base variables management UI (replaces the CE stub)
import { BaseVariableValueType } from 'nocodb-sdk'
import type { BaseVariableType } from 'nocodb-sdk'

const { $api } = useNuxtApp()
const { t } = useI18n()
const { openedProject } = storeToRefs(useBases())

const variables = ref<BaseVariableType[]>([])
const isLoading = ref(false)

const modalVisible = ref(false)
const isEditing = ref(false)
const isSaving = ref(false)

const editingVariable = ref<Partial<BaseVariableType>>({
  key: '',
  value: '',
  description: '',
  type: BaseVariableValueType.TEXT,
})

const baseId = computed(() => openedProject.value?.id)

const loadVariables = async () => {
  if (!baseId.value) return
  isLoading.value = true
  try {
    const res = await $api.instance.get(
      `/api/v2/meta/bases/${baseId.value}/variables`,
    )
    variables.value = res.data?.list ?? res.data ?? []
  } catch (e: any) {
    message.error(await extractSdkResponseErrorMsg(e))
  } finally {
    isLoading.value = false
  }
}

const openCreateModal = () => {
  isEditing.value = false
  editingVariable.value = {
    key: '',
    value: '',
    description: '',
    type: BaseVariableValueType.TEXT,
  }
  modalVisible.value = true
}

const openEditModal = async (variable: BaseVariableType) => {
  isEditing.value = true
  // secrets are masked in the list response — fetch the single variable
  // to prefill the real value
  if (variable.type === BaseVariableValueType.SECRET) {
    try {
      const res = await $api.instance.get(
        `/api/v2/meta/bases/${baseId.value}/variables/${variable.id}`,
      )
      editingVariable.value = { ...res.data }
    } catch (e: any) {
      message.error(await extractSdkResponseErrorMsg(e))
      return
    }
  } else {
    editingVariable.value = { ...variable }
  }
  modalVisible.value = true
}

const saveVariable = async () => {
  const { key, value, description, type } = editingVariable.value
  if (!key?.trim()) {
    message.error(t('msg.error.baseVariableKeyRequired'))
    return
  }
  isSaving.value = true
  try {
    if (isEditing.value && editingVariable.value.id) {
      await $api.instance.patch(
        `/api/v2/meta/bases/${baseId.value}/variables/${editingVariable.value.id}`,
        { value, description, type },
      )
      message.success(t('msg.success.baseVariableUpdated'))
    } else {
      await $api.instance.post(`/api/v2/meta/bases/${baseId.value}/variables`, {
        key: key.trim(),
        value,
        description,
        type,
      })
      message.success(t('msg.success.baseVariableCreated'))
    }
    modalVisible.value = false
    await loadVariables()
  } catch (e: any) {
    message.error(await extractSdkResponseErrorMsg(e))
  } finally {
    isSaving.value = false
  }
}

const deleteVariable = async (variable: BaseVariableType) => {
  Modal.confirm({
    title: t('msg.info.baseVariableDeleteTitle'),
    content: t('msg.info.baseVariableDeleteDescription', { key: variable.key }),
    okText: t('general.delete'),
    okType: 'danger',
    cancelText: t('general.cancel'),
    async onOk() {
      try {
        await $api.instance.delete(
          `/api/v2/meta/bases/${baseId.value}/variables/${variable.id}`,
        )
        message.success(t('msg.success.baseVariableDeleted'))
        await loadVariables()
      } catch (e: any) {
        message.error(await extractSdkResponseErrorMsg(e))
      }
    },
  })
}

onMounted(loadVariables)
</script>

<template>
  <div class="nc-base-variables max-w-250">
    <div class="flex items-center justify-between mb-4">
      <div>
        <div class="text-lg font-weight-600">{{ $t('title.baseVariables') }}</div>
        <div class="text-sm text-nc-content-gray-subtle">
          {{ $t('msg.info.baseVariablesSubtitle') }}
        </div>
      </div>
      <NcButton type="primary" size="small" data-testid="base-variables-add" @click="openCreateModal">
        <div class="flex items-center gap-1">
          <GeneralIcon icon="plus" />
          {{ $t('general.add') }}
        </div>
      </NcButton>
    </div>

    <div v-if="isLoading" class="py-8 text-center text-nc-content-gray-subtle">
      <GeneralLoader />
    </div>

    <div v-else-if="!variables.length" class="py-10 text-center text-nc-content-gray-subtle text-sm">
      {{ $t('msg.info.baseVariablesEmpty') }}
    </div>

    <div v-else class="flex flex-col gap-2">
      <div
        v-for="variable in variables"
        :key="variable.id"
        class="flex items-center gap-3 border-1 border-nc-border-gray-medium rounded-lg px-4 py-2"
        :data-testid="`base-variables-row-${variable.key}`"
      >
        <div class="w-60 font-weight-600 font-mono text-sm">{{ variable.key }}</div>
        <div class="flex-1 truncate text-sm text-nc-content-gray">
          <template v-if="variable.type === BaseVariableValueType.SECRET">
            <span class="flex items-center gap-1">
              <GeneralIcon icon="eye" class="text-nc-content-gray-muted" />
              <!-- [CE-EE] F05 R4: value is always masked server-side — show the
                   dots by type, not by whether a (stripped) value exists -->
              <span v-if="variable.value" class="font-mono">{{ variable.value }}</span>
              <span v-else class="font-mono text-nc-content-gray-muted">••••••••</span>
            </span>
          </template>
          <template v-else>{{ variable.value }}</template>
        </div>
        <div class="w-24 text-xs text-nc-content-gray-muted uppercase">{{ variable.type }}</div>
        <div class="flex-1 truncate text-sm text-nc-content-gray-subtle">{{ variable.description }}</div>
        <div class="flex items-center gap-1">
          <NcButton type="text" size="small" :data-testid="`base-variables-edit-${variable.key}`" @click="openEditModal(variable)">
            <GeneralIcon icon="edit" />
          </NcButton>
          <NcButton type="text" size="small" :data-testid="`base-variables-delete-${variable.key}`" @click="deleteVariable(variable)">
            <GeneralIcon icon="delete" class="text-nc-content-red-medium" />
          </NcButton>
        </div>
      </div>
    </div>

    <NcModal v-model:visible="modalVisible" :title="isEditing ? $t('general.edit') : $t('general.add')" size="small">
      <div class="flex flex-col gap-4 py-2">
        <div>
          <div class="text-sm mb-1">{{ $t('labels.key') }}</div>
          <a-input
            v-model:value="editingVariable.key"
            :disabled="isEditing"
            placeholder="MY_VARIABLE"
            data-testid="base-variables-key-input"
          />
          <div class="text-xs text-nc-content-gray-muted mt-1">
            {{ $t('msg.info.baseVariableKeyFormat') }}
          </div>
        </div>
        <div>
          <div class="text-sm mb-1">{{ $t('labels.value') }}</div>
          <a-input-password
            v-if="editingVariable.type === BaseVariableValueType.SECRET"
            v-model:value="editingVariable.value"
            data-testid="base-variables-value-input"
          />
          <a-input
            v-else
            v-model:value="editingVariable.value"
            data-testid="base-variables-value-input"
          />
        </div>
        <div>
          <div class="text-sm mb-1">{{ $t('labels.type') }}</div>
          <NcSelect
            v-model:value="editingVariable.type"
            :options="[
              { label: 'text', value: BaseVariableValueType.TEXT },
              { label: 'secret', value: BaseVariableValueType.SECRET },
            ]"
            :disabled="isEditing"
            data-testid="base-variables-type-select"
          />
        </div>
        <div>
          <div class="text-sm mb-1">{{ $t('labels.description') }}</div>
          <a-textarea v-model:value="editingVariable.description" :rows="2" data-testid="base-variables-description-input" />
        </div>
        <div class="flex justify-end gap-2">
          <NcButton size="small" @click="modalVisible = false">{{ $t('general.cancel') }}</NcButton>
          <NcButton type="primary" size="small" :loading="isSaving" data-testid="base-variables-save" @click="saveVariable">
            {{ isEditing ? $t('general.save') : $t('general.create') }}
          </NcButton>
        </div>
      </div>
    </NcModal>
  </div>
</template>
