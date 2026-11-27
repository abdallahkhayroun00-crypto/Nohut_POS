import {makeGitHubRequest} from './github-http.mjs';
async function runTransportChecks(makeGitHubRequest){
 const sha="a".repeat(40),root="/repos/nohutfalafel/qr-menu",calls=[];
 const fetchImpl=async(url,options)=>{calls.push({url,options});return {ok:false}};
 const make=mode=>makeGitHubRequest({token:"synthetic-token-not-a-real-secret",mode,fetchImpl,timeoutSignal:()=>null});
 const equal=(a,b)=>{if(a!==b)throw Error("assertion")};const passed=[];
 async function test(name,fn){await fn();passed.push(name)}
 async function rejects(fn,msg){try{await fn()}catch(e){equal(e.message,msg);return}throw Error("expected "+msg)}
 await test("fixed read endpoint and no redirect",async()=>{await rejects(()=>make("read")({method:"GET",path:root+"/git/ref/heads/main"}),"github_http_error");equal(calls[0].url,"https://api.github.com"+root+"/git/ref/heads/main");equal(calls[0].options.redirect,"error")});
 await test("wrong repo",()=>rejects(()=>make("write")({method:"GET",path:"/repos/other/repo/git/ref/heads/main"}),"git_target_denied"));
 await test("wrong branch",()=>rejects(()=>make("read")({method:"GET",path:root+"/git/ref/heads/dev"}),"git_target_denied"));
 await test("read scope cannot write",()=>rejects(()=>make("read")({method:"PATCH",path:root+"/git/refs/heads/main",body:{sha,force:false}}),"git_write_denied"));
 await test("force prohibited",()=>rejects(()=>make("write")({method:"PATCH",path:root+"/git/refs/heads/main",body:{sha,force:true}}),"git_ref_denied"));
 await test("unknown path prohibited",()=>rejects(()=>make("write")({method:"POST",path:root+"/git/trees",body:{base_tree:sha,tree:[{path:"index.html",content:"x",type:"blob",mode:"100644"}]}}),"git_tree_denied"));
 await test("marker cannot disable",()=>rejects(()=>make("write")({method:"POST",path:root+"/git/trees",body:{base_tree:sha,tree:[{path:"cms/pos-managed-menu.json",content:"{}",type:"blob",mode:"100644"},{path:"cms/pos-managed-status.json",content:'{"schemaVersion":1,"enabled":false}',type:"blob",mode:"100644"}]}}),"git_marker_denied"));
 await test("nonforce ref request",async()=>{await rejects(()=>make("write")({method:"PATCH",path:root+"/git/refs/heads/main",body:{sha,force:false}}),"github_http_error");equal(JSON.parse(calls.at(-1).options.body).force,false)});
 equal(calls.length,2);return passed;
}
const results=await runTransportChecks(makeGitHubRequest);console.log(`${results.length} transport checks passed`);
