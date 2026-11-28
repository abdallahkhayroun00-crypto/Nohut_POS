import {createHash} from "node:crypto";
import {Buffer} from "node:buffer";
import {inspectQrImage,qrImagePath} from "./image-validation.mjs";

// Isolated prepare-only port. The caller must durably pin the staged image
// to this exact publication and enforce tenant/target/expiry in storage.
// No ref mutation, no decoder, no public route, no production transport.
export function makeAssetTreePlanner({loadPinnedImage,request,assertAuthorized}){
 if([loadPinnedImage,request,assertAuthorized].some(x=>typeof x!=="function"))throw Error("missing_asset_dependency");
 const managedPath=x=>typeof x==="string"&&/^assets\/products\/pos-[a-f0-9]{64}\.(png|jpg|webp)$/.test(x);
 const sha=x=>typeof x==="string"&&x.length===40&&/^[a-f0-9]+$/.test(x);
 const root="/repos/nohutfalafel/qr-menu";
 return async function prepareAssets({requestId,previous,catalog,parentTree}){
  if(!sha(parentTree)||typeof requestId!=="string"||!Array.isArray(previous?.products)||!Array.isArray(catalog?.products))throw Error("invalid_asset_plan");
  // Campaign upload is not yet authorized. Existing legacy paths can remain,
  // but a new or changed reference must be handled by a reviewed route.
  const oldCampaign=new Map((previous.campaigns??[]).map(c=>[c.id,c]));
  for(const c of catalog.campaigns??[])for(const k of ["poster","thumbnail"]){
   if(c[k]!=null&&c[k]!==oldCampaign.get(c.id)?.[k])throw Error("campaign_asset_not_supported");
  }
  const old=new Map(previous.products.map(p=>[p.id,p.image]));
  const refs=new Map();
  for(const p of catalog.products){
   if(p.image==null||p.image===old.get(p.id))continue;
   if(!managedPath(p.image))throw Error("new_asset_path_denied");
   if(refs.has(p.image))throw Error("shared_new_asset_not_supported");
   refs.set(p.image,p.id);
  }
  if(refs.size>4)throw Error("asset_count_exceeded");
  if(!refs.size)return [];
  await assertAuthorized();
  const parent=await request({method:"GET",path:root+"/git/trees/"+parentTree+"?recursive=1"});
  if(parent?.sha!==parentTree||parent.truncated!==false||!Array.isArray(parent.tree))throw Error("unverifiable_parent_tree");
  const result=[];let total=0;
  // Validate every staged entry before creating any blob.
  const ready=[];
  for(const [path,id] of refs){
   const stage=await loadPinnedImage({requestId,productId:id,path});
   if(!stage||stage.requestId!==requestId||stage.productId!==id||stage.path!==path||!(stage.bytes instanceof Uint8Array))throw Error("asset_pin_mismatch");
   const bytes=Buffer.from(stage.bytes);
   const info=inspectQrImage(bytes,stage.mime);
   const digest=createHash("sha256").update(bytes).digest("hex");
   if(stage.sha256!==digest||qrImagePath(info,digest)!==path)throw Error("asset_digest_mismatch");
   total+=bytes.length;if(total>24000000)throw Error("asset_quota_exceeded");
   const blob=createHash("sha1").update("blob "+bytes.length+"\0").update(bytes).digest("hex");
   const existing=parent.tree.filter(x=>x.path===path);
   if(existing.length>1||existing.length===1&&(existing[0].type!=="blob"||existing[0].mode!=="100644"||existing[0].sha!==blob))throw Error("asset_path_conflict");
   if(!existing.length)ready.push({path,blob,bytes});
  }
  for(const e of ready){
   await assertAuthorized();
   const b=await request({method:"POST",path:root+"/git/blobs",body:{encoding:"base64",content:e.bytes.toString("base64")}});
   if(b?.sha!==e.blob)throw Error("asset_blob_mismatch");
   result.push({path:e.path,mode:"100644",type:"blob",sha:e.blob});
  }
  return result;
 };
}
