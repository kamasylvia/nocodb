import { BaseVariableValueType } from 'nocodb-sdk';

// [CE-EE] F05: pure validation/masking helpers for base variables.
// Kept dependency-light (sdk only) so they are unit-testable in isolation
// without pulling the Nest/model import graph (ESM-only transitive deps).

export const ALLOWED_VARIABLE_TYPES = Object.values(
  BaseVariableValueType,
) as string[];
export const MAX_VARIABLE_VALUE_LENGTH = 65536; // 64KB, mirrors the model limit
export const MAX_VARIABLE_KEY_LENGTH = 255; // mirrors nc_base_variables.key

export class BaseVariableValidationError extends Error {}

export function validateVariableKey(key: unknown): string {
  if (!key || typeof key !== 'string') {
    throw new BaseVariableValidationError('Variable key is required');
  }
  if (key.length > MAX_VARIABLE_KEY_LENGTH) {
    throw new BaseVariableValidationError(
      `Variable key exceeds ${MAX_VARIABLE_KEY_LENGTH} characters limit`,
    );
  }
  return key;
}

export function validateVariableValue(value: unknown): string | undefined {
  if (value === undefined || value === null) return undefined;
  // objects/arrays have no meaningful .length and used to bypass the 64KB
  // check — enforce the string type explicitly
  if (typeof value !== 'string') {
    throw new BaseVariableValidationError('Variable value must be a string');
  }
  if (value.length > MAX_VARIABLE_VALUE_LENGTH) {
    throw new BaseVariableValidationError('Variable value exceeds 64KB limit');
  }
  return value;
}

export function validateVariableType(
  type: unknown,
): BaseVariableValueType | undefined {
  // non-string types are rejected instead of silently falling back to text
  if (type === undefined || type === null) return undefined;
  if (typeof type !== 'string' || !ALLOWED_VARIABLE_TYPES.includes(type)) {
    throw new BaseVariableValidationError(
      `Variable type must be one of: ${ALLOWED_VARIABLE_TYPES.join(', ')}`,
    );
  }
  return type as BaseVariableValueType;
}

export function maskSecretVariable<
  T extends { type?: string; value?: string | null; default_value?: string | null },
>(variable: T): T {
  if (variable.type === BaseVariableValueType.SECRET) {
    // default_value carries secret material too (the model decrypts it in
    // prepareForRead) — strip both fields
    return { ...variable, value: undefined, default_value: undefined };
  }
  return variable;
}
