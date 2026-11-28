// Dedicated direct database transport. No credentials in URI, SQL or logs.
// Driver injected for tests; production entrypoint pins the implementation.
const allowed = new Map([
  [
    "select nohut_qr_edge.qr_publish_bind_draft($1::text,$2::text,$3::bigint,$4::text,$5::text,$6::text,$7::text) as value",
    7
  ],
  [
    "select nohut_qr_edge.qr_recovery_authority($1::text,$2::text,$3::bigint,$4::text) as value",
    4
  ],
  [
    "select nohut_qr_edge.qr_publish_claim($1::text,$2::text,$3::bigint,$4::text,$5::text,$6::text,$7::text,$8::text) as value",
    8
  ],
  [
    "select nohut_qr_edge.qr_publish_transition($1::text,$2::text,$3::bigint,$4::text,$5::text,$6::uuid,$7::text,$8::text,$9::text,$10::text,$11::text,$12::text,$13::text,$14::text) as value",
    14
  ],
  [
    "select nohut_qr_edge.qr_publish_recover($1::text,$2::text,$3::bigint,$4::text,$5::text,$6::text,$7::text,$8::text) as value",
    8
  ]
]);
export function makeDatabaseTransport({env,postgres}){
 if(typeof env!=="function"||typeof postgres!=="function")throw Error("invalid_db_dependencies");
 let client;
 function connect(){
  if(client)return client;
  const password=env("NOHUT_QR_DB_PASSWORD"),ca=env("NOHUT_QR_DB_CA");
  if(typeof password!=="string"||password.length<32||typeof ca!=="string"||!ca.includes("-----BEGIN CERTIFICATE-----")||ca.length>32768)throw Error("database_configuration_missing");
  client=postgres({
   host:"db.bccwdutmrkptupiwbnwf.supabase.co",port:5432,database:"postgres",username:"nohut_qr_runtime",password,
   ssl:{ca,rejectUnauthorized:true},prepare:false,max:1,connect_timeout:8,idle_timeout:10,max_lifetime:120,
   debug:false,onnotice:()=>{},connection:{application_name:"nohut_qr_publisher",statement_timeout:"10000",lock_timeout:"3000"}
  });
  return client;
 }
 async function query(sql,params){
  if(!allowed.has(sql)||!Array.isArray(params)||params.length!==allowed.get(sql)||params.some(x=>x!==null&&typeof x!=="string"&&!Number.isSafeInteger(x)))throw Error("database_query_denied");
  try{
   // The driver resolves begin only after COMMIT, so receipt ACK is durable.
   return await connect().begin(async tx=>{
    const identity=await tx.unsafe("select session_user::text as login, current_user::text as role, exists(select 1 from pg_catalog.pg_stat_ssl where pid=pg_backend_pid() and ssl) as tls, exists(select 1 from pg_catalog.pg_roles where rolname=current_user and not rolsuper and not rolbypassrls and not rolcreaterole and not rolcreatedb and not rolreplication) as restricted");
    const i=identity[0];
    if(identity.length!==1||i?.login!=="nohut_qr_runtime"||i.role!=="nohut_qr_runtime"||i.tls!==true||i.restricted!==true)throw Error("database_identity_denied");
    const rows=await tx.unsafe(sql,params,{prepare:false});
    if(rows.length!==1||!Object.hasOwn(rows[0],"value"))throw Error("database_result_invalid");
    return rows[0].value;
   });
  }catch{throw Error("database_operation_failed")}
 }
 async function close(){if(client){const c=client;client=undefined;await c.end({timeout:2})}}
 return {query,close};
}
