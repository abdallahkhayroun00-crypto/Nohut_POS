// Experimental adapter only. Do not import into the production entrypoint
// until hosted Edge CPU/memory, codec security and dependency lock are reviewed.
import {ImageMagick,initializeImageMagick,MagickFormat} from "npm:@imagemagick/magick-wasm@0.0.43";
import {makeImageNormalizer} from "./image-normalization.mjs";

const wasmBytes=await Deno.readFile(new URL("magick.wasm",import.meta.resolve("npm:@imagemagick/magick-wasm@0.0.43")));
await initializeImageMagick(wasmBytes);
export function decodeToPng(bytes:Uint8Array,mime:string,info:{width:number;height:number}):Uint8Array {
 const format=mime==="image/png"?MagickFormat.Png:mime==="image/jpeg"?MagickFormat.Jpeg:mime==="image/webp"?MagickFormat.WebP:undefined;
 if(format===undefined)throw Error("unsupported_decoder_format");
 return ImageMagick.read(bytes,format,img=>{
  if(img.width!==info.width||img.height!==info.height||img.width*img.height>4000000)throw Error("decoder_dimensions_mismatch");
  img.autoOrient();
  if(img.width*img.height>4000000)throw Error("decoder_dimensions_mismatch");
  return img.write(MagickFormat.Png,data=>Uint8Array.from(data));
 });
}
export const normalizeQrImage=makeImageNormalizer({decodeToPng});
