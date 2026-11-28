import {inspectQrImage,qrImagePath} from './image-validation.mjs';
function imageChecks(inspectQrImage,qrImagePath){
 const arr=(...x)=>new Uint8Array(x);
 const png=arr(137,80,78,71,13,10,26,10,0,0,0,13,73,72,68,82,0,0,0,2,0,0,0,3,8,2,0,0,0,0,0,0,0,0,0,0,1,73,68,65,84,1,0,0,0,0,0,0,0,0,73,69,78,68,0,0,0,0);
 const jpg=arr(255,216,255,192,0,11,8,0,3,0,2,1,1,17,0,255,218,0,8,1,1,0,0,63,0,1,255,217);
 const webp=arr(82,73,70,70,18,0,0,0,87,69,66,80,86,80,56,76,5,0,0,0,47,1,128,0,0,0);
 let passed=0;
 const eq=(a,b)=>{if(a!==b)throw Error("unexpected "+a);};
 const reject=f=>{try{f()}catch{passed++;return}throw Error("expected rejection")};
 for(const [bytes,mime,ext] of [[png,"image/png","png"],[jpg,"image/jpeg","jpg"],[webp,"image/webp","webp"]]){const v=inspectQrImage(bytes,mime);eq(v.width,2);eq(v.height,3);eq(v.extension,ext);eq(qrImagePath(v,"a".repeat(64)),"assets/products/pos-"+"a".repeat(64)+"."+ext);passed++}
 reject(()=>inspectQrImage(png,"image/jpeg"));
 reject(()=>inspectQrImage(png,"image/svg+xml"));
 reject(()=>inspectQrImage(png.slice(0,-1),"image/png"));
 reject(()=>inspectQrImage(jpg.slice(0,-2),"image/jpeg"));
 reject(()=>inspectQrImage(webp.slice(0,-1),"image/webp"));
 const huge=png.slice();huge[18]=32;reject(()=>inspectQrImage(huge,"image/png"));
 reject(()=>inspectQrImage(new Uint8Array(6000001),"image/png"));
 reject(()=>qrImagePath({extension:"png"},"../x"));
 reject(()=>qrImagePath({extension:"svg"},"a".repeat(64)));
 return passed;
}
console.log(`${imageChecks(inspectQrImage,qrImagePath)} image preflight checks passed`);
