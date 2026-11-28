// Structural preflight only: no decompression, CRC or full image decoding.
// Require independent sandboxed decoder/re-encode before staging/publishing.
export function inspectQrImage(bytes,mime){
 const fail=()=>{throw Error("invalid_image")};
 if(!(bytes instanceof Uint8Array)||bytes.length<12||bytes.length>6000000)fail();
 const n=bytes.length,b=bytes,ascii=(o,s)=>o+s.length<=n&&[...s].every((c,i)=>b[o+i]===c.charCodeAt(0));
 const be16=o=>b[o]*256+b[o+1],be32=o=>b[o]*16777216+b[o+1]*65536+b[o+2]*256+b[o+3];
 const le24=o=>b[o]+256*b[o+1]+65536*b[o+2],le32=o=>le24(o)+16777216*b[o+3];
 let w,h,ext;
 if(mime==="image/png"){
  ext="png";
  if(![137,80,78,71,13,10,26,10].every((v,i)=>b[i]===v)||n<45||be32(8)!==13||!ascii(12,"IHDR"))fail();
  w=be32(16);h=be32(20);
  let o=8,first=true,data=false,ended=false;
  while(o+12<=n){
   const len=be32(o);if(len>n-o-12)fail();
   if(!first&&ascii(o+4,"IHDR"))fail();
   if(ascii(o+4,"acTL")||ascii(o+4,"fcTL")||ascii(o+4,"fdAT"))fail();
   if(ascii(o+4,"IDAT")&&len>0)data=true;
   if(ascii(o+4,"IEND")){if(len!==0||o+12!==n||!data)fail();ended=true;break}
   first=false;o+=len+12;
  }
  if(!ended)fail();
 }else if(mime==="image/jpeg"){
  ext="jpg";
  if(b[0]!==255||b[1]!==216||b[n-2]!==255||b[n-1]!==217)fail();
  let o=2,scan=false;
  while(o<n-2){
   if(b[o++]!==255)fail();while(o<n&&b[o]===255)o++;
   if(o>=n)fail();const m=b[o++];
   if(m===0||m===216||m===217||m===1||(m>=208&&m<=215))fail();
   if(o+2>n)fail();const len=be16(o);if(len<2||o+len>n-2)fail();
   if([192,193,194].includes(m)){
    if(w!==undefined||len<8||b[o+2]!==8)fail();
    h=be16(o+3);w=be16(o+5);
   }
   if(m===218){if(w===undefined||len<6||o+len>=n-2)fail();scan=true;break}
   o+=len;
  }
  if(!scan)fail();
 }else if(mime==="image/webp"){
  ext="webp";
  if(!ascii(0,"RIFF")||!ascii(8,"WEBP")||le32(4)!==n-8)fail();
  let o=12,frames=0,canvas,frame;
  while(o+8<=n){
   const len=le32(o+4),p=o+8,end=p+len+(len%2);if(end>n)fail();
   if(ascii(o,"ANIM")||ascii(o,"ANMF"))fail();
   if(ascii(o,"VP8X")){
    if(o!==12||len!==10||(b[p]&2)!==0)fail();
    canvas=[le24(p+4)+1,le24(p+7)+1];
   }else if(ascii(o,"VP8 ")){
    if(++frames!==1||len<10||(b[p]&1)!==0||b[p+3]!==157||b[p+4]!==1||b[p+5]!==42)fail();
    frame=[(b[p+6]+256*b[p+7])&16383,(b[p+8]+256*b[p+9])&16383];
   }else if(ascii(o,"VP8L")){
    if(++frames!==1||len<5||b[p]!==47||(b[p+4]&224)!==0)fail();
    frame=[1+b[p+1]+((b[p+2]&63)<<8),1+(b[p+2]>>6)+(b[p+3]<<2)+((b[p+4]&15)<<10)];
   }
   o=end;
  }
  if(o!==n||frames!==1||!frame||canvas&&canvas.some((v,i)=>v!==frame[i]))fail();
  [w,h]=frame;
 }else fail();
 if(!Number.isSafeInteger(w)||!Number.isSafeInteger(h)||w<1||h<1||w>4096||h>4096||w*h>12000000)fail();
 return {mime,extension:ext,width:w,height:h,size:n};
}
export function qrImagePath(info,digest){
 if(!info||!["png","jpg","webp"].includes(info.extension)||typeof digest!=="string"||digest.length!==64||!/^[a-f0-9]+$/.test(digest))throw Error("invalid_image_digest");
 return "assets/products/pos-"+digest+"."+info.extension;
}
