import { Injectable, UnauthorizedException } from '@nestjs/common';
import { PassportStrategy } from '@nestjs/passport';
import { Strategy } from 'passport-custom';
import { extractRolesObj } from 'nocodb-sdk';
import type { NcRequest } from '~/interface/config';
import { Base } from '~/models';

@Injectable()
export class BaseViewStrategy extends PassportStrategy(Strategy, 'base-view') {
  // eslint-disable-next-line @typescript-eslint/ban-types
  async validate(req: NcRequest, callback: Function) {
    try {
      let user;
      if (req.headers['xc-shared-base-id']) {
        const sharedBase = await Base.getByUuid(
          req.context,
          req.headers['xc-shared-base-id'],
        );

        // block shared base for private base
        if (sharedBase.default_role) {
          return callback(
            new UnauthorizedException(
              'Shared base feature is not available for private bases. Please contact the base owner for access.',
            ),
          );
        }

        // [CE-EE] F08 R1: fork-private bases block shared links at the auth
        // layer too — a link created before privatization must stop resolving
        // (the extract-ids mask skips public pseudo users by design).
        if (sharedBase?.is_private) {
          return callback(
            new UnauthorizedException(
              'Shared base feature is not available for private bases. Please contact the base owner for access.',
            ),
          );
        }

        // validate base id
        if (!sharedBase || req.ncBaseId !== sharedBase.id) {
          return callback(new UnauthorizedException());
        }

        user = {
          roles: extractRolesObj(sharedBase?.roles),
          base_roles: extractRolesObj(sharedBase?.roles),
        };
      }

      callback(null, user);
    } catch (error) {
      callback(error);
    }
  }
}
