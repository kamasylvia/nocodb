<script setup lang="ts">
// [CE-EE] F10: dashboard page — minimal titled container. Widget rendering
// lands with the widget layer.
const route = useRoute()
const { $api } = useNuxtApp()

const dashboard = ref<Record<string, any> | null>(null)
const isLoading = ref(true)

onMounted(async () => {
  try {
    const res = await $api.instance.get(
      `/api/v2/meta/bases/${route.params.baseId}/dashboards/${route.params.dashboardId}`,
    )
    dashboard.value = res.data
  } catch (e: any) {
    message.error(await extractSdkResponseErrorMsg(e))
  } finally {
    isLoading.value = false
  }
})
</script>

<template>
  <div class="nc-dashboard-page h-full flex flex-col p-6">
    <div v-if="isLoading" class="flex-1 flex items-center justify-center">
      <GeneralLoader />
    </div>
    <template v-else-if="dashboard">
      <div class="mb-4">
        <h1 class="text-xl font-weight-700" data-testid="dashboard-title">{{ dashboard.title }}</h1>
        <p v-if="dashboard.description" class="text-sm text-nc-content-gray-subtle mt-1">
          {{ dashboard.description }}
        </p>
      </div>
      <div class="flex-1 flex items-center justify-center border-1 border-dashed border-nc-border-gray-medium rounded-lg text-sm text-nc-content-gray-subtle">
        {{ $t('msg.info.dashboardEmpty') }}
      </div>
    </template>
  </div>
</template>
