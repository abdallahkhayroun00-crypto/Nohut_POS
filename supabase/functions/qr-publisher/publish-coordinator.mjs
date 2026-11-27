// Receipt-driven cloud publisher orchestration. Injected ports MUST implement durable SQL transactions, authority checks and fencing. No default storage or network.
export function makePublishCoordinator({adapter,receipts,authorize,fingerprint}) {
 if(!adapter||!receipts||typeof authorize!=="function"||typeof fingerprint!=="function")throw Error("missing_dependency");
 for(const k of ["claim","savePrepared","markAttempt","finish","loadForReconcile","recordReconciliation"])if(typeof receipts[k]!=="function")throw Error("missing_receipt_port");
 const uuid=x=>typeof x==="string"&&/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(x);
 const sha=x=>typeof x==="string"&&/^[0-9a-f]{40}$/.test(x);
 const response=(requestId,status)=>({requestId,status});
 const known=(requestId,value)=>{
  if(!value||value.requestId!==requestId)throw Error("invalid_result");
  if(value.status==="committed"&&sha(value.commit)&&sha(value.revision))return {requestId,status:"committed",commit:value.commit,revision:value.revision,pages:"unverified"};
  if(value.status==="no_change"&&sha(value.revision))return {requestId,status:"no_change",revision:value.revision};
  if(value.status==="cancelled_before_attempt")return response(requestId,"cancelled_before_attempt");
  if(value.status==="unknown")return response(requestId,"reconciliation_required");
  throw Error("invalid_result");
 };
 async function execute({requestId,expectedRevision,catalog,activateConfirmed=false},context){
  if(!uuid(requestId)||!sha(expectedRevision)||typeof activateConfirmed!=="boolean")throw Error("invalid_request");
  // authorize MUST resolve a server-validated tenant/actor/lease/command binding
  // from the opaque authenticated context. Client role/tenant is never accepted.
  const scope=await authorize(context,{requestId,operation:"publish",expectedRevision});
  const digest=await fingerprint({requestId,expectedRevision,catalog,activateConfirmed});
  if(typeof digest!=="string"||!/^[0-9a-f]{64}$/.test(digest))throw Error("invalid_fingerprint");
  // claim is one atomic DB operation: check bound authority, scope and hash,
  // reject conflicting payloads and unresolved operations on the same repo;
  // issue exactly one fresh fencing token for a new claim.
  const c=await receipts.claim(scope,{requestId,digest,expectedRevision});
  if(c.status==="conflict")return response(requestId,"conflict");
  if(c.status==="completed")return known(requestId,c.result);
  if(c.status==="busy")return response(requestId,"busy");
  if(["prepared","attempted","unknown"].includes(c.status))return response(requestId,"reconciliation_required");
  if(c.status!=="new"||typeof c.fence!=="string"||!c.fence)throw Error("invalid_claim");
  const binding={requestId,digest,fence:c.fence};
  const recheck=async()=>{await authorize(context,{requestId,operation:"publish",expectedRevision,scope,fence:c.fence})};
  try {
   const p=await adapter.prepare({requestId,expectedRevision,catalog,activateConfirmed,assertAuthorized:recheck,recordPrepared:async prepared=>{
    if(prepared.requestId!==requestId||prepared.expectedRevision!==expectedRevision||![prepared.parent,prepared.commit,prepared.tree,prepared.revision].every(sha))throw Error("invalid_prepared");
    await recheck();
    // DB compare-and-set on matching fence; throw if not durably committed.
    await receipts.savePrepared(scope,binding,prepared);
   }});
   if(p.status==="no_change"){
    const value=known(requestId,p);
    await receipts.finish(scope,binding,value);
    return value;
   }
   if(p.status!=="prepared"||p.requestId!==requestId||p.expectedRevision!==expectedRevision)throw Error("invalid_prepared");
   await recheck();
   // The storage port returns the exact persisted prepared object, never
   // accepts a caller's substitute, and atomically consumes the one attempt.
   const persisted=await receipts.markAttempt(scope,binding);
   if(!persisted||persisted.requestId!==requestId||persisted.expectedRevision!==expectedRevision||["parent","commit","tree","revision"].some(k=>!sha(persisted[k])||persisted[k]!==p[k]))throw Error("invalid_prepared");
   const value=known(requestId,await adapter.publishPrepared(persisted,{assertAuthorized:recheck}));
   await receipts.finish(scope,binding,value);
   return value;
  }catch{
   // Never retry after an ambiguous failure, including a failed ACK write.
   // Durable port must retain unresolved claim/attempt and block another write.
   // Do not expose exception strings or attempt to reset a receipt here.
   return response(requestId,"reconciliation_required");
  }
 }
 async function reconcile({requestId},context){
  if(!uuid(requestId))throw Error("invalid_request");
  const scope=await authorize(context,{requestId,operation:"reconcile"});
  const stored=await receipts.loadForReconcile(scope,{requestId});
  if(!stored||stored.requestId!==requestId)return response(requestId,"not_found");
  if(stored.status==="completed")return known(requestId,stored.result);
  // Pre-attempt cancellation is an explicit fenced recovery operation, not a GitHub lookup.
  if(!["attempted","unknown"].includes(stored.status)||!stored.prepared)return response(requestId,"reconciliation_required");
  const p=stored.prepared;
  if(p.requestId!==requestId||![p.parent,p.commit,p.tree,p.revision,p.expectedRevision].every(sha))throw Error("invalid_prepared");
  // Reconciliation is strictly read-only at GitHub. Authorization and atomic
  // evidence persistence must still be enforced by the storage port.
  const value=known(requestId,await adapter.reconcile(p));
  await authorize(context,{requestId,operation:"reconcile",scope});
  await receipts.recordReconciliation(scope,{requestId,expectedCommit:p.commit,value});
  return value;
 }
 return {execute,reconcile};
}
