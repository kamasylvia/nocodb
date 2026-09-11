import { UITypes } from 'nocodb-sdk'
import { canEnableUniqueConstraint, isUniqueConstraintSupportedType } from '~/utils/uniqueConstraintHelpers'

// [CE-EE] F01 Unique values only: gate helpers must keep the column-edit toggle
// available for supported types on NC-DB sources and disabled elsewhere.

describe('uniqueConstraintHelpers', () => {
  describe('canEnableUniqueConstraint', () => {
    it('enables for supported type on NC-DB base', () => {
      expect(canEnableUniqueConstraint({ uidt: UITypes.SingleLineText } as any, true)).toEqual({
        canEnable: true,
      })
    })

    it('disables on external sources with reason', () => {
      const res = canEnableUniqueConstraint({ uidt: UITypes.SingleLineText } as any, false)
      expect(res.canEnable).toBe(false)
      expect(res.reason).toMatch(/NC-DB/)
    })

    it('disables for unsupported field types', () => {
      const res = canEnableUniqueConstraint({ uidt: UITypes.Attachment } as any, true)
      expect(res.canEnable).toBe(false)
      expect(res.reason).toMatch(/Attachment/)
    })

    it('disables when a default value is set', () => {
      const res = canEnableUniqueConstraint({ uidt: UITypes.Number, cdf: '5' } as any, true)
      expect(res.canEnable).toBe(false)
      expect(res.reason).toMatch(/default value/)
    })

    it('ignores empty-string defaults', () => {
      expect(canEnableUniqueConstraint({ uidt: UITypes.Number, cdf: '' } as any, true).canEnable).toBe(true)
    })
  })

  describe('isUniqueConstraintSupportedType', () => {
    it('accepts supported scalar types', () => {
      for (const uidt of [UITypes.SingleLineText, UITypes.Email, UITypes.Number, UITypes.DateTime, UITypes.UUID]) {
        expect(isUniqueConstraintSupportedType(uidt)).toBe(true)
      }
    })

    it('rejects virtual and binary types', () => {
      for (const uidt of [UITypes.Attachment, UITypes.Lookup, UITypes.Rollup, UITypes.Checkbox]) {
        expect(isUniqueConstraintSupportedType(uidt)).toBe(false)
      }
    })

    it('rejects LongText in both plain and rich mode (not in supported list)', () => {
      expect(isUniqueConstraintSupportedType(UITypes.LongText, { richMode: true })).toBe(false)
      expect(isUniqueConstraintSupportedType(UITypes.LongText, {})).toBe(false)
    })
  })
})
