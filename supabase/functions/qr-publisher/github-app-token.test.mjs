import {makeInstallationTokenFactory} from "./github-app-token.mjs";
import {generateKeyPairSync,verify} from "node:crypto";
import assert from "node:assert/strict";
const {privateKey,publicKey}=generateKeyPairSync("rsa",{modulusLength:2048});
const pem=privateKey.export({type:"pkcs8",format:"pem"}).toString();
const time=Date.UTC(2026,10,28);
const secret="synthetic-installation-token-not-real";
function fixture({mode="read",overrideApp={},overrideInstall={},overrideToken={},badKey=false,httpError=false}={}){
 const calls=[];
 const env=k=>({NOHUT_QR_GITHUB_APP_ID:"123456",NOHUT_QR_GITHUB_PRIVATE_KEY:badKey?"invalid":pem})[k];
 const fetchImpl=async(url,opts)=>{
  calls.push({url,opts});assert.equal(opts.redirect,"error");
  const jwt=opts.headers.authorization.slice(7),[h,p,s]=jwt.split(".");
  assert.equal(JSON.parse(Buffer.from(h,"base64url")).alg,"RS256");
  const payload=JSON.parse(Buffer.from(p,"base64url"));assert.equal(payload.iss,"123456");assert.equal(payload.exp,Math.floor(time/1000)+480);
  assert.ok(verify("RSA-SHA256",Buffer.from(h+"."+p),publicKey,Buffer.from(s,"base64url")));
  if(httpError)return new Response("sensitive upstream body",{status:403});
  let data;
  if(url==="https://api.github.com/app")data={id:123456,slug:"nohut-qr-publisher",...overrideApp};
  else if(url==="https://api.github.com/repos/nohutfalafel/qr-menu/installation")data={id:456,app_id:123456,account:{login:"nohutfalafel"},repository_selection:"selected",permissions:{contents:"write"},...overrideInstall};
  else if(url==="https://api.github.com/app/installations/456/access_tokens"){
   assert.deepEqual(JSON.parse(opts.body),{repositories:["qr-menu"],permissions:{contents:mode}});
   data={token:secret,expires_at:new Date(time+3600000).toISOString(),permissions:{contents:mode,metadata:"read"},repositories:[{full_name:"nohutfalafel/qr-menu"}],...overrideToken};
  }else throw Error("unexpected URL");
  return new Response(JSON.stringify(data),{status:200});
 };
 return {calls,issue:makeInstallationTokenFactory({env,fetchImpl,now:()=>time,timeoutSignal:()=>undefined})};
}
for(const mode of ["read","write"]){const f=fixture({mode});assert.equal(await f.issue(mode),secret);assert.equal(f.calls.length,3)}
const badCases=[
 {overrideApp:{slug:"another-app"}},
 {overrideInstall:{repository_selection:"all"}},
 {overrideInstall:{suspended_at:"2026-11-28"}},
 {overrideInstall:{account:{login:"wrong-owner"}}},
 {mode:"write",overrideInstall:{permissions:{contents:"read"}}},
 {overrideToken:{repositories:[{full_name:"other/repo"}]}},
 {overrideToken:{permissions:{contents:"write"}}},
 {overrideToken:{permissions:{contents:"read",administration:"write"}}},
 {overrideToken:{expires_at:new Date(time).toISOString()}},
 {badKey:true},
 {httpError:true}
];
for(const c of badCases){const f=fixture(c);await assert.rejects(()=>f.issue(c.mode??"read"),{message:"github_installation_token_unavailable"});}
const f=fixture();await assert.rejects(()=>f.issue("admin"),{message:"invalid_token_scope"});assert.equal(f.calls.length,0);
console.log("14 GitHub App token factory checks passed");
