// Actual compressed raster fixtures generated in memory; no customer images.
import assert from "node:assert/strict";
import {Buffer} from "node:buffer";
import {createHash} from "node:crypto";
import {deflateSync,inflateSync} from "node:zlib";
import {ImageMagick,MagickFormat} from "npm:@imagemagick/magick-wasm@0.0.43";
import {normalizeQrImage} from "./image-wasm.review.ts";
import {crc32} from "./image-normalization.mjs";

function chunk(type:string,data:Uint8Array){
 const name=Buffer.from(type),out=Buffer.alloc(12+data.length);
 out.writeUInt32BE(data.length);name.copy(out,4);out.set(data,8);
 out.writeUInt32BE(crc32(out.subarray(4,out.length-4)),out.length-4);return out;
}
const ihdr=Buffer.alloc(13);ihdr.writeUInt32BE(3,0);ihdr.writeUInt32BE(2,4);ihdr[8]=8;ihdr[9]=2;
const pixels=Buffer.from([0,255,0,0,0,255,0,0,0,255,0,255,0,0,0,255,0,0,0,255]);
const privateText="synthetic-private-location-not-real";
const makePng=(compressed:Uint8Array)=>Buffer.concat([Buffer.from("89504e470d0a1a0a","hex"),chunk("IHDR",ihdr),chunk("tEXt",Buffer.from("Comment\0"+privateText)),chunk("IDAT",compressed),chunk("IEND",new Uint8Array())]);
const png=makePng(deflateSync(pixels));
assert.deepEqual(inflateSync(deflateSync(pixels)),pixels);
const hash=(x:Uint8Array)=>createHash("sha256").update(x).digest("hex");
for(const [mime,format] of [["image/png",MagickFormat.Png],["image/jpeg",MagickFormat.Jpeg],["image/webp",MagickFormat.WebP]] as const){
 const bytes=mime==="image/png"?png:ImageMagick.read(png,MagickFormat.Png,img=>img.write(format,d=>Uint8Array.from(d)));
 const result=await normalizeQrImage({bytes,mime,expectedSourceSha256:hash(bytes)});
 assert.equal(result.mime,"image/png");assert.equal(result.sourceMime,mime);
 assert.equal(result.width,3);assert.equal(result.height,2);
 assert.equal(result.sha256,hash(result.bytes));assert.equal(result.path,"assets/products/pos-"+hash(result.bytes)+".png");
 assert.ok(!Buffer.from(result.bytes).includes(privateText));
 assert.ok(!Buffer.from(result.bytes).includes("tEXt"));
 // Decode the normalized compressed pixels a second time.
 ImageMagick.read(result.bytes,MagickFormat.Png,img=>{assert.equal(img.width,3);assert.equal(img.height,2)});
}
await assert.rejects(()=>normalizeQrImage({bytes:png,mime:"image/png",expectedSourceSha256:"0".repeat(64)}),{message:"image_normalization_failed"});
const corrupt=Buffer.from(png);corrupt[29]^=1;
await assert.rejects(()=>normalizeQrImage({bytes:corrupt,mime:"image/png",expectedSourceSha256:hash(corrupt)}),{message:"image_normalization_failed"});
const corruptData=makePng(Buffer.from([1,2,3,4,5,6,7,8]));
await assert.rejects(()=>normalizeQrImage({bytes:corruptData,mime:"image/png",expectedSourceSha256:hash(corruptData)}),{message:"image_normalization_failed"});
await assert.rejects(()=>normalizeQrImage({bytes:png,mime:"image/svg+xml",expectedSourceSha256:hash(png)}),{message:"image_normalization_failed"});
console.log("7 WASM normalization cases passed: PNG/JPEG/WebP, metadata exclusion, re-decode, source digest, CRC, invalid compressed data and format");
