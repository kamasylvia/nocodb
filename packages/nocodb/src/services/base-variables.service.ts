import { Injectable } from '@nestjs/common';
import { BaseVariableValueType } from 'nocodb-sdk';
import type { BaseVariableType } from 'nocodb-sdk';
import type { NcContext } from '~/interface/config';
import BaseVariable from '~/models/BaseVariable';
import { NcError } from '~/helpers/catchError';
import { isUniqueViolation } from '~/helpers/isUniqueViolation';
import { getCredentialEncryptSecret } from '~/utils/encryptDecrypt';
import {
  BaseVariableValidationError,
  maskSecretVariable,
  validateVariableKey,
  validateVariableType,
  validateVariableValue,
} from '~/helpers/baseVariableValidators';

// [CE-EE] F05: base variables management — the BaseVariable model ships
// complete in CE (validation, secret encryption, cache, ordering); this
// service exposes it over the meta API.

@Injectable()
export class BaseVariablesService {
  async list(context: NcContext, baseId: string) {
    const variables = await BaseVariable.list(context, baseId);

    // Mask secret material in list responses; the decrypted value is only
    // served by the single-variable get (creator-gated anyway).
    return variables.map((v) => maskSecretVariable(v));
  }

  async get(context: NcContext, baseId: string, variableId: string) {
    await this.getVariableWithBaseCheck(context, baseId, variableId);
    const variable = await BaseVariable.get(context, variableId);
    return variable;
  }

  async create(
    context: NcContext,
    baseId: string,
    body: Partial<BaseVariableType>,
  ) {
    // [CE-EE] F05 R1: build the payload explicitly — request bodies must not
    // be able to inject internal columns (base_id/default_value/order/
    // inheritance/override flags) or bypass field validation.
    const type = this.safeValidate(() => validateVariableType(body.type));
    const value = this.safeValidate(() => validateVariableValue(body.value));
    const key = this.safeValidate(() => validateVariableKey(body.key));
    // [CE-EE] F05 R4: same contract as update — objects would be stored as
    // dirty JSON strings by the pg driver and errored on mysql
    if (
      body.description !== undefined &&
      body.description !== null &&
      typeof body.description !== 'string'
    ) {
      NcError.badRequest('Variable description must be a string');
    }
    const description =
      body.description === null ? null : (body.description as string);

    // [CE-EE] F05 R3: insert writes secret material when the (resolved) type
    // is secret — guard regardless of whether a value was provided
    if ((type || BaseVariableValueType.TEXT) === BaseVariableValueType.SECRET) {
      this.ensureEncryptionAvailable();
    }
    await this.validateUniqueKey(context, key);
    try {
      return await BaseVariable.insert(context, {
        base_id: baseId,
        key,
        value,
        description,
        type: type || BaseVariableValueType.TEXT,
      });
    } catch (e: any) {
      // [CE-EE] F05 R1: two creators racing on the same key fall through to
      // the DB unique constraint — surface it as the same 400 the
      // pre-check produces instead of a 500.
      if (isUniqueViolation(e)) {
        NcError.badRequest(`Variable key ${key} already exists in this base`);
      }
      throw e;
    }
  }

  async update(
    context: NcContext,
    baseId: string,
    variableId: string,
    body: Partial<BaseVariableType>,
  ) {
    const existing = await this.getVariableWithBaseCheck(
      context,
      baseId,
      variableId,
    );

    // key is immutable — it is the variable's identifier across consumers
    if (body.key !== undefined && body.key !== existing.key) {
      NcError.badRequest('Variable key cannot be changed. Delete and recreate');
    }

    const type =
      body.type !== undefined
        ? this.safeValidate(() => validateVariableType(body.type))
        : undefined;
    // [CE-EE] F05 R2: REST PATCH semantics — explicit null clears the value
    const value =
      body.value === null
        ? ''
        : body.value !== undefined
        ? this.safeValidate(() => validateVariableValue(body.value))
        : undefined;

    if (
      type === undefined &&
      value === undefined &&
      body.description === undefined
    ) {
      NcError.badRequest('Nothing to update');
    }

    // [CE-EE] F05 R3: description must be a string (or null to clear) —
    // objects used to be stored as dirty JSON strings by the pg driver and
    // errored out on mysql
    if (
      body.description !== undefined &&
      body.description !== null &&
      typeof body.description !== 'string'
    ) {
      NcError.badRequest('Variable description must be a string');
    }

    // [CE-EE] F05 R3: enforce only when secret material is actually written —
    // a value write on a secret row, or a flip into the secret type (which
    // makes the model encrypt the stored value)
    const finalType = (type ?? existing.type) as BaseVariableValueType;
    const typeFlippedToSecret =
      type !== undefined &&
      type === BaseVariableValueType.SECRET &&
      existing.type !== BaseVariableValueType.SECRET;
    const writesSecretMaterial =
      finalType === BaseVariableValueType.SECRET &&
      (value !== undefined || typeFlippedToSecret);
    if (writesSecretMaterial) {
      this.ensureEncryptionAvailable();
    }

    await BaseVariable.update(context, variableId, {
      ...(value !== undefined ? { value } : {}),
      ...(body.description !== undefined
        ? { description: body.description }
        : {}),
      ...(type !== undefined ? { type } : {}),
    });

    return BaseVariable.get(context, variableId);
  }

  async delete(context: NcContext, baseId: string, variableId: string) {
    await this.getVariableWithBaseCheck(context, baseId, variableId);
    await BaseVariable.delete(context, variableId);
    return true;
  }

  private safeValidate<T>(fn: () => T): T {
    // [CE-EE] F05: map pure-validator errors onto the standard 400 channel
    try {
      return fn();
    } catch (e) {
      if (e instanceof BaseVariableValidationError) {
        NcError.badRequest(e.message);
      }
      throw e;
    }
  }

  private ensureEncryptionAvailable() {
    // [CE-EE] F05 R1/R3: the model's encryptValue silently stores plaintext
    // when NC_CONNECTION_ENCRYPT_KEY is not configured — refuse secret
    // material writes (secret create, value write on a secret row, or a flip
    // into the secret type) instead of failing the "encrypted at rest"
    // promise invisibly. Callers decide when a write touches secret material.
    if (!getCredentialEncryptSecret()) {
      NcError.badRequest(
        'NC_CONNECTION_ENCRYPT_KEY is not configured — secret variables are disabled',
      );
    }
  }

  private async getVariableWithBaseCheck(
    context: NcContext,
    baseId: string,
    variableId: string,
  ): Promise<BaseVariable> {
    const variable = await BaseVariable.get(context, variableId);
    if (!variable || variable.base_id !== baseId) {
      NcError.notFound('Variable not found');
    }
    return variable;
  }

  private async validateUniqueKey(context: NcContext, key: string) {
    const existing = await BaseVariable.list(context, context.base_id);
    if (existing.some((v) => v.key === key)) {
      NcError.badRequest(`Variable key ${key} already exists in this base`);
    }
  }
}
