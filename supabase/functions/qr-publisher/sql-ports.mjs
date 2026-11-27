// Parameterized private SQL bridge. Actual dedicated server DB connection is intentionally not provisioned.
export function makeSqlPorts({query,validateCatalog}){
 if(typeof query!=="function"||typeof validateCatalog!=="function")throw Error("missing_sql_dependencies");
 // query(text, parameters) MUST use bound parameters and return a single
 // scalar JSON value from a committed transaction. No raw token logging.
 const scopes=new WeakMap();
 const hex=(x,n)=>typeof x==="string"&&x.length===n&&/^[a-f0-9]+$/.test(x);
 const sql={
  bind:"select nohut_private.qr_publish_bind_draft($1::text,$2::text,$3::bigint,$4::text,$5::text,$6::text,$7::text) as value",
  recovery:"select (nohut_private.qr_recovery_authority($1::text,$2::text,$3::bigint,$4::text)).restaurant_id::text as value",
  claim:"select nohut_private.qr_publish_claim($1::text,$2::text,$3::bigint,$4::text,$5::text,$6::text) as value",
  transition:"select nohut_private.qr_publish_transition($1::text,$2::text,$3::bigint,$4::text,$5::text,$6::uuid,$7::text,$8::text,$9::text,$10::text,$11::text) as value",
  recover:"select nohut_private.qr_publish_recover($1::text,$2::text,$3::bigint,$4::text,$5::text,$6::text,$7::text,$8::text) as value"
 };
 const base=x=>[x.token,x.commandId,x.leaseGeneration,x.envelopeSha256];
 const get=s=>{const x=scopes.get(s);if(!x)throw Error("untrusted_scope");return x};
 async function authenticate(input){
  const x={...input};delete x.catalog;
  let identity;
  if(x.operation==="publish"){
   if(x.activateConfirmed!==false)throw Error("activation_disabled");
   validateCatalog(JSON.parse(x.draftJson));
   identity=await query(sql.bind,[...base(x),x.expectedStamp,x.expectedRevision,x.draftJson]);
   if(!identity||!hex(identity.digest,64)||identity.expectedRevision!==x.expectedRevision||!identity.restaurantId||!identity.epoch||!identity.agentId)throw Error("draft_binding_denied");
  }else{
   const restaurant=await query(sql.recovery,base(x));
   if(typeof restaurant!=="string"||!restaurant)throw Error("recovery_denied");
   identity={restaurantId:restaurant};
  }
  // No token/raw draft in outward scope or returned JSON.
  const scope=Object.freeze({});scopes.set(scope,{...x,identity});return scope;
 }
 async function reauthorize(s,request){
  const x=get(s);
  if(request.operation==="publish"){
   if(x.operation!=="publish"||request.requestId!==x.commandId||request.expectedRevision!==x.expectedRevision)throw Error("scope_mismatch");
   const next=await query(sql.bind,[...base(x),x.expectedStamp,x.expectedRevision,x.draftJson]);
   if(!next||["restaurantId","epoch","agentId","digest","expectedRevision"].some(k=>next[k]!==x.identity[k]))throw Error("authority_changed");
  }else{
   if(x.operation!=="reconcile"||request.requestId!==x.targetRequestId)throw Error("scope_mismatch");
   if(await query(sql.recovery,base(x))!==x.identity.restaurantId)throw Error("authority_changed");
  }
  return s;
 }
 const fingerprintFor=s=>async input=>{const x=get(s);if(x.operation!=="publish"||input.requestId!==x.commandId||input.expectedRevision!==x.expectedRevision||input.activateConfirmed!==false||JSON.stringify(input.catalog)!==JSON.stringify(JSON.parse(x.draftJson)))throw Error("draft_mismatch");return x.identity.digest};
 function publishBinding(s,b){const x=get(s);if(x.operation!=="publish"||b.requestId!==x.commandId||b.digest!==x.identity.digest)throw Error("binding_mismatch");return x}
 async function transition(s,b,step,v={}){
  const x=publishBinding(s,b);return query(sql.transition,[...base(x),b.digest,b.fence,step,v.parent??null,v.commit??null,v.tree??null,v.revision??null]);
 }
 async function recover(s,id,step,v={}){
  const x=get(s);if(!["reconcile","cancel_before_attempt"].includes(x.operation)||x.targetRequestId!==id)throw Error("scope_mismatch");
  if(x.operation==="cancel_before_attempt"&&step!=="cancel_before_attempt")throw Error("scope_mismatch");
  if(x.operation==="reconcile"&&step==="cancel_before_attempt")throw Error("scope_mismatch");
  return query(sql.recover,[...base(x),id,step,v.commit??null,v.revision??null]);
 }
 const receipts={
  async claim(s,b){const x=publishBinding(s,b);if(b.expectedRevision!==x.expectedRevision)throw Error("binding_mismatch");return query(sql.claim,[...base(x),b.digest,b.expectedRevision])},
  async savePrepared(s,b,p){const x=publishBinding(s,b);if(p.requestId!==b.requestId||p.expectedRevision!==x.expectedRevision)throw Error("binding_mismatch");const v=await transition(s,b,"prepare",p);if(v?.status!=="prepared")throw Error("prepare_not_persisted")},
  async markAttempt(s,b){return transition(s,b,"attempt")},
  async finish(s,b,v){if(v.requestId!==b.requestId)throw Error("binding_mismatch");const step=v.status==="reconciliation_required"?"unknown":v.status;if(!["unknown","committed","no_change"].includes(step))throw Error("invalid_finish");const saved=await transition(s,b,step,v);if(saved?.requestId!==v.requestId||saved.status!==v.status)throw Error("finish_not_persisted")},
  async loadForReconcile(s,b){const v=await recover(s,b.requestId,"inspect");return v?.status==="not_found"?null:v},
  async recordReconciliation(s,b){if(b.value.requestId!==b.requestId)throw Error("binding_mismatch");if(b.value.status==="reconciliation_required")return; if(b.value.status!=="committed"||b.value.commit!==b.expectedCommit)throw Error("evidence_mismatch");const v=await recover(s,b.requestId,"confirm_reachable",b.value);const saved=v?.status==="completed"?v.result:v;if(saved?.status!=="committed"||saved.commit!==b.expectedCommit||saved.revision!==b.value.revision)throw Error("recovery_not_persisted")}
 };
 async function recoverBeforeAttempt(s,id){const v=await recover(s,id,"cancel_before_attempt");return v?.status==="completed"?v.result:{...v,requestId:id}}
 return {authenticate,reauthorize,fingerprintFor,receipts,recoverBeforeAttempt};
}
