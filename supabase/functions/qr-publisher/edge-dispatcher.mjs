// Strict application boundary; no Deno.serve or production wiring yet.
export function makeEdgeDispatcher({enabled,authenticate,createCoordinator,recoverBeforeAttempt}){
 if(typeof enabled!=="function"||typeof authenticate!=="function"||typeof createCoordinator!=="function"||typeof recoverBeforeAttempt!=="function")throw Error("missing_edge_dependencies");
 const uuid=x=>typeof x==="string"&&/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(x);
 const hex=(x,n)=>typeof x==="string"&&x.length===n&&/^[a-f0-9]+$/.test(x);
 const exact=(x,keys)=>x!==null&&typeof x==="object"&&!Array.isArray(x)&&Object.keys(x).sort().join(",")===keys.slice().sort().join(",");
 const out=(status,body)=>({status,body});
 const safe=(value,id)=>{
  if(!value||value.requestId!==id)throw Error("invalid_result");
  const s=value.status;
  if(s==="committed"&&hex(value.commit,40)&&hex(value.revision,40))return out(200,{requestId:id,status:s,commit:value.commit,revision:value.revision,pages:"unverified"});
  if(s==="no_change"&&hex(value.revision,40))return out(200,{requestId:id,status:s,revision:value.revision});
  if(s==="cancelled_before_attempt")return out(200,{requestId:id,status:s});
  if(s==="not_found")return out(404,{requestId:id,status:s});
  if(["busy","conflict","reconciliation_required"].includes(s))return out(409,{requestId:id,status:s});
  throw Error("invalid_result");
 };
 // This dispatcher is deliberately not a deployed entrypoint.
 // authenticate MUST bind opaque agent credential, current command lease,
 // same-tenant target, expected stamp and actual authoritative draft on the
 // server. The coordinator must repeat live authority checks on every write.
 return async({method,token,body}={})=>{
  if(method!=="POST")return out(405,{error:"method_not_allowed"});
  if(enabled()!==true)return out(503,{error:"publisher_disabled"});
  if(!hex(token,64))return out(401,{error:"unauthorized"});
  const common=["operation","commandId","leaseGeneration","envelopeSha256"];
  const op=body?.operation;
  const keys=op==="publish"?[...common,"expectedRevision","expectedStamp","draftJson","activateConfirmed"]:op==="reconcile"||op==="cancel_before_attempt"?[...common,"targetRequestId"]:null;
  if(!keys||!exact(body,keys)||!uuid(body.commandId)||!Number.isSafeInteger(body.leaseGeneration)||body.leaseGeneration<1||!hex(body.envelopeSha256,64))return out(400,{error:"invalid_request"});
  if(op==="publish"&&(!hex(body.expectedRevision,40)||!hex(body.expectedStamp,16)||body.activateConfirmed!==false||typeof body.draftJson!=="string"||body.draftJson.length>800000))return out(400,{error:"invalid_request"});
  if(op!=="publish"&&!uuid(body.targetRequestId))return out(400,{error:"invalid_request"});
  let catalog;
  if(op==="publish"){try{catalog=JSON.parse(body.draftJson)}catch{return out(400,{error:"invalid_request"})}if(!catalog||typeof catalog!=="object"||Array.isArray(catalog))return out(400,{error:"invalid_request"})}
  let scope;
  try{scope=await authenticate({token,commandId:body.commandId,leaseGeneration:body.leaseGeneration,envelopeSha256:body.envelopeSha256,operation:op,expectedStamp:body.expectedStamp,expectedRevision:body.expectedRevision,draftJson:body.draftJson,activateConfirmed:body.activateConfirmed,targetRequestId:body.targetRequestId})}catch{return out(403,{error:"forbidden"})}
  if(!scope)return out(403,{error:"forbidden"});
  try{
   if(op==="cancel_before_attempt")return safe(await recoverBeforeAttempt(scope,body.targetRequestId),body.targetRequestId);
   // Only construct the server Git transport AFTER authenticated authority.
   // Recovery must use a read-only installation token.
   const coordinator=await createCoordinator(scope,op==="publish"?"write":"read");
   if(op==="publish")return safe(await coordinator.execute({requestId:body.commandId,expectedRevision:body.expectedRevision,catalog,activateConfirmed:false},scope),body.commandId);
   return safe(await coordinator.reconcile({requestId:body.targetRequestId},scope),body.targetRequestId);
  }catch{return out(503,{error:"publisher_unavailable"})}
 };
}
