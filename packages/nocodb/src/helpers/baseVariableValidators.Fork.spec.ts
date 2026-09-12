/**
 * [CE-EE] F05: unit tests for the base variable validation/masking helpers
 * (pure logic — no DB/Nest required, sdk-only import chain).
 * (file suffix matches jest testRegex '(Integration|Source|Fork)\.spec\.ts$')
 */
import { BaseVariableValueType } from 'nocodb-sdk';
import {
  BaseVariableValidationError,
  maskSecretVariable,
  validateVariableKey,
  validateVariableType,
  validateVariableValue,
} from '~/helpers/baseVariableValidators';

describe('baseVariableValidators (F05)', () => {
  describe('validateVariableValue', () => {
    it('accepts strings and passes them through', () => {
      expect(validateVariableValue('hello')).toBe('hello');
    });

    it('treats null/undefined as not-provided', () => {
      expect(validateVariableValue(undefined)).toBeUndefined();
      expect(validateVariableValue(null)).toBeUndefined();
    });

    it('rejects non-string values that used to bypass the 64KB check', () => {
      const bigObject: any = { length: undefined };
      for (let i = 0; i < 70000; i++) bigObject[`k${i}`] = i;
      expect(() => validateVariableValue(bigObject)).toThrow(/string/i);
      expect(() => validateVariableValue(42)).toThrow(/string/i);
    });

    it('enforces the 64KB limit precisely', () => {
      expect(() => validateVariableValue('x'.repeat(65537))).toThrow(/64KB/);
      expect(validateVariableValue('x'.repeat(65536))).toHaveLength(65536);
    });
  });

  describe('validateVariableType', () => {
    it('accepts whitelisted types', () => {
      expect(validateVariableType('text')).toBe('text');
      expect(validateVariableType('secret')).toBe('secret');
    });

    it('passes undefined/null through (create falls back to text)', () => {
      expect(validateVariableType(undefined)).toBeUndefined();
      expect(validateVariableType(null)).toBeUndefined();
    });

    it('rejects unknown and non-string types', () => {
      expect(() => validateVariableType('weird')).toThrow(/type must be/);
      expect(() => validateVariableType('Secret')).toThrow(/type must be/);
      expect(() => validateVariableType(123 as any)).toThrow(/type must be/);
    });
  });

  describe('validateVariableKey', () => {
    it('rejects missing keys', () => {
      expect(() => validateVariableKey(undefined)).toThrow(/required/);
      expect(() => validateVariableKey('')).toThrow(/required/);
    });

    it('rejects keys over 255 chars', () => {
      expect(() => validateVariableKey('K'.repeat(256))).toThrow(
        /255 characters/,
      );
      expect(validateVariableKey('K'.repeat(255))).toHaveLength(255);
    });
  });

  describe('maskSecretVariable', () => {
    it('strips value and default_value from secret variables', () => {
      const masked = maskSecretVariable({
        key: 'S',
        type: BaseVariableValueType.SECRET,
        value: 'plain',
        default_value: 'plain-default',
      });
      expect(masked.value).toBeUndefined();
      expect(masked.default_value).toBeUndefined();
    });

    it('leaves text variables untouched', () => {
      const masked = maskSecretVariable({
        key: 'T',
        type: BaseVariableValueType.TEXT,
        value: 'visible',
      });
      expect(masked.value).toBe('visible');
    });
  });

  describe('BaseVariableValidationError', () => {
    it('is the error type thrown by validators', () => {
      expect(() => validateVariableType('weird')).toThrowError(
        BaseVariableValidationError,
      );
    });
  });
});
