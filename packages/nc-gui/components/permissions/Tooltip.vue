<script lang="ts" setup>
import type { PermissionEntity, PermissionKey } from 'nocodb-sdk'
import type { TooltipPlacement } from 'ant-design-vue/lib/tooltip'

interface Props {
  entity: PermissionEntity
  entityId?: string // required for permission check otherwise it will always return true
  permission: PermissionKey
  title?: string
  description?: string
  placement?: TooltipPlacement
  showIcon?: boolean
  showOverlay?: boolean
  defaultTooltip?: string
  showPointerEventNone?: boolean
  disabled?: boolean
  arrow?: boolean
}

// [CE-EE] F02: wire to the real permission resolution — without an entityId
// the check is meaningless, so keep allow-all in that case (stub behaviour)
const props = defineProps<Props>()

const { isAllowed: isPermissionAllowed } = usePermissions()

const isAllowed = computed(() => {
  if (!props.entityId) return true
  return isPermissionAllowed(props.entity, props.entityId, props.permission)
})
</script>

<template>
  <slot :is-allowed="isAllowed" />
</template>
