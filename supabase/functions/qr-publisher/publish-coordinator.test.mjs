import { makePublishCoordinator } from './publish-coordinator.mjs';
async function coordinatorChecks(makePublishCoordinator) {
 const id="12345678-1234-4234-8234-123456789abc",r="1".repeat(40),c="2".repeat(40),p="3".repeat(40),t="4".repeat(40),n="5".repeat(40),scope="restaurant-A";
 const equal=(x,y)=>{if(JSON.stringify(x)!==JSON.stringify(y))throw Error("assertion "+JSON.stringify(x)+" != "+JSON.stringify(y))};
 const input={requestId:id,expectedRevision:r,catalog:{price:5}};
 function fixture({loseAck=false,unknown=false,deny=false,saveFail=false,revoked=false,noChange=false}={}){
  let row=null,writes=0,prepares=0,checks=0,applied=false;
  const authorization=async(ctx)=>{checks++;if(deny||ctx!=="trusted"||(revoked&&checks>=4))throw Error("denied");return scope};
  const receiptPort={
   async claim(s,i){equal(s,scope);if(row){if(row.digest!==i.digest)return {status:"conflict"};return {...row}}row={...i,status:"new",fence:"fence-1"};return {status:"new",fence:row.fence}},
   async savePrepared(s,b,value){equal(s,scope);equal(b.fence,row.fence);if(saveFail)throw Error("storage_failure");equal(row.status,"new");row.prepared=value;row.status="prepared"},
   async markAttempt(s,b){equal(s,scope);equal(b.fence,row.fence);equal(row.status,"prepared");row.status="attempted";return row.prepared},
   async finish(s,b,value){equal(s,scope);equal(b.fence,row.fence);if(loseAck&&applied)throw Error("lost_ack");row.status=value.status==="reconciliation_required"?"unknown":"completed";row.result=value},
   async loadForReconcile(s,b){equal(s,scope);return row?.requestId===b.requestId?{...row}:null},
   async recordReconciliation(s,b){equal(s,scope);equal(b.expectedCommit,row.prepared.commit);if(b.value.status==="committed"){row.status="completed";row.result=b.value}}
  };
  const adapter={
   async prepare(i){prepares++;await i.assertAuthorized();if(noChange)return {status:"no_change",requestId:id,revision:r};const v={requestId:id,expectedRevision:r,parent:p,commit:c,tree:t,revision:n};await i.recordPrepared(v);return {status:"prepared",...v}},
   async publishPrepared(v,h){await h.assertAuthorized();equal(row.status,"attempted");equal(v,row.prepared);writes++;applied=true;return unknown?{status:"unknown",requestId:id}:{status:"committed",requestId:id,commit:c,revision:n}},
   async reconcile(v){return applied?{status:"committed",requestId:v.requestId,commit:v.commit,revision:v.revision}:{status:"unknown",requestId:v.requestId}}
  };
  const fresh=()=>makePublishCoordinator({adapter,receipts:receiptPort,authorize:authorization,fingerprint:async i=>String(i.catalog.price===5?"a":"b").repeat(64)});
  return {fresh,run:(i=input)=>fresh().execute(i,"trusted"),reconcile:()=>fresh().reconcile({requestId:id},"trusted"),state:()=>({row,writes,prepares,checks})}
 }
 const results=[];async function test(name,f){await f();results.push(name)}
 await test("normal then duplicate after restart",async()=>{let m=fixture();equal((await m.run()).status,"committed");equal((await m.run()).status,"committed");equal(m.state().writes,1);equal(m.state().prepares,1)});
 await test("different payload same ID conflict",async()=>{let m=fixture();await m.run();equal((await m.run({...input,catalog:{price:6}})).status,"conflict");equal(m.state().writes,1)});
 await test("lost result ACK cannot repeat write",async()=>{let m=fixture({loseAck:true});equal((await m.run()).status,"reconciliation_required");equal((await m.run()).status,"reconciliation_required");equal(m.state().writes,1);equal((await m.reconcile()).status,"committed");equal((await m.run()).status,"committed")});
 await test("ambiguous network result reconciles read-only",async()=>{let m=fixture({unknown:true});equal((await m.run()).status,"reconciliation_required");equal((await m.reconcile()).status,"committed");equal(m.state().writes,1)});
 await test("prepare receipt failure blocks publication",async()=>{let m=fixture({saveFail:true});equal((await m.run()).status,"reconciliation_required");equal(m.state().writes,0)});
 await test("revocation blocks publication",async()=>{let m=fixture({revoked:true});equal((await m.run()).status,"reconciliation_required");equal(m.state().writes,0)});
 await test("unauthorized caller never claims",async()=>{let m=fixture({deny:true});let denied=false;try{await m.run()}catch(e){denied=e.message==="denied"}equal(denied,true);equal(m.state().row,null)});
 await test("no-change is durable without write",async()=>{let m=fixture({noChange:true});equal((await m.run()).status,"no_change");equal((await m.run()).status,"no_change");equal(m.state().writes,0)});
 await test("missing receipt no GitHub operation",async()=>{let m=fixture();equal((await m.reconcile()).status,"not_found");equal(m.state().writes,0)});
 return results;
}
const results=await coordinatorChecks(makePublishCoordinator);console.log(`${results.length} receipt coordinator checks passed`);
