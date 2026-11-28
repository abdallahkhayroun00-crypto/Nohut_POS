// Isolated Git Data adapter. Requires trusted transport, decoder, durable receipt and fresh authorization hooks; no endpoint.
export function makePublishAdapter({request,validateCatalog,decodeBase64,prepareAssets}){
 if([request,validateCatalog,decodeBase64].some(x=>typeof x!=="function"))throw Error("missing_dependency");
 const root="/repos/nohutfalafel/qr-menu",managed="cms/pos-managed-menu.json",marker="cms/pos-managed-status.json";
 const sha=x=>typeof x==="string"&&/^[0-9a-f]{40}$/.test(x);
 const checked=x=>{if(!sha(x))throw Error("invalid_git_sha");return x};
 const uuid=x=>typeof x==="string"&&/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(x);
 const call=(method,path,body)=>request({method,path:root+path,body});
 const canonical=x=>Array.isArray(x)?x.map(canonical):x!==null&&typeof x==="object"?Object.fromEntries(Object.keys(x).sort().map(k=>[k,canonical(x[k])])):x;
 const result=(p,status,reason)=>({status,requestId:p.requestId,...(reason?{reason}:{}),...(status==="committed"?{commit:p.commit,revision:p.revision,pages:"unverified"}:{})});
 async function head(){
  const r=await call("GET","/git/ref/heads/main");
  if(r.ref!=="refs/heads/main"||r.object?.type!=="commit")throw Error("invalid_ref");
  return checked(r.object.sha);
 }
 async function file(path,parent){
  const f=await call("GET","/contents/"+path+"?ref="+checked(parent));
  if(f.type!=="file"||f.path!==path||f.encoding!=="base64"||typeof f.content!=="string"||f.content.length>2000000)throw Error("invalid_file");
  return {sha:checked(f.sha),value:JSON.parse(decodeBase64(f.content.replace(/\s/g,"")))};
 }
 function checkPrepared(p){
  if(!uuid(p?.requestId)||![p.parent,p.commit,p.tree,p.revision,p.expectedRevision].every(sha))throw Error("invalid_prepared");
 }
 // Caller MUST hold exclusive durable claim and persist request intent/payload hash.
 // Hooks MUST throw on failure. No endpoint or production transport here.
 async function prepare({requestId,expectedRevision,catalog,activateConfirmed=false,assertAuthorized,recordPrepared}){
  if(!uuid(requestId)||!sha(expectedRevision)||typeof activateConfirmed!=="boolean"||typeof assertAuthorized!=="function"||typeof recordPrepared!=="function")throw Error("invalid_execution");
  await assertAuthorized();
  const parent=await head(),base=await call("GET","/git/commits/"+parent);
  if(base.sha!==parent)throw Error("invalid_parent");
  const baseTree=checked(base.tree?.sha);
  // Existing managed file only. Bootstrap must be handled by separately reviewed flow.
  const old=await file(managed,parent),status=await file(marker,parent);
  if(old.sha!==expectedRevision)throw Error("revision_conflict");
  if(status.value?.schemaVersion!==1||typeof status.value.enabled!=="boolean"||Object.keys(status.value).sort().join(",")!=="enabled,schemaVersion")throw Error("invalid_marker");
  if(!status.value.enabled&&!activateConfirmed)throw Error("activation_confirmation_required");
  validateCatalog(catalog,old.value);
  const content=JSON.stringify(catalog,null,2)+"\n";
  if(encodeURIComponent(content).replace(/%[0-9A-F]{2}/g,"x").length>800000)throw Error("catalog_too_large");
  if(status.value.enabled&&JSON.stringify(canonical(catalog))===JSON.stringify(canonical(old.value)))return {status:"no_change",requestId,revision:old.sha,head:parent};
  const entries=[{path:managed,mode:"100644",type:"blob",content}];
  if(!status.value.enabled)entries.push({path:marker,mode:"100644",type:"blob",content:'{"schemaVersion":1,"enabled":true}\n'});
  // Asset publication remains unavailable in the runtime until the private
  // pinned storage/decoder/transport contract is reviewed and wired.
  const oldProducts=new Map(old.value.products.map(p=>[p.id,p.image]));
  const oldCampaigns=new Map(old.value.campaigns.map(c=>[c.id,c]));
  const changedAssets=catalog.products.some(p=>p.image!=null&&p.image!==oldProducts.get(p.id))||
   catalog.campaigns.some(c=>["poster","thumbnail"].some(k=>c[k]!=null&&c[k]!==oldCampaigns.get(c.id)?.[k]));
  if(changedAssets&&typeof prepareAssets!=="function")throw Error("asset_publication_disabled");
  if(changedAssets){
   const assets=await prepareAssets({requestId,previous:old.value,catalog,parentTree:baseTree});
   if(!Array.isArray(assets)||assets.length>4)throw Error("invalid_asset_entries");
   const allowed=new Set(catalog.products.filter(p=>p.image!==oldProducts.get(p.id)).map(p=>p.image));
   const seen=new Set();
   for(const e of assets){
    if(!e||!allowed.has(e.path)||seen.has(e.path)||!/^assets\/products\/pos-[a-f0-9]{64}\.(png|jpg|webp)$/.test(e.path)||e.mode!=="100644"||e.type!=="blob"||!sha(e.sha))throw Error("invalid_asset_entry");
    seen.add(e.path);entries.push({path:e.path,mode:e.mode,type:e.type,sha:e.sha});
   }
  }
  await assertAuthorized();
  const tree=await call("POST","/git/trees",{base_tree:baseTree,tree:entries});
  const treeSha=checked(tree.sha);
  let revision=tree.tree?.find(x=>x.path===managed&&x.type==="blob")?.sha;
  if(!sha(revision)){
   const t=await call("GET","/git/trees/"+treeSha+"?recursive=1");
   if(t.sha!==treeSha||t.truncated!==false)throw Error("unverifiable_tree");
   revision=t.tree?.find(x=>x.path===managed&&x.type==="blob")?.sha;
  }
  checked(revision);
  if(entries.some(e=>e.sha)){
   const full=await call("GET","/git/trees/"+treeSha+"?recursive=1");
   if(full.sha!==treeSha||full.truncated!==false||!Array.isArray(full.tree))throw Error("unverifiable_asset_tree");
   for(const e of entries.filter(e=>e.sha)){
    const matches=full.tree.filter(x=>x.path===e.path);
    if(matches.length!==1||matches[0].sha!==e.sha||matches[0].type!=="blob"||matches[0].mode!=="100644")throw Error("asset_tree_mismatch");
   }
   const menu=full.tree.filter(x=>x.path===managed);
   if(menu.length!==1||menu[0].sha!==revision||menu[0].type!=="blob")throw Error("catalog_tree_mismatch");
  }
  const message="cms: Nohut POS QR publication "+requestId;
  const c=await call("POST","/git/commits",{message,tree:treeSha,parents:[parent]});
  const prepared={requestId,parent,commit:checked(c.sha),tree:treeSha,revision,expectedRevision};
  if(c.tree?.sha!==treeSha||c.parents?.length!==1||c.parents[0].sha!==parent)throw Error("unverifiable_commit");
  // This must commit the exact immutable receipt before any ref mutation.
  await recordPrepared(Object.freeze({...prepared}));
  return {status:"prepared",...prepared};
 }
 // Caller must obtain prepared from durable storage, not the client; must
 // durably mark ref attempt before calling, and reconcile any prior attempt.
 async function publishPrepared(p,{assertAuthorized}){
  checkPrepared(p);
  if(typeof assertAuthorized!=="function")throw Error("missing_authority");
  await assertAuthorized();
  if(await head()!==p.parent)return result(p,"unknown","head_changed_reconcile_required");
  const c=await call("GET","/git/commits/"+p.commit);
  if(c.sha!==p.commit||c.tree?.sha!==p.tree||c.parents?.length!==1||c.parents[0].sha!==p.parent||c.message!=="cms: Nohut POS QR publication "+p.requestId)throw Error("unverifiable_commit");
  await assertAuthorized();
  try{
   const r=await call("PATCH","/git/refs/heads/main",{sha:p.commit,force:false});
   return r.ref==="refs/heads/main"&&r.object?.sha===p.commit?result(p,"committed"):result(p,"unknown","unverified_ref_response");
  }catch{return result(p,"unknown","ref_update_outcome_unknown");}
 }
 async function reconcile(p){
  checkPrepared(p);
  try{
   const h=await head();
   if(h===p.commit)return {...result(p,"committed"),currentHead:h};
   const c=await call("GET","/compare/"+p.commit+"..."+h);
   if(c.status==="ahead"&&c.merge_base_commit?.sha===p.commit)return {...result(p,"committed"),currentHead:h};
   // Not reachable now does not prove no earlier write. No automatic retry.
   return result(p,"unknown","commit_not_proven_reachable");
  }catch{return result(p,"unknown","reconciliation_unavailable");}
 }
 return {prepare,publishPrepared,reconcile};
}
