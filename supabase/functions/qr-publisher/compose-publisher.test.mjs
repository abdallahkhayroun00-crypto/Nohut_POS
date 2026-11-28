import {makeQrPublisher} from "./compose-publisher.mjs";
import {createHash} from "node:crypto";
import assert from "node:assert/strict";
const tr={tr:"Test",en:"Test",ar:"اختبار"};
const catalog={schemaVersion:1,source:"nohutfalafel/qr-menu",currency:"TRY",categories:[{id:"all",name:tr,description:tr,active:true,order:0},{id:"wrap",name:tr,description:tr,active:true,order:1}],products:[{id:1,category:"wrap",name:tr,displayName:tr,description:tr,price:140,active:true,image:"assets/products/test.webp",available:true,legacyKey:"Test",order:0}],campaigns:[]};
const draftJson=JSON.stringify(catalog),digest=createHash("sha256").update(draftJson).digest("hex");
const id="12345678-1234-4234-8234-123456789abc",revision="a".repeat(40),head="b".repeat(40),tree="c".repeat(40);
const request={method:"POST",token:"d".repeat(64),body:{operation:"publish",commandId:id,leaseGeneration:1,envelopeSha256:"e".repeat(64),expectedRevision:revision,expectedStamp:digest.slice(0,16),draftJson,activateConfirmed:false}};
let sqlCalls=[],httpCalls=[],tokenCalls=[];
const query=async(sql,params)=>{
 sqlCalls.push({sql,params});
 if(sql.includes("bind_draft"))return {restaurantId:"restaurant",epoch:"epoch",agentId:"agent",digest,expectedRevision:revision};
 if(sql.includes("qr_publish_claim"))return {status:"new",fence:"synthetic-fence"};
 if(sql.includes("qr_publish_transition")){
  assert.equal(params[6],"no_change");
  return {requestId:id,status:"no_change",revision};
 }
 throw Error("unexpected SQL");
};
const fetchImpl=async(url,opts)=>{
 httpCalls.push({url,method:opts.method});assert.equal(opts.method,"GET");
 const p=new URL(url).pathname;
 let body;
 if(p.endsWith("/git/ref/heads/main"))body={ref:"refs/heads/main",object:{type:"commit",sha:head}};
 else if(p.endsWith("/git/commits/"+head))body={sha:head,tree:{sha:tree}};
 else if(p.endsWith("pos-managed-menu.json"))body={type:"file",path:"cms/pos-managed-menu.json",encoding:"base64",sha:revision,content:Buffer.from(draftJson).toString("base64")};
 else if(p.endsWith("pos-managed-status.json"))body={type:"file",path:"cms/pos-managed-status.json",encoding:"base64",sha:tree,content:Buffer.from(JSON.stringify({schemaVersion:1,enabled:true})).toString("base64")};
 else throw Error("unexpected Git path");
 return new Response(JSON.stringify(body),{status:200});
};
const config={query,issueToken:async mode=>{tokenCalls.push(mode);return "synthetic-installation-token-only"},fetchImpl,timeoutSignal:()=>AbortSignal.timeout(1000),decodeBase64:s=>new TextDecoder("utf-8",{fatal:true}).decode(Buffer.from(s,"base64"))};
const disabled=makeQrPublisher(config);
assert.equal((await disabled(request)).status,503);
assert.equal(sqlCalls.length+httpCalls.length+tokenCalls.length,0);
const publisher=makeQrPublisher({...config,enabled:()=>true});
const outcome=await publisher(request);
assert.deepEqual(outcome,{status:200,body:{requestId:id,status:"no_change",revision}});
assert.deepEqual(tokenCalls,["write"]);
assert.equal(httpCalls.length,4);
assert.equal(sqlCalls.at(-1).params[6],"no_change");
assert.ok(sqlCalls.every(x=>!x.sql.includes(request.token)));
assert.ok(!JSON.stringify(outcome).includes(request.token));
console.log("2 composed publisher checks passed (default-disabled and authenticated no-change with streamed GitHub mocks)");
