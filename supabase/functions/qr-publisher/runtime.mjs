import {makeQrPublisher} from "./compose-publisher.mjs";
import {makeInstallationTokenFactory} from "./github-app-token.mjs";
import {makePublisherHttpHandler} from "./publisher-http-handler.mjs";
import {Buffer} from "node:buffer";

// Real GitHub authentication and Fetch HTTP boundary, but DB connection is
// deliberately injected; do not use service_role or an owner DB login.
// No deployment entrypoint and no default enablement.
export function makePublisherRuntime({env,query,fetchImpl=fetch,enabled=()=>false,timeoutSignal=ms=>AbortSignal.timeout(ms)}){
 if(typeof env!=="function"||typeof query!=="function"||typeof enabled!=="function")throw Error("missing_runtime_dependencies");
 const issueToken=makeInstallationTokenFactory({env,fetchImpl,timeoutSignal});
 const decodeBase64=s=>{
   if(typeof s!=="string"||!/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(s))throw Error("invalid_base64");
   return new TextDecoder("utf-8",{fatal:true}).decode(Buffer.from(s,"base64"));
 };
 const dispatch=makeQrPublisher({enabled,query,issueToken,fetchImpl,timeoutSignal,decodeBase64});
 return makePublisherHttpHandler({dispatch,enabled});
}
