// Fetch-compatible HTTP boundary. No Deno.serve; the production entrypoint
// must supply a reviewed dedicated DB role and a disabled-by-default gate.
export function makePublisherHttpHandler({dispatch,enabled=()=>false,maxBytes=1600000}){
 if(typeof dispatch!=="function"||typeof enabled!=="function"||!Number.isSafeInteger(maxBytes)||maxBytes<1||maxBytes>2000000)throw Error("invalid_http_configuration");
 const json=(status,body)=>new Response(JSON.stringify(body),{status,headers:{"content-type":"application/json; charset=utf-8","cache-control":"no-store","x-content-type-options":"nosniff"}});
 return async function handle(req){
  if(req.method!=="POST")return json(405,{error:"method_not_allowed"});
  if(enabled()!==true)return json(503,{error:"publisher_disabled"});
  // Opaque agent credential is independent of the Supabase gateway key.
  // Never accept a client-supplied service role or GitHub credential.
  const token=req.headers.get("x-nohut-agent-token")??"";
  if(!/^[a-f0-9]{64}$/.test(token))return json(401,{error:"unauthorized"});
  if(!/^application\/json(?:\s*;\s*charset=utf-8)?$/i.test(req.headers.get("content-type")??""))return json(415,{error:"unsupported_content_type"});
  if(req.headers.has("content-encoding")&&req.headers.get("content-encoding")!=="identity")return json(415,{error:"unsupported_encoding"});
  const length=req.headers.get("content-length");
  if(length!==null&&(!/^\d+$/.test(length)||Number(length)>maxBytes))return json(413,{error:"request_too_large"});
  const reader=req.body?.getReader();if(!reader)return json(400,{error:"invalid_request"});
  let total=0,bodyText="";
  const decoder=new TextDecoder("utf-8",{fatal:true});
  try{
   while(true){
    const part=await reader.read();if(part.done)break;
    total+=part.value.byteLength;
    if(total>maxBytes){await reader.cancel();return json(413,{error:"request_too_large"})}
    bodyText+=decoder.decode(part.value,{stream:true});
   }
   bodyText+=decoder.decode();
  }catch{return json(400,{error:"invalid_request"})}finally{reader.releaseLock()}
  let body;try{body=JSON.parse(bodyText)}catch{return json(400,{error:"invalid_request"})}
  try{
   const result=await dispatch({method:"POST",token,body});
   if(!result||![200,400,401,403,404,405,409,503].includes(result.status)||!result.body||typeof result.body!=="object")return json(503,{error:"publisher_unavailable"});
   return json(result.status,result.body);
  }catch{return json(503,{error:"publisher_unavailable"})}
 };
}
