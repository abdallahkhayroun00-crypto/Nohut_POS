import { makePublishAdapter } from './git-data-publish.mjs';
async function runChecks(makePublishAdapter){
 const P="1".repeat(40),B="2".repeat(40),R="3".repeat(40),M="4".repeat(40),T="5".repeat(40),C="6".repeat(40),N="7".repeat(40),X="8".repeat(40),requestId="12345678-1234-4234-8234-123456789abc";
 const managed="cms/pos-managed-menu.json",marker="cms/pos-managed-status.json",old={products:[{price:1}]},candidate={products:[{price:2}]};
 const equal=(a,b)=>{if(JSON.stringify(a)!==JSON.stringify(b))throw Error("assert "+JSON.stringify(a)+" != "+JSON.stringify(b))};
 function mock({enabled=true,lost=false,race=false,receiptFail=false,revoked=false,wrongTree=false,compareAhead=false}={}){
  let current=P,recorded=null,checks=0,patches=0,trees=[],calls=[];
  const request=async ({method,path,body})=>{
   if(!path.startsWith("/repos/nohutfalafel/qr-menu/"))throw Error("wrong repo");
   calls.push({method,path,body});const p=path.slice("/repos/nohutfalafel/qr-menu".length);
   if(p==="/git/ref/heads/main")return {ref:"refs/heads/main",object:{sha:current,type:"commit"}};
   if(p==="/git/commits/"+P)return {sha:P,tree:{sha:B}};
   if(p.startsWith("/contents/")){
    const name=p.split("?")[0].slice(10);equal(p.split("?")[1],"ref="+P);
    return {type:"file",path:name,encoding:"base64",sha:name===managed?R:M,content:name===managed?"CATALOG":"MARKER"};
   }
   if(p==="/git/trees"&&method==="POST"){trees=body.tree;equal(body.base_tree,B);return {sha:T,tree:[{path:managed,type:"blob",sha:N}]};}
   if(p==="/git/commits"&&method==="POST"){equal(body.parents,[P]);return {sha:C,tree:{sha:wrongTree?X:T},parents:[{sha:P}]};}
   if(p==="/git/commits/"+C)return {sha:C,tree:{sha:T},parents:[{sha:P}],message:"cms: Nohut POS QR publication "+requestId};
   if(p==="/git/refs/heads/main"&&method==="PATCH"){
    patches++;if(!recorded)throw Error("no receipt");equal(body,{sha:C,force:false});
    if(race){current=X;throw Error("nonfastforward");}current=C;if(lost)throw Error("lost response");return {ref:"refs/heads/main",object:{sha:C}};
   }
   if(p==="/compare/"+C+"..."+X)return {status:compareAhead?"ahead":"diverged",merge_base_commit:{sha:compareAhead?C:P}};
   throw Error("unexpected "+method+" "+path);
  };
  const a=makePublishAdapter({request,validateCatalog:v=>{if(!Array.isArray(v.products))throw Error("invalid_catalog")},decodeBase64:x=>JSON.stringify(x==="CATALOG"?old:{schemaVersion:1,enabled})});
  const auth=async()=>{checks++;if(revoked&&checks>=3)throw Error("revoked")};
  const prepare=(over={})=>a.prepare({requestId,expectedRevision:R,catalog:candidate,assertAuthorized:auth,recordPrepared:async x=>{if(receiptFail)throw Error("receipt_failed");recorded=x},...over});
  return {a,prepare,auth,state:()=>({current,recorded,checks,patches,trees,calls}),setHead:x=>current=x};
 }
 async function rejects(f,msg){try{await f()}catch(e){equal(e.message,msg);return}throw Error("expected "+msg);}
 const passed=[];async function test(name,f){await f();passed.push(name)}
 await test("atomic publish",async()=>{let m=mock();let p=await m.prepare();equal(m.state().patches,0);equal(m.state().recorded.commit,C);equal(m.state().trees.map(x=>x.path),[managed]);let r=await m.a.publishPrepared(p,{assertAuthorized:m.auth});equal(r.status,"committed");equal(r.pages,"unverified");equal(m.state().patches,1)});
 await test("stale revision",async()=>{let m=mock();await rejects(()=>m.prepare({expectedRevision:X}),"revision_conflict");equal(m.state().trees,[])});
 await test("activation denied",async()=>{let m=mock({enabled:false});await rejects(()=>m.prepare(),"activation_confirmation_required");equal(m.state().trees,[])});
 await test("atomic activation",async()=>{let m=mock({enabled:false});await m.prepare({activateConfirmed:true});equal(m.state().trees.map(x=>x.path),[managed,marker])});
 await test("no change",async()=>{let m=mock();equal((await m.prepare({catalog:old})).status,"no_change");equal(m.state().trees,[])});
 await test("receipt failure",async()=>{let m=mock({receiptFail:true});await rejects(()=>m.prepare(),"receipt_failed");equal(m.state().patches,0)});
 await test("revoked before update",async()=>{let m=mock({revoked:true});let p=await m.prepare();await rejects(()=>m.a.publishPrepared(p,{assertAuthorized:m.auth}),"revoked");equal(m.state().patches,0)});
 await test("lost response",async()=>{let m=mock({lost:true});let p=await m.prepare();equal((await m.a.publishPrepared(p,{assertAuthorized:m.auth})).status,"unknown");equal((await m.a.reconcile(p)).status,"committed");equal(m.state().patches,1)});
 await test("head moved before update",async()=>{let m=mock();let p=await m.prepare();m.setHead(X);equal((await m.a.publishPrepared(p,{assertAuthorized:m.auth})).status,"unknown");equal(m.state().patches,0)});
 await test("concurrent ref rejection",async()=>{let m=mock({race:true});let p=await m.prepare();equal((await m.a.publishPrepared(p,{assertAuthorized:m.auth})).status,"unknown");equal((await m.a.reconcile(p)).status,"unknown");equal(m.state().patches,1);equal(m.state().current,X)});
 await test("later head contains commit",async()=>{let m=mock({compareAhead:true});let p=await m.prepare();await m.a.publishPrepared(p,{assertAuthorized:m.auth});m.setHead(X);equal((await m.a.reconcile(p)).status,"committed")});
 await test("unexpected commit tree",async()=>{let m=mock({wrongTree:true});await rejects(()=>m.prepare(),"unverifiable_commit");equal(m.state().patches,0)});
 await test("bad identifier",async()=>{let m=mock();await rejects(()=>m.prepare({requestId:"x"}),"invalid_execution");equal(m.state().calls.length,0)});
 return passed;
}
const results=await runChecks(makePublishAdapter);console.log(`${results.length} atomic publish checks passed`);
