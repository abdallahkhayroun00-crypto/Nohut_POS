import {makeDatabaseTransport} from "./database-transport.mjs";
import assert from "node:assert/strict";
const sql="select nohut_qr_edge.qr_recovery_authority($1::text,$2::text,$3::bigint,$4::text) as value";
const params=["synthetic-token","synthetic-request",1,"synthetic-hash"];
function fixture({identity={},commitFail=false,missing=false}={}){
 let config,queries=[],commits=0,closed=0;
 const env=k=>missing?undefined:k==="NOHUT_QR_DB_PASSWORD"?"synthetic-password-not-real-123456789":k==="NOHUT_QR_DB_CA"?"-----BEGIN CERTIFICATE-----\nsynthetic\n-----END CERTIFICATE-----":undefined;
 const postgres=options=>{config=options;return {async begin(fn){const value=await fn({async unsafe(q,p){queries.push({q,p});return q.startsWith("select session_user")?[{login:"nohut_qr_runtime",role:"nohut_qr_runtime",tls:true,restricted:true,...identity}]:[{value:"synthetic-restaurant"}]}});if(commitFail)throw Error("sensitive commit exception");commits++;return value},async end(){closed++}}};
 return {db:makeDatabaseTransport({env,postgres}),state:()=>({config,queries,commits,closed})};
}
const f=fixture();
assert.equal(await f.db.query(sql,params),"synthetic-restaurant");
assert.equal(f.state().config.ssl.rejectUnauthorized,true);
assert.equal(f.state().config.username,"nohut_qr_runtime");
assert.equal(f.state().config.prepare,false);
assert.deepEqual(f.state().queries[1].p,params);
assert.equal(f.state().commits,1);
await f.db.close();assert.equal(f.state().closed,1);
for(const id of [{role:"postgres"},{login:"postgres"},{tls:false},{restricted:false}]){
 const x=fixture({identity:id});await assert.rejects(()=>x.db.query(sql,params),{message:"database_operation_failed"});assert.equal(x.state().queries.length,1);
}
const c=fixture({commitFail:true});await assert.rejects(()=>c.db.query(sql,params),{message:"database_operation_failed"});assert.equal(c.state().commits,0);
const m=fixture({missing:true});await assert.rejects(()=>m.db.query(sql,params),{message:"database_operation_failed"});assert.equal(m.state().queries.length,0);
const i=fixture();await assert.rejects(()=>i.db.query("select * from nohut_private.app_users",[]),{message:"database_query_denied"});await assert.rejects(()=>i.db.query(sql,[]),{message:"database_query_denied"});assert.equal(i.state().config,undefined);
console.log("9 database transport checks passed (mock driver, not live TLS)");
