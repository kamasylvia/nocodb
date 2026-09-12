import { ProjectRoles } from 'nocodb-sdk'
import { rolePermissions } from '~/lib/acl'

// [CE-EE] F05: base variables management is gated to creator+ — the frontend
// ACL must expose the four baseVariable* permissions for creators (the backend
// grants them via the exclude-based creator role), and must NOT expose them to
// editor/viewer/commenter include lists.

const VARIABLE_OPS = [
  'baseVariableList',
  'baseVariableCreate',
  'baseVariableUpdate',
  'baseVariableDelete',
]

describe('base variables ACL gating (F05)', () => {
  it('grants all baseVariable* ops to base creators', () => {
    const creatorInclude = (rolePermissions as any)[ProjectRoles.CREATOR].include
    for (const op of VARIABLE_OPS) {
      expect(creatorInclude[op]).toBe(true)
    }
  })

  it('does not hand the ops to lower base roles via include lists', () => {
    for (const role of [ProjectRoles.EDITOR, ProjectRoles.COMMENTER, ProjectRoles.VIEWER]) {
      const include = (rolePermissions as any)?.[role]?.include
      if (!include) continue
      for (const op of VARIABLE_OPS) {
        expect(include[op]).toBeUndefined()
      }
    }
  })
})
