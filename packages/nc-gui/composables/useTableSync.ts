// [CE-EE] F09: minimal reactive access to a table's sync record (P1).
// A synced table has exactly one owning sync — located via the main mapping
// (dest_table_id). Used by the tree node sync menu and the status badge.
import type { TableSyncType } from 'nocodb-sdk'

export function useTableSync(baseId: string, tableId: string) {
  const { $api } = useNuxtApp()

  const sync = ref<TableSyncType | null>(null)
  const isLoading = ref(false)
  const isUpdating = ref(false)

  const findSyncForTable = async (): Promise<TableSyncType | null> => {
    const res = await $api.instance.get(
      `/api/v2/meta/bases/${baseId}/table-syncs`,
    )
    const syncs: TableSyncType[] = res.data ?? []
    return (
      syncs.find((s) =>
        (s.mappings || []).some(
          (m) => m.dest_table_id === tableId && m.role === 'main',
        ),
      ) ?? null
    )
  }

  const load = async () => {
    if (!baseId || !tableId) return
    isLoading.value = true
    try {
      sync.value = await findSyncForTable()
    } catch {
      sync.value = null
    } finally {
      isLoading.value = false
    }
  }

  const withUpdate = async (fn: () => Promise<unknown>) => {
    isUpdating.value = true
    try {
      await fn()
      await load()
    } catch (e: any) {
      message.error(await extractSdkResponseErrorMsg(e))
    } finally {
      isUpdating.value = false
    }
  }

  const syncNow = () =>
    withUpdate(() =>
      $api.instance.post(
        `/api/v2/meta/bases/${baseId}/table-syncs/${sync.value?.id}/resync`,
      ),
    )

  const freeze = () =>
    withUpdate(() =>
      $api.instance.post(
        `/api/v2/meta/bases/${baseId}/table-syncs/${sync.value?.id}/freeze`,
      ),
    )

  const resume = () =>
    withUpdate(() =>
      $api.instance.post(
        `/api/v2/meta/bases/${baseId}/table-syncs/${sync.value?.id}/resume`,
      ),
    )

  const remove = () =>
    withUpdate(() =>
      $api.instance.delete(
        `/api/v2/meta/bases/${baseId}/table-syncs/${sync.value?.id}`,
      ),
    )

  onMounted(load)

  return { sync, isLoading, isUpdating, load, syncNow, freeze, resume, remove }
}
