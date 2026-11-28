import assert from "node:assert/strict";
import {createHash} from "node:crypto";
import {Buffer} from "node:buffer";
import {makeAssetTreePlanner} from "./asset-tree-planner.mjs";
import {makePublishAdapter} from "./git-data-publish.mjs";
// Structural fixture only, not a decoded image. Real normalization is a release gate.
const bytes=Buffer.from("89504e470d0a1a0a0000000d494844520000000200000003080200000000000000000000014944415401000000000000000049454e4400000000","hex");
const digest=createHash("sha256").update(bytes).digest("hex");
const blob=createHash("sha1").update("blob "+bytes.length+"\0").update(bytes).digest("hex");
const path="assets/products/pos-"+digest+".png",managed="cms/pos-managed-menu.json";
const id="12345678-1234-4234-8234-123456789abc",P="1".repeat(40),B="2".repeat(40),R="3".repeat(40),T="4".repeat(40),C="5".repeat(40),N="6".repeat(40);
const previous={products:[{id:1,image:null}],campaigns:[]},catalog={products:[{id:1,image:path}],campaigns:[]};
function fixture({pin={},existing=[],wrongBlob=false,wrongTree=false,lost=false,disabled=false}={}){
 let head=P,receipt=null,tree=[],calls=[],patches=0;
 const request=async x=>{
  calls.push(x);const p=x.path.replace("/repos/nohutfalafel/qr-menu","");
  if(p==="/git/ref/heads/main")return {ref:"refs/heads/main",object:{type:"commit",sha:head}};
  if(p==="/git/commits/"+P)return {sha:P,tree:{sha:B}};
  if(p.startsWith("/contents/"))return {type:"file",path:p.split("?")[0].slice(10),encoding:"base64",sha:R,content:p.includes("status")?"marker":"menu"};
  if(p==="/git/trees/"+B+"?recursive=1")return {sha:B,truncated:false,tree:existing};
  if(p==="/git/blobs"){assert.equal(x.body.content,bytes.toString("base64"));return {sha:wrongBlob?N:blob}}
  if(p==="/git/trees"&&x.method==="POST"){tree=x.body.tree;return {sha:T,tree:[{path:managed,type:"blob",sha:N}]}}
  if(p==="/git/trees/"+T+"?recursive=1")return {sha:T,truncated:false,tree:[{path:managed,type:"blob",sha:N},...tree.filter(e=>e.sha).map(e=>({...e,sha:wrongTree?N:e.sha}))]};
  if(p==="/git/commits"&&x.method==="POST"){assert.equal(x.body.tree,T);return {sha:C,tree:{sha:T},parents:[{sha:P}]}}
  if(p==="/git/commits/"+C)return {sha:C,tree:{sha:T},parents:[{sha:P}],message:"cms: Nohut POS QR publication "+id};
  if(p==="/git/refs/heads/main"){assert.ok(receipt);assert.equal(x.body.force,false);patches++;head=C;if(lost)throw Error("lost ack");return {ref:"refs/heads/main",object:{sha:C}}}
  throw Error("unexpected "+p);
 };
 const assertAuthorized=async()=>{};
 const prepareAssets=makeAssetTreePlanner({request,assertAuthorized,loadPinnedImage:async()=>({requestId:id,productId:1,path,sha256:digest,mime:"image/png",bytes,...pin})});
 const adapter=makePublishAdapter({request,validateCatalog:()=>{},decodeBase64:x=>JSON.stringify(x==="marker"?{schemaVersion:1,enabled:true}:previous),prepareAssets:disabled?undefined:prepareAssets});
 return {adapter,prepare:()=>adapter.prepare({requestId:id,expectedRevision:R,catalog,assertAuthorized,recordPrepared:async x=>{receipt=x}}),publish:p=>adapter.publishPrepared(p,{assertAuthorized}),state:()=>({head,receipt,tree,calls,patches})};
}
const f=fixture(),p=await f.prepare();
assert.equal(f.state().head,P);
assert.equal(f.state().patches,0);
assert.deepEqual(f.state().tree.map(e=>e.path),[managed,path]);
assert.equal(f.state().tree[1].sha,blob);
assert.equal((await f.publish(p)).status,"committed");
assert.equal(f.state().patches,1);
const lost=fixture({lost:true}),lp=await lost.prepare();
assert.equal((await lost.publish(lp)).status,"unknown");
assert.equal((await lost.adapter.reconcile(lp)).status,"committed");
assert.equal(lost.state().patches,1);
for(const [cfg,reason] of [
 [{disabled:true},"asset_publication_disabled"],
 [{pin:{productId:2}},"asset_pin_mismatch"],
 [{pin:{sha256:N}},"asset_digest_mismatch"],
 [{existing:[{path,type:"blob",mode:"100644",sha:N}]},"asset_path_conflict"],
 [{wrongBlob:true},"asset_blob_mismatch"],
 [{wrongTree:true},"asset_tree_mismatch"]
]){
 const x=fixture(cfg);await assert.rejects(()=>x.prepare(),{message:reason});assert.equal(x.state().patches,0);assert.equal(x.state().receipt,null);
}
const existing=fixture({existing:[{path,type:"blob",mode:"100644",sha:blob}]});
await existing.prepare();assert.equal(existing.state().calls.filter(x=>x.path.endsWith("/git/blobs")).length,0);
console.log("9 atomic asset preparation checks passed (mock GitHub, structural image fixture)");
