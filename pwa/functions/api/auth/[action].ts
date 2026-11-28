// Cloudflare Pages Function: POST /api/auth/{login|unlock|pin|mfa|logout}.
// See ../../_lib/bff.ts. One throttle per isolate (best effort).
import { LoginBff, Throttle, type BffEnv } from '../../_lib/bff';

const throttle = new Throttle();

interface Context { request: Request; env: BffEnv; params: { action?: string | string[] } }

export const onRequest = async (context: Context): Promise<Response> => {
  const action = Array.isArray(context.params.action) ? context.params.action[0] : context.params.action;
  return new LoginBff(context.env, fetch, throttle).handle(context.request, action ?? '');
};
