import {createPrivateKey,sign} from "node:crypto";
import {Buffer} from "node:buffer";

// Server-only factory; no persistent installation token cache.
// No caller-supplied repository, installation, host, or permissions.
export function makeInstallationTokenFactory({env,fetchImpl=fetch,now=Date.now,timeoutSignal=ms=>AbortSignal.timeout(ms)}){
 if(typeof env!=="function")throw Error("missing_github_configuration");
 const api="https://api.github.com",repo="nohutfalafel/qr-menu";
 const b64=x=>Buffer.from(JSON.stringify(x)).toString("base64url");
 async function call(path,jwt,body){
  const r=await fetchImpl(api+path,{method:body===undefined?"GET":"POST",redirect:"error",
   headers:{authorization:"Bearer "+jwt,accept:"application/vnd.github+json","x-github-api-version":"2022-11-28","user-agent":"NohutQrPublisher/2",...(body===undefined?{}:{"content-type":"application/json"})},
   body:body===undefined?undefined:JSON.stringify(body),signal:timeoutSignal(12000)});
  if(!r.ok)throw Error("github_auth_failed");
  const reader=r.body?.getReader();if(!reader)throw Error("invalid_auth_response");
  const decoder=new TextDecoder("utf-8",{fatal:true});let size=0,text="";
  try{while(true){const part=await reader.read();if(part.done)break;size+=part.value.byteLength;if(size>1000000){await reader.cancel();throw Error("auth_response_too_large")}text+=decoder.decode(part.value,{stream:true})}text+=decoder.decode()}finally{reader.releaseLock()}
  return JSON.parse(text);
 }
 return async function issueToken(mode){
  if(!["read","write"].includes(mode))throw Error("invalid_token_scope");
  try{
   const id=env("NOHUT_QR_GITHUB_APP_ID")?.trim()??"",pem=env("NOHUT_QR_GITHUB_PRIVATE_KEY")??"";
   const expected=env("NOHUT_QR_GITHUB_INSTALLATION_ID")?.trim()??"";
   if(!/^\d{1,16}$/.test(id)||!pem||pem.length>32768||(expected&&!/^\d{1,16}$/.test(expected)))throw Error("invalid_config");
   const key=createPrivateKey(pem.replace(/\\n/g,"\n").trim());
   if(key.asymmetricKeyType!=="rsa"||(key.asymmetricKeyDetails?.modulusLength??0)<2048)throw Error("invalid_key");
   const t=Math.floor(now()/1000);
   const unsigned=b64({alg:"RS256",typ:"JWT"})+"."+b64({iat:t-60,exp:t+480,iss:id});
   const jwt=unsigned+"."+sign("RSA-SHA256",Buffer.from(unsigned),key).toString("base64url");
   const app=await call("/app",jwt);
   if(String(app.id)!==id||app.slug!=="nohut-qr-publisher")throw Error("wrong_app");
   const installation=await call("/repos/"+repo+"/installation",jwt);
   if(!Number.isSafeInteger(installation.id)||installation.id<=0||String(installation.app_id)!==id||
      installation.suspended_at||installation.account?.login?.toLowerCase()!=="nohutfalafel"||
      installation.repository_selection!=="selected"||(expected&&String(installation.id)!==expected)||
      (mode==="write"&&installation.permissions?.contents!=="write")||
      (mode==="read"&&!["read","write"].includes(installation.permissions?.contents)))throw Error("wrong_installation");
   const result=await call("/app/installations/"+installation.id+"/access_tokens",jwt,{repositories:["qr-menu"],permissions:{contents:mode}});
   const expiry=Date.parse(result.expires_at),permissions=result.permissions;
   if(typeof result.token!=="string"||result.token.length<20||result.token.length>4096||
     !Number.isFinite(expiry)||expiry<now()+60000||expiry>now()+3660000||
     !permissions||permissions.contents!==mode||
     Object.entries(permissions).some(([k,v])=>k==="contents"?v!==mode:k==="metadata"?v!=="read":true)||
     !Array.isArray(result.repositories)||result.repositories.length!==1||
     result.repositories[0]?.full_name?.toLowerCase()!==repo)throw Error("unexpected_token_scope");
   return result.token;
  }catch{
   // Never propagate upstream response content, secrets, or crypto errors.
   throw Error("github_installation_token_unavailable");
  }
 };
}
