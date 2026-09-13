<script setup lang="ts">
// [CE-EE] F08: base type management panel (replaces the CE stub) — toggle a
// base between workspace-shared and invite-only private.
const { $api } = useNuxtApp()
const { t } = useI18n()

const baseStore = useBase()
const { base } = storeToRefs(baseStore)
const { isUIAllowed } = useRoles()

const canManage = computed(() => isUIAllowed('manageBaseType'))
const isPrivate = computed(() => !!(base.value as any)?.is_private)
const isUpdating = ref(false)

const options = computed(() => [
  {
    value: false,
    title: t('labels.workspace'),
    description: t('title.baseTypeSettingsDefaultSubtext'),
  },
  {
    value: true,
    title: t('title.privateBase'),
    description: t('title.baseTypeSettingsPrivateSubtext'),
  },
])

const selectType = async (val: boolean) => {
  if (!canManage.value || isUpdating.value || val === isPrivate.value) return
  if (!base.value?.id) return

  isUpdating.value = true
  try {
    await $api.instance.patch(`/api/v2/meta/bases/${base.value.id}`, {
      is_private: val,
    })
    ;(base.value as any).is_private = val
    message.success(
      val
        ? t('msg.info.baseTypeChangedToPrivate')
        : t('msg.info.baseTypeChangedToWorkspace'),
    )
  } catch (e: any) {
    message.error(await extractSdkResponseErrorMsg(e))
  } finally {
    isUpdating.value = false
  }
}
</script>

<template>
  <div class="nc-base-type-settings max-w-150">
    <div class="text-lg font-bold text-nc-content-gray-emergency">
      {{ $t('general.baseType') }}
    </div>
    <div class="text-sm text-nc-content-gray-subtle mt-1">
      {{ $t('title.baseTypeTabSubtext') }}
    </div>

    <div class="mt-6 flex flex-col gap-4" role="radiogroup">
      <div
        v-for="opt of options"
        :key="String(opt.value)"
        v-e="['a:base:type-select']"
        class="rounded-xl border p-4 flex items-start gap-3 cursor-pointer transition-colors"
        :class="
          opt.value === isPrivate
            ? 'border-nc-border-brand bg-nc-bg-gray-extralight'
            : 'border-nc-border-gray-200 hover:bg-nc-bg-gray-extralight'
        "
        :aria-checked="opt.value === isPrivate"
        :aria-disabled="!canManage"
        role="radio"
        :data-testid="`nc-base-type-${opt.value ? 'private' : 'workspace'}`"
        @click="selectType(opt.value)"
      >
        <div
          class="mt-1 w-4 h-4 rounded-full border-2 flex items-center justify-center flex-shrink-0"
          :class="
            opt.value === isPrivate
              ? 'border-nc-border-brand'
              : 'border-nc-border-gray-400'
          "
        >
          <div
            v-if="opt.value === isPrivate"
            class="w-2 h-2 rounded-full bg-nc-fill-brand"
          />
        </div>

        <div class="flex flex-col gap-1 min-w-0">
          <div class="font-medium text-nc-content-gray-emergency">
            {{ opt.title }}
          </div>
          <div class="text-sm text-nc-content-gray-subtle">
            {{ opt.description }}
          </div>
        </div>

        <GeneralIcon
          v-if="isUpdating && opt.value === isPrivate"
          icon="reload"
          class="animate-spin text-nc-content-gray-muted ml-auto"
        />
      </div>
    </div>
  </div>
</template>
