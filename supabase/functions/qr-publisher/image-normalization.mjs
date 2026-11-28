import {inspectQrImage,qrImagePath} from "./image-validation.mjs";
import {createHash} from "node:crypto";

// PNG output only. Retain pixel-essential chunks and standard numeric
// color interpretation; omit textual, EXIF, XMP, ICC, time and unknown
// ancillary data. Reject malformed or unsupported critical chunks.
const keep=new Set(["IHDR","PLTE","IDAT","IEND","tRNS","sRGB","gAMA","cHRM"]);
const crcTable=Uint32Array.from({length:256},(_,i)=>{
 let c=i;for(let k=0;k<8;k++)c=c&1?0xedb88320^(c>>>1):c>>>1;return c>>>0;
});
export function crc32(bytes){
 let c=0xffffffff;for(const b of bytes)c=crcTable[(c^b)&255]^(c>>>8);return (c^0xffffffff)>>>0;
}
export function cleanPng(bytes){
 inspectQrImage(bytes,"image/png");
 const view=new DataView(bytes.buffer,bytes.byteOffset,bytes.byteLength);
 const chunks=[bytes.slice(0,8)];let o=8,size=8,seenIDAT=false,closedIDAT=false;
 const seen=new Set();
 while(o<bytes.length){
  const len=view.getUint32(o),end=o+12+len;
  if(end>bytes.length)throw Error("invalid_png_chunk");
  const type=String.fromCharCode(...bytes.subarray(o+4,o+8));
  if(!/^[A-Za-z]{4}$/.test(type)||crc32(bytes.subarray(o+4,end-4))!==view.getUint32(end-4))throw Error("invalid_png_crc");
  if(!keep.has(type)&&type[0]===type[0].toUpperCase())throw Error("unknown_critical_png_chunk");
  if(type==="IDAT"){
   if(closedIDAT)throw Error("noncontiguous_png_data");seenIDAT=true;
  }else if(seenIDAT)closedIDAT=true;
  if(keep.has(type)){
   if(type!=="IDAT"&&seen.has(type))throw Error("duplicate_png_chunk");
   seen.add(type);chunks.push(bytes.slice(o,end));size+=end-o;
  }
  o=end;
 }
 const out=new Uint8Array(size);let cursor=0;
 for(const c of chunks){out.set(c,cursor);cursor+=c.length}
 return out;
}

// decoder is a trusted, isolated implementation, not supplied by the caller.
// This function never writes files, storage, GitHub, or logs.
export function makeImageNormalizer({decodeToPng}){
 if(typeof decodeToPng!=="function")throw Error("missing_decoder");
 return async function normalize({bytes,mime,expectedSourceSha256}){
  try{
   if(!(bytes instanceof Uint8Array)||bytes.length>4000000)throw Error("image_input_limit");
   const input=Uint8Array.from(bytes),info=inspectQrImage(input,mime);
   if(info.width*info.height>4000000)throw Error("image_pixel_limit");
   const sourceSha256=createHash("sha256").update(input).digest("hex");
   if(typeof expectedSourceSha256!=="string"||expectedSourceSha256!==sourceSha256)throw Error("source_digest_mismatch");
   if(mime==="image/png")cleanPng(input); // independently validate CRC before decoder
   const decoded=await decodeToPng(input,mime,info);
   if(!(decoded instanceof Uint8Array)||decoded.length>6000000)throw Error("image_output_limit");
   const output=cleanPng(decoded);
   const final=inspectQrImage(output,"image/png");
   if(final.width*final.height>4000000||
      !((final.width===info.width&&final.height===info.height)||(final.width===info.height&&final.height===info.width)))throw Error("decoded_dimensions_mismatch");
   const sha256=createHash("sha256").update(output).digest("hex");
   return {sourceSha256,sourceMime:mime,mime:"image/png",bytes:output,sha256,path:qrImagePath(final,sha256),width:final.width,height:final.height};
  }catch{throw Error("image_normalization_failed")}
 };
}
