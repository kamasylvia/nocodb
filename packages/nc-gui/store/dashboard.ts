import type { DashboardType } from 'nocodb-sdk'

export const useDashboardStore = defineStore('dashboard', () => {
  // State
  const { $api } = useNuxtApp()

  const dashboards = ref(new Map<string, DashboardType>())
  const router = useRouter()
  const route = router.currentRoute

  const activeBaseId = computed(() => route.value.params.baseId as string)

  const activeBaseDashboards = computed(() =>
    [...dashboards.value.values()].filter((d) => d.base_id === activeBaseId.value),
  )

  const loadDashboards = async (baseId: string) => {
    const res = await $api.instance.get(`/api/v2/meta/bases/${baseId}/dashboards`)
    for (const d of res.data ?? []) {
      dashboards.value.set(d.id, d)
    }
    return res.data
  }

  const loadDashboard = async (baseId: string, dashboardId: string) => {
    const res = await $api.instance.get(
      `/api/v2/meta/bases/${baseId}/dashboards/${dashboardId}`,
    )
    const d = res.data
    dashboards.value.set(d.id, d)
    return d
  }

  const createDashboard = async (baseId: string, body: { title: string; description?: string }) => {
    const res = await $api.instance.post(`/api/v2/meta/bases/${baseId}/dashboards`, body)
    dashboards.value.set(res.data.id, res.data)
    return res.data
  }

  const updateDashboard = async (
    baseId: string,
    dashboardId: string,
    body: { title?: string; description?: string },
  ) => {
    const res = await $api.instance.patch(
      `/api/v2/meta/bases/${baseId}/dashboards/${dashboardId}`,
      body,
    )
    dashboards.value.set(res.data.id, res.data)
    return res.data
  }

  const deleteDashboard = async (baseId: string, dashboardId: string) => {
    await $api.instance.delete(`/api/v2/meta/bases/${baseId}/dashboards/${dashboardId}`)
    dashboards.value.delete(dashboardId)
    return true
  }

  const openDashboard = async (dashboardId: string) => {
    const wsId = route.value.params.typeOrId as string
    const baseId = route.value.params.baseId as string
    await navigateTo(`/${wsId}/${baseId}/dashboard/${dashboardId}`)
  }

  const duplicateDashboard = async (..._params: any) => null

  async function openNewDashboardModal(params: { baseId?: string }) {
    const baseId = params?.baseId || (route.value.params.baseId as string)
    if (!baseId) return

    // [CE-EE] F10: default title avoids the per-base unique-title constraint;
    // pick the first non-colliding "Dashboard N" instead of a fixed count
    let n = 1
    const titles = new Set([...dashboards.value.values()].map((d) => d.title))
    while (titles.has(`Dashboard ${n}`)) n++
    const title = `Dashboard ${n}`

    try {
      const dashboard = await createDashboard(baseId, { title })
      message.success('Dashboard created')
      await navigateTo(`/${route.value.params.typeOrId}/${baseId}/dashboard/${dashboard.id}`)
    } catch (e: any) {
      message.error(await extractSdkResponseErrorMsg(e))
    }
  }

  return {
    // State
    dashboards,

    // Getters
    activeBaseDashboards,

    // Actions
    loadDashboards,
    loadDashboard,
    createDashboard,
    updateDashboard,
    deleteDashboard,
    openDashboard,
    duplicateDashboard,
    openNewDashboardModal,
  }
})

// Enable HMR
if (import.meta.hot) {
  import.meta.hot.accept(acceptHMRUpdate(useDashboardStore, import.meta.hot))
}
