import type { DashboardType } from 'nocodb-sdk'

export const useDashboardStore = defineStore('dashboard', () => {
  // State
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
    const res = await $api.instance.get(`/api/v2/meta/bases/${baseId}/dashboards/${dashboardId}`)
    const d = res.data
    dashboards.value.set(d.id, d)
    return d
  }

  const createDashboard = async (baseId: string, body: { title: string; description?: string }) => {
    const res = await $api.instance.post(`/api/v2/meta/bases/${baseId}/dashboards`, body)
    dashboards.value.set(res.data.id, res.data)
    return res.data
  }

  const updateDashboard = async (baseId: string, dashboardId: string, body: { title?: string; description?: string }) => {
    const res = await $api.instance.patch(`/api/v2/meta/bases/${baseId}/dashboards/${dashboardId}`, body)
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
    await navigateTo(`/${wsId}/${dashboardId}`)
  }

  const duplicateDashboard = async (..._params: any) => null

  async function openNewDashboardModal(params: { baseId?: string }) {
    const baseId = params?.baseId || (route.value.params.baseId as string)
    if (!baseId) return

    // [CE-EE] F10 minimal: create with a default title (Dashboard / Dashboard 2 / ...)
    // — title editing lands with the dashboard page
    const n = dashboards.value.size + 1
    const dashboard = await createDashboard(baseId, {
      title: `Dashboard ${n}`,
    })
    message.success('Dashboard created')
    await openDashboard(dashboard.id)
  }

  return {
    // State
    dashboards,
    activeDashboard,

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
