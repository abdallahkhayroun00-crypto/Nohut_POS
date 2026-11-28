import {makeSqlPorts} from './sql-ports.mjs';
async function sqlPortChecks(makeSqlPorts){
 const token="a".repeat(64),id="12345678-1234-4234-8234-123456789abc",target="aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",sha="b".repeat(40),digest="c".repeat(64),stamp="d".repeat(16),draftJson='{"products":[]}';
 const x={token,commandId:id,leaseGeneration:1,envelopeSha256:"e".repeat(64),operation:"publish",expectedStamp:stamp,expectedRevision:sha,draftJson,activateConfirmed:false};
 const calls=[],identity={restaurantId:"r",epoch:"e",agentId:"a",digest,expectedRevision:sha};
 const query=async(sql,params)=>{calls.push({sql,params});if(sql.includes("bind_draft"))return identity;if(sql.includes("qr_recovery_authority"))return "r";if(sql.includes("qr_publish_claim"))return {status:"new",fence:"f"};if(sql.includes("qr_publish_transition"))return {status:"prepared"};if(sql.includes("qr_publish_recover"))return {status:"not_found"};throw Error("unknown")};
 const p=makeSqlPorts({query,validateCatalog:()=>{}}),results=[];
 const equal=(a,b)=>{if(a!==b)throw Error("assert "+a+" != "+b)};
 async function test(n,f){await f();results.push(n)}
 async function reject(f){let denied=false;try{await f()}catch{denied=true}equal(denied,true)}
 let scope;
 await test("raw draft parameter binding and opaque scope",async()=>{scope=await p.authenticate(x);equal(JSON.stringify(scope),"{}");equal(calls[0].params[6],draftJson);equal(calls[0].sql.includes(token),false)});
 await test("fingerprint obtained only from database",async()=>equal(await p.fingerprintFor(scope)({requestId:id,expectedRevision:sha,catalog:JSON.parse(draftJson),activateConfirmed:false}),digest));
 await test("altered draft denied",()=>reject(()=>p.fingerprintFor(scope)({requestId:id,expectedRevision:sha,catalog:{products:[1]},activateConfirmed:false})));
 await test("untrusted scope denied",()=>reject(()=>p.receipts.claim({}, {requestId:id,digest,expectedRevision:sha})));
 await test("claim with server digest",async()=>equal((await p.receipts.claim(scope,{requestId:id,digest,expectedRevision:sha})).status,"new"));
 await test("forged receipt digest denied",()=>reject(()=>p.receipts.claim(scope,{requestId:id,digest:"f".repeat(64),expectedRevision:sha})));
 await test("reauthorize exact scope",async()=>equal(await p.reauthorize(scope,{operation:"publish",requestId:id,expectedRevision:sha}),scope));
 await test("recovery cannot substitute another target",async()=>{const s=await p.authenticate({...x,operation:"reconcile",targetRequestId:target});await reject(()=>p.receipts.loadForReconcile(s,{requestId:id}));equal(await p.receipts.loadForReconcile(s,{requestId:target}),null)});
 return results;
}
const results=await sqlPortChecks(makeSqlPorts);console.log(`${results.length} SQL port checks passed`);
