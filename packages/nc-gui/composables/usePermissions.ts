import {
  getPermissionIcon,
  getPermissionLabel,
  getPermissionOption,
  PermissionOptions,
  PermissionOptionValue,
  PermissionEntity,
  PermissionKey,
  PermissionRole,
  PermissionRoleMap,
  PermissionRolePower,
} from 'nocodb-sdk'
import { evaluateTableFieldPermission } from '~/utils/tableFieldPermission'

// Re-export the interface from SDK for backward compatibility
export type { PermissionOption } from 'nocodb-sdk'

// [CE-EE] F02: real permission resolution. Base permission grants are fetched
// once per base (lazily) and consumed reactively; the grant decision is the
// shared rule in utils/tableFieldPermission (same as the backend), so the two
// sides can never drift. No grant for an entity = allowed (fail-open).

const ROLE_VALUE_TO_OPTION: Record<string, PermissionOptionValue> = {
  [PermissionRole.VIEWER]: PermissionOptionValue.VIEWERS_AND_UP,
  [PermissionRole.COMMENTER]: PermissionOptionValue.COMMENTERS_AND_UP,
  [PermissionRole.EDITOR]: PermissionOptionValue.EDITORS_AND_UP,
  [PermissionRole.CREATOR]: PermissionOptionValue.CREATORS_AND_UP,
  [PermissionRole.OWNER]: PermissionOptionValue.CREATORS_AND_UP,
}

export const usePermissions = () => {
  // Use centralized permission options from SDK
  const permissionOptions = PermissionOptions

  const { user } = useGlobal()
  const { baseRoles } = useRoles()
  const { base } = storeToRefs(useBase())

  const baseId = computed(() => base.value?.id)

  const permissions = useState<any[]>(() => [])

  const loadedFor = useState<string | null>(
    'nc-permissions-loaded-for',
    () => null,
  )

  const loadPermissions = async (force = false) => {
    // [CE-EE] F02 R2: force bypasses the per-base guard so callers that just
    // wrote grants (dialog save/delete) always refetch — otherwise the guard
    // made the post-save refetch a no-op and the UI served stale grants
    if (!force && loadedFor.value === baseId.value) return
    if (!baseId.value) return
    loadedFor.value = baseId.value
    try {
      const { $api } = useNuxtApp()
      const res = await $api.instance.get(
        `/api/v2/meta/bases/${baseId.value}/permissions`,
      )
      permissions.value = res.data ?? []
    } catch (e) {
      loadedFor.value = null
    }
  }

  // lazy-load once per base — consumers are reactive, so grants arriving
  // after first render simply re-evaluate the dependent computeds
  if (baseId.value && loadedFor.value !== baseId.value) {
    void loadPermissions()
  }

  // base switch: drop stale grants immediately (fail-open until refetched)
  watch(baseId, (nv, ov) => {
    if (nv && nv !== ov) {
      permissions.value = []
      loadedFor.value = null
      void loadPermissions()
    }
  })

  // Permissions data grouped by entity — key shape `${entity}:${entityId}`
  const permissionsByEntity = computed<Record<string, any[]>>(() => {
    const map: Record<string, any[]> = {}
    for (const p of permissions.value) {
      const key = `${p.entity}:${p.entity_id}`
      ;(map[key] = map[key] ?? []).push(p)
    }
    return map
  })

  const grantsFor = (
    entity: PermissionEntity,
    entityId: string,
    permissionType: PermissionKey,
  ): any[] => {
    const key = `${entity}:${entityId}`
    return (permissionsByEntity.value[key] ?? []).filter(
      (p) => p.permission === permissionType,
    )
  }

  // current user's most powerful base role, mapped to the SDK PermissionRole
  const currentUserPermissionRole = computed<PermissionRole | undefined>(() => {
    const rolesObj = baseRoles.value ?? {}
    let best: PermissionRole | undefined
    let bestPower = -1
    for (const [role, has] of Object.entries(rolesObj)) {
      if (!has) continue
      const mapped = PermissionRoleMap[role as keyof typeof PermissionRoleMap]
      const power = mapped
        ? PermissionRolePower[mapped as keyof typeof PermissionRolePower]
        : undefined
      if (power !== undefined && power > bestPower) {
        bestPower = power
        best = mapped as PermissionRole
      }
    }
    return best
  })

  // Get permission summary for an entity (returns internal value)
  const getPermissionSummary = (
    entity: PermissionEntity,
    entityId: string,
    permissionType: PermissionKey,
  ): PermissionOptionValue => {
    const grants = grantsFor(entity, entityId, permissionType)
    if (!grants.length) {
      // no grant = default behaviour (editors and up can edit)
      return PermissionOptionValue.EDITORS_AND_UP
    }
    const grant = grants[0]
    if (grant.granted_type === 'nobody') {
      return PermissionOptionValue.NOBODY
    }
    if (grant.granted_type === 'user') {
      return PermissionOptionValue.SPECIFIC_USERS
    }
    return ROLE_VALUE_TO_OPTION[grant.granted_role] ?? PermissionOptionValue.EDITORS_AND_UP
  }

  // Get permission summary with display label
  const getPermissionSummaryLabel = (entity: string, entityId: string, permissionType: string) => {
    const internalValue = getPermissionSummary(entity as PermissionEntity, entityId, permissionType as PermissionKey)
    return getPermissionLabel(internalValue)
  }

  const isAllowed = (
    entity: PermissionEntity,
    entityId: string,
    permission: PermissionKey,
    opts: { isFormView?: boolean } = {},
  ): boolean => {
    if (!entityId) return true

    // [CE-EE] F02 R1: base owners always pass — keep frontend in sync with
    // the backend checkPermission/isAllowed owner shortcut
    if (currentUserPermissionRole.value === PermissionRole.OWNER) return true

    const grants = grantsFor(entity, entityId, permission)
    if (!grants.length) return true

    const grant = grants[0]

    // form submissions may opt out of enforcement per grant
    if (opts?.isFormView && grant.enforce_for_form === false) {
      return true
    }

    return evaluateTableFieldPermission(grant, {
      userId: user.value?.id,
      permissionRole: currentUserPermissionRole.value,
    })
  }

  const getPermissionColor = (..._args: any[]): string => {
    return 'gray'
  }

  const getPermissionTextColor = (..._args: any[]): string => {
    return 'text-gray-700'
  }

  return {
    permissionOptions,
    permissions,
    permissionsByEntity,
    loadPermissions,
    getPermissionOption,
    getPermissionLabel,
    getPermissionIcon,
    getPermissionColor,
    getPermissionTextColor,
    getPermissionSummary,
    getPermissionSummaryLabel,
    isAllowed,
  }
}
