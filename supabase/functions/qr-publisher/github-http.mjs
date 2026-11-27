// Fixed-host, allowlisted GitHub transport. Token only from trusted server factory.
export function makeGitHubRequest({token,mode,fetchImpl,timeoutSignal}){
 if(typeof token!=="string"||token.length<20||!["read","write"].includes(mode)||typeof fetchImpl!=="function"||typeof timeoutSignal!=="function")throw Error("invalid_transport_config");
 const root="/repos/nohutfalafel/qr-menu",base="https://api.github.com";
 const sha="[a-f0-9]{40}";
 const readPath=new RegExp("^(?:/git/ref/heads/main|/git/commits/"+sha+"|/git/trees/"+sha+"\\?recursive=1|/contents/cms/(?:pos-managed-menu|pos-managed-status)\\.json\\?ref="+sha+"|/compare/"+sha+"\\.\\.\\."+sha+")$");
 return async({method,path,body})=>{
  if(typeof path!=="string"||!path.startsWith(root+"/"))throw Error("git_target_denied");
  const suffix=path.slice(root.length);
  if(method==="GET"){
   if(!readPath.test(suffix)||body!==undefined)throw Error("git_target_denied");
  }else{
   if(mode!=="write")throw Error("git_write_denied");
   if(method==="PATCH"){
    if(suffix!=="/git/refs/heads/main"||!body||Object.keys(body).sort().join(",")!=="force,sha"||body.force!==false||!new RegExp("^"+sha+"$").test(body.sha))throw Error("git_ref_denied");
   }else if(method==="POST"&&suffix==="/git/trees"){
    if(!body||Object.keys(body).sort().join(",")!=="base_tree,tree"||!new RegExp("^"+sha+"$").test(body.base_tree)||!Array.isArray(body.tree)||body.tree.length<1||body.tree.length>2)throw Error("git_tree_denied");
    const paths=new Set();
    for(const e of body.tree){
     if(!e||Object.keys(e).sort().join(",")!=="content,mode,path,type"||!["cms/pos-managed-menu.json","cms/pos-managed-status.json"].includes(e.path)||paths.has(e.path)||e.mode!=="100644"||e.type!=="blob"||typeof e.content!=="string"||e.content.length>800000)throw Error("git_tree_denied");
     if(e.path==="cms/pos-managed-status.json"&&e.content!=='{"schemaVersion":1,"enabled":true}\n')throw Error("git_marker_denied");
     paths.add(e.path);
    }
    if(!paths.has("cms/pos-managed-menu.json"))throw Error("git_tree_denied");
   }else if(method==="POST"&&suffix==="/git/commits"){
    if(!body||Object.keys(body).sort().join(",")!=="message,parents,tree"||!new RegExp("^"+sha+"$").test(body.tree)||!Array.isArray(body.parents)||body.parents.length!==1||!new RegExp("^"+sha+"$").test(body.parents[0])||typeof body.message!=="string"||!/^cms: Nohut POS QR publication [a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/.test(body.message))throw Error("git_commit_denied");
   }else throw Error("git_target_denied");
  }
  const res=await fetchImpl(base+path,{method,redirect:"error",headers:{authorization:"Bearer "+token,accept:"application/vnd.github+json","x-github-api-version":"2022-11-28","user-agent":"NohutQrPublisher/2",...(body===undefined?{}:{"content-type":"application/json"})},body:body===undefined?undefined:JSON.stringify(body),signal:timeoutSignal(12000)});
  if(!res.ok)throw Error("github_http_error");
  // Bound upstream data before parsing; never return raw upstream errors.
  const reader=res.body?.getReader();if(!reader)throw Error("invalid_github_response");
  let text="",size=0;const decoder=new TextDecoder("utf-8",{fatal:true});
  try{while(true){const x=await reader.read();if(x.done)break;size+=x.value.byteLength;if(size>4000000){await reader.cancel();throw Error("github_response_too_large")}text+=decoder.decode(x.value,{stream:true})}text+=decoder.decode()}finally{reader.releaseLock()}
  return JSON.parse(text);
 };
}
