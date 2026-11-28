import { makeEdgeDispatcher } from "./edge-dispatcher.mjs";
import { makeSqlPorts } from "./sql-ports.mjs";
import { makePublishCoordinator } from "./publish-coordinator.mjs";
import { makePublishAdapter } from "./git-data-publish.mjs";
import { makeGitHubRequest } from "./github-http.mjs";
import { validateCatalog } from "./catalog-validation.mjs";

// Composition root, deliberately not a deployable Deno entrypoint.
// query must be a trusted, committed, parameterized private SQL connection.
// issueToken must return a repository-scoped installation token only.
export function makeQrPublisher({ enabled = () => false, query, issueToken, fetchImpl, timeoutSignal, decodeBase64 }) {
  if (typeof issueToken !== "function") throw Error("missing_token_factory");
  const ports = makeSqlPorts({query,validateCatalog});
  return makeEdgeDispatcher({
    enabled,
    authenticate:ports.authenticate,
    recoverBeforeAttempt:ports.recoverBeforeAttempt,
    async createCoordinator(scope,mode) {
      const token = await issueToken(mode);
      const request = makeGitHubRequest({token,mode,fetchImpl,timeoutSignal});
      const adapter = makePublishAdapter({request,validateCatalog,decodeBase64});
      return makePublishCoordinator({
        adapter,
        receipts:ports.receipts,
        authorize:ports.reauthorize,
        fingerprint:ports.fingerprintFor(scope)
      });
    }
  });
}
