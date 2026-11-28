// Disposable CI only: the injected test factory maps the production host to loopback.
import postgres from "postgres";
import {readFileSync} from "node:fs";
import assert from "node:assert/strict";
import {makeDatabaseTransport} from "./database-transport.mjs";
const ca=readFileSync(process.env.QR_TEST_CA,"utf8");
const password="synthetic-ci-runtime-password-not-production";
const sql="select nohut_qr_edge.qr_recovery_authority($1::text,$2::text,$3::bigint,$4::text) as value";
const params=["synthetic-token","request",1,"hash"];
const factory=over=>options=>postgres({...options,host:"127.0.0.1",port:5432,...over});
const env=k=>k==="NOHUT_QR_DB_PASSWORD"?password:k==="NOHUT_QR_DB_CA"?ca:undefined;
const good=makeDatabaseTransport({env,postgres:factory({})});
try{assert.equal(await good.query(sql,params),"synthetic-restaurant")}finally{await good.close()}
const wrongCa=makeDatabaseTransport({env,postgres:factory({ssl:{ca:readFileSync(process.env.QR_TEST_WRONG_CA,"utf8"),rejectUnauthorized:true}})});
try{await assert.rejects(()=>wrongCa.query(sql,params),{message:"database_operation_failed"})}finally{await wrongCa.close()}
const plaintext=makeDatabaseTransport({env,postgres:factory({ssl:false})});
try{await assert.rejects(()=>plaintext.query(sql,params),{message:"database_operation_failed"})}finally{await plaintext.close()}
console.log("Disposable PostgreSQL real TLS: verified certificate, wrong CA denied, plaintext denied");
