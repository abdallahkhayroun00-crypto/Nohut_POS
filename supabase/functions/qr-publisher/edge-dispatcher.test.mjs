import {makeEdgeDispatcher} from './edge-dispatcher.mjs';
async function testDispatcher(makeEdgeDispatcher){
 const id="12345678-1234-4234-8234-123456789abc",target="aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",sha="a".repeat(40),token="a".repeat(64),body={operation:"publish",commandId:id,leaseGeneration:1,envelopeSha256:"b".repeat(64),expectedRevision:sha,expectedStamp:"c".repeat(16),catalog:{products:[]},activateConfirmed:false};
 const equal=(x,y)=>{if(x!==y)throw Error("assertion "+x+" != "+y)};const results=[];
 function fixture({enabled=true,denied=false}={}){
  let auth=0,dispatch=0,mode=null;
  const handler=makeEdgeDispatcher({enabled:()=>enabled,authenticate:async()=>{auth++;if(denied)throw Error("synthetic-secret");return {verified:true}},createCoordinator:async(s,m)=>{dispatch++;mode=m;return {execute:async v=>({requestId:v.requestId,status:"committed",commit:sha,revision:sha,internal:"synthetic-secret"}),reconcile:async v=>({requestId:v.requestId,status:"reconciliation_required"})}},recoverBeforeAttempt:async(s,id)=>({requestId:id,status:"cancelled_before_attempt"})});
  return {run:(b=body,t=token)=>handler({method:"POST",token:t,body:b}),state:()=>({auth,dispatch,mode})}
 }
 async function test(n,f){await f();results.push(n)}
 await test("disabled by default gate prevents dispatch",async()=>{let m=fixture({enabled:false});equal((await m.run()).status,503);equal(m.state().auth,0)});
 await test("invalid token rejected before database",async()=>{let m=fixture();equal((await m.run(body,"bad")).status,401);equal(m.state().auth,0)});
 await test("client supplied tenant or commit denied",async()=>{let m=fixture();equal((await m.run({...body,restaurantId:id})).status,400);equal(m.state().dispatch,0)});
 await test("denied authority never creates Git client",async()=>{let m=fixture({denied:true});let r=await m.run();equal(r.status,403);equal(m.state().dispatch,0);equal(JSON.stringify(r).includes("synthetic-secret"),false)});
 await test("publish response allowlist",async()=>{let m=fixture();let r=await m.run();equal(r.status,200);equal(r.body.pages,"unverified");equal(m.state().mode,"write");equal(JSON.stringify(r).includes("synthetic-secret"),false)});
 const recovery={operation:"reconcile",commandId:id,leaseGeneration:1,envelopeSha256:"b".repeat(64),targetRequestId:target};
 await test("recovery read scope only",async()=>{let m=fixture();equal((await m.run(recovery)).status,409);equal(m.state().mode,"read")});
 await test("cancellation does not construct Git transport",async()=>{let m=fixture();equal((await m.run({...recovery,operation:"cancel_before_attempt"})).body.status,"cancelled_before_attempt");equal(m.state().dispatch,0)});
 await test("fake Git evidence cannot enter recovery",async()=>{let m=fixture();equal((await m.run({...recovery,commit:sha})).status,400);equal(m.state().auth,0)});
 return results;
}
const results=await testDispatcher(makeEdgeDispatcher);console.log(`${results.length} Edge dispatcher checks passed`);
