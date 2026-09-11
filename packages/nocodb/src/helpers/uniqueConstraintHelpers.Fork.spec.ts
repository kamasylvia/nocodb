import { UITypes } from 'nocodb-sdk';
import type { NcContext } from '~/interface/config';
import {
  normalizeUniqueConstraintFlag,
  normalizeValueForUniqueCheck,
  validateUniqueConstraint,
} from '~/helpers/uniqueConstraintHelpers';

// [CE-EE] F01: unit tests for the unique-values-only validation helpers
// (file suffix matches jest testRegex '(Integration|Source|Fork)\.spec\.ts$')

const ctx = {} as NcContext;

describe('uniqueConstraintHelpers', () => {
  describe('validateUniqueConstraint', () => {
    it('passes when unique is not requested', () => {
      expect(() =>
        validateUniqueConstraint(ctx, UITypes.SingleLineText, undefined, false),
      ).not.toThrow();
      expect(() =>
        validateUniqueConstraint(ctx, UITypes.SingleLineText, undefined, undefined),
      ).not.toThrow();
    });

    it('rejects unique on non NC-DB sources', () => {
      const externalSource = { is_local: false, is_meta: false, type: 'pg' };
      expect(() =>
        validateUniqueConstraint(
          ctx,
          UITypes.SingleLineText,
          undefined,
          true,
          externalSource as any,
        ),
      ).toThrow(/NC-DB/);
    });

    it('rejects unique on sqlite sources (client value sqlite3)', () => {
      // [CE-EE] R4: regression guard — the runtime client value is 'sqlite3'
      for (const type of ['sqlite', 'sqlite3']) {
        expect(() =>
          validateUniqueConstraint(
            ctx,
            UITypes.SingleLineText,
            undefined,
            true,
            { is_local: true, is_meta: false, type } as any,
          ),
        ).toThrow(/SQLite/);
      }
    });

    it('allows unique on local/meta sources', () => {
      expect(() =>
        validateUniqueConstraint(
          ctx,
          UITypes.SingleLineText,
          undefined,
          true,
          { is_local: true, is_meta: false, type: 'pg' } as any,
        ),
      ).not.toThrow();
      expect(() =>
        validateUniqueConstraint(
          ctx,
          UITypes.SingleLineText,
          undefined,
          true,
          { is_local: false, is_meta: true, type: 'pg' } as any,
        ),
      ).not.toThrow();
    });

    it('rejects unsupported field types', () => {
      expect(() =>
        validateUniqueConstraint(ctx, UITypes.Attachment, undefined, true),
      ).toThrow(/not supported for field type 'Attachment'/);
    });

    it('rejects rich long text (and LongText generally, not in supported list)', () => {
      expect(() =>
        validateUniqueConstraint(ctx, UITypes.LongText, { richMode: true }, true),
      ).toThrow(/not supported for field type 'LongText'/);
    });

    it('rejects unique when a default value is set', () => {
      expect(() =>
        validateUniqueConstraint(ctx, UITypes.SingleLineText, undefined, true, undefined, 'abc'),
      ).toThrow(/default value is set/);
    });

    it('allows UUID fields to combine unique with generated defaults', () => {
      expect(() =>
        validateUniqueConstraint(ctx, UITypes.UUID, undefined, true, undefined, 'gen_random_uuid()'),
      ).not.toThrow();
    });

    it('allows supported field types without defaults', () => {
      for (const uidt of [
        UITypes.SingleLineText,
        UITypes.Email,
        UITypes.PhoneNumber,
        UITypes.URL,
        UITypes.Number,
        UITypes.Decimal,
        UITypes.Currency,
        UITypes.Percent,
        UITypes.Date,
        UITypes.DateTime,
        UITypes.Time,
      ]) {
        expect(() => validateUniqueConstraint(ctx, uidt, undefined, true)).not.toThrow();
      }
    });
  });

  describe('normalizeUniqueConstraintFlag', () => {
    it('passes booleans and absence through', () => {
      expect(normalizeUniqueConstraintFlag(ctx, true)).toBe(true);
      expect(normalizeUniqueConstraintFlag(ctx, false)).toBe(false);
      expect(normalizeUniqueConstraintFlag(ctx, undefined)).toBeUndefined();
      expect(normalizeUniqueConstraintFlag(ctx, null)).toBeUndefined();
    });

    it('rejects truthy strings like "false" that would flip the constraint on', () => {
      expect(() => normalizeUniqueConstraintFlag(ctx, 'false')).toThrow(/boolean/);
      expect(() => normalizeUniqueConstraintFlag(ctx, 'true')).toThrow(/boolean/);
      expect(() => normalizeUniqueConstraintFlag(ctx, 1)).toThrow(/boolean/);
      expect(() => normalizeUniqueConstraintFlag(ctx, 0)).toThrow(/boolean/);
    });
  });

  describe('normalizeValueForUniqueCheck', () => {
    it('treats empty values as null', () => {
      expect(normalizeValueForUniqueCheck(null, UITypes.SingleLineText)).toBeNull();
      expect(normalizeValueForUniqueCheck(undefined, UITypes.SingleLineText)).toBeNull();
      expect(normalizeValueForUniqueCheck('', UITypes.SingleLineText)).toBeNull();
    });

    it('trims and lowercases text-based field values', () => {
      expect(normalizeValueForUniqueCheck('  Foo Bar ', UITypes.SingleLineText)).toBe('foo bar');
      expect(normalizeValueForUniqueCheck('A@B.COM', UITypes.Email)).toBe('a@b.com');
    });

    it('keeps non-text values as-is', () => {
      expect(normalizeValueForUniqueCheck(42, UITypes.Number)).toBe(42);
    });
  });
});
