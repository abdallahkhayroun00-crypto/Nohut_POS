// TEST ONLY. Localhost + explicit synthetic gate. Never deploy this bridge:
// it stands in for PostgREST/JWT verification against a disposable database.
const {Client}=require('pg');
const http=require('node:http');
const fs=require('node:fs');
const path=require('node:path');
const {randomUUID}=require('node:crypto');
if(process.env.NOHUT_SYNTHETIC_TEST!=='1'||!['127.0.0.1','localhost'].includes(process.env.PGHOST||'127.0.0.1')) {
  throw Error('Synthetic localhost test gate required');
}
const cfg={host:process.env.PGHOST||'127.0.0.1',port:Number(process.env.PGPORT||5432),
  user:process.env.PGUSER||'postgres',password:process.env.PGPASSWORD,database:'postgres'};
const base=path.resolve(__dirname,'..');
const dbname='nohut_test_http_'+Date.now();
const role='nohut_test_owner';
const ids={restaurantId:randomUUID(),authorityEpoch:randomUUID(),userId:randomUUID(),deviceId:randomUUID(),sessionId:randomUUID(),windowsDeviceId:randomUUID(),windowsSessionId:randomUUID()};
const methods={
  nohut_agent_ingest:['p_token','p_tx'],nohut_agent_checkpoint:['p_token'],nohut_agent_claim:['p_token','p_max'],
  nohut_agent_validate_claim:['p_token','p_request','p_generation','p_envelope_sha256'],
  nohut_agent_complete:['p_token','p_request','p_generation','p_envelope_sha256','p_result'],
  nohut_agent_report_receipt:['p_token','p_request','p_envelope_sha256','p_result'],
  nohut_enqueue_command:['p_device_id','p_client','p_permission_version','p_request_id','p_action','p_payload'],
  nohut_command_status:['p_device_id','p_client','p_permission_version','p_request_id'],
  nohut_windows_owner_session:['p_device_id'],
  nohut_enroll_agent:['p_device_id','p_permission_version','p_epoch','p_request_id','p_token_sha256'],
  nohut_revoke_agent:['p_device_id','p_permission_version','p_agent_id'],
  nohut_owner_rotate_authority_epoch:['p_device_id','p_permission_version','p_reason'],
  nohut_agent_begin_initial_sync:['p_token','p_migration_id','p_snapshot_revision','p_snapshot_seq','p_manifest_sha256','p_backup_verified'],
  nohut_agent_upload_snapshot_batch:['p_token','p_migration_id','p_batch_id','p_category','p_item_count','p_body_sha256','p_events'],
  nohut_agent_activate_initial_sync:['p_token','p_migration_id','p_expected_batches','p_expected_manifest_sha256'],
  nohut_agent_migration_status:['p_token','p_migration_id'],
  nohut_daily_report_view:['p_device_id','p_client','p_permission_version','p_day'],
  nohut_notifications_list:['p_device_id','p_client','p_permission_version','p_limit'],
};
let loseAck=false,loseEnrollAck=false;
// Trusted bootstrap exists only in this disposable fixture, never in a client.
async function registerSyntheticWindows(db,restaurant,user,device,session){
  await db.query('begin');
  try{
    await db.query('set local role service_role');
    const ticket=(await db.query('select public.nohut_issue_windows_bootstrap($1) as ticket',[restaurant])).rows[0].ticket;
    await db.query('reset role');
    await db.query('set local role authenticated');
    await db.query("select set_config('request.jwt.claims',$1,true)",[JSON.stringify({sub:user,session_id:session,aal:'aal2'})]);
    await db.query("select public.nohut_register_windows_device($1,'Synthetic Windows',$2)",[device,ticket]);
    await db.query('commit');
  }catch(err){await db.query('rollback');throw err;}
}
// Real independent database connections, including concurrent session_status
// updates. The HTTP request queue itself deliberately remains serialized.
async function verifySetupConcurrency(db){
  const [r,e,u,d,s,q]=Array.from({length:6},()=>randomUUID());
  await db.query('insert into nohut_private.restaurants(restaurant_id) values($1)',[r]);
  await db.query('insert into nohut_private.authority_epochs(restaurant_id,authority_epoch) values($1,$2)',[r,e]);
  await db.query("insert into nohut_private.app_users(user_id,restaurant_id,username,role_template,is_owner) values($1,$2,$3,'Yönetici',true)",[u,r,'synthetic-concurrent-owner']);
  await registerSyntheticWindows(db,r,u,d,s);
  const args=[d,1,e,q,require('node:crypto').createHash('sha256').update(randomUUID()+randomUUID()).digest('hex')];
  async function run(sessionOnly){
    const c=new Client({...cfg,database:dbname});await c.connect();
    try{
      await c.query('begin');await c.query('set local statement_timeout=10000');await c.query('set local role authenticated');
      await c.query("select set_config('request.jwt.claims',$1,true)",[JSON.stringify({sub:u,session_id:s,aal:'aal2'})]);
      const result=(await c.query(sessionOnly?'select public.nohut_windows_owner_session($1) as value':
        'select public.nohut_enroll_agent($1,$2,$3,$4,$5) as value',sessionOnly?[d]:args)).rows[0].value;
      await c.query('commit');return result;
    }catch(err){await c.query('rollback');throw err;}finally{await c.end();}
  }
  const result=await Promise.all([run(false),run(false),run(true)]);
  const counts=(await db.query(`select (select count(*)::integer from nohut_private.agent_enrollment_requests where restaurant_id=$1) as enrollments,
    (select count(*)::integer from nohut_private.windows_agents where restaurant_id=$1 and revoked_at is null) as live_agents`,[r])).rows[0];
  return {...counts,same_agent:result[0].agent_id===result[1].agent_id,session_ok:result[2].status==='ok'};
}
async function main(){
  const admin=new Client(cfg);await admin.connect();
  for(const sql of ['create role anon nologin','create role authenticated nologin',
    'create role service_role nologin bypassrls',`create role ${role} nologin nosuperuser nobypassrls`]){
    try{await admin.query(sql)}catch(e){if(e.code!=='42710')throw e;}
  }
  await admin.query(`grant anon,authenticated,service_role to ${role}`);
  await admin.query(`create database ${dbname} owner ${role}`);
  const db=new Client({...cfg,database:dbname});await db.connect();
  await db.query(fs.readFileSync(path.join(base,'ci/supabase_auth_stub.sql'),'utf8'));
  await db.query(`set role ${role}`);
  for(const file of fs.readdirSync(path.join(base,'migrations')).filter(f=>f.endsWith('.sql')).sort()){
    await db.query(fs.readFileSync(path.join(base,'migrations',file),'utf8'));
  }
  await db.query('insert into nohut_private.restaurants(restaurant_id) values($1)',[ids.restaurantId]);
  await db.query('insert into nohut_private.authority_epochs(restaurant_id,authority_epoch) values($1,$2)',[ids.restaurantId,ids.authorityEpoch]);
  await db.query(`insert into nohut_private.sync_migrations(restaurant_id,migration_id,authority_epoch,snapshot_revision,snapshot_seq,schema_version,manifest_sha256,status)
    values($1,$2,$3,0,0,1,repeat('a',64),'active')`,[ids.restaurantId,randomUUID(),ids.authorityEpoch]);
  await db.query('insert into nohut_private.sync_checkpoints(restaurant_id,authority_epoch) values($1,$2)',[ids.restaurantId,ids.authorityEpoch]);
  await db.query(`insert into nohut_private.app_users(user_id,restaurant_id,username,pos_employee_id,role_template,is_owner)
    values($1,$2,'synthetic-http-owner',1,'Yönetici',true)`,[ids.userId,ids.restaurantId]);
  await db.query(`select nohut_private.enroll_device($1,$2,$3,'yonetici','Synthetic HTTP')`,[ids.userId,ids.deviceId,ids.sessionId]);
  await registerSyntheticWindows(db,ids.restaurantId,ids.userId,ids.windowsDeviceId,ids.windowsSessionId);
  // Serialize test requests on one connection so SET LOCAL ROLE is isolated.
  let tail=Promise.resolve();
  const server=http.createServer((req,res)=>{
    tail=tail.then(async()=>{
      try{
        let body='';for await(const chunk of req){body+=chunk;if(body.length>8*1024*1024)throw Error('body limit');}
        const args=body?JSON.parse(body):{};
        res.setHeader('Content-Type','application/json');
        if(req.url==='/test/setup'){res.end(JSON.stringify(ids));return;}
        if(req.url==='/test/lose-next-ingest-ack'){loseAck=true;res.end('{}');return;}
        if(req.url==='/test/lose-next-enroll-ack'){loseEnrollAck=true;res.end('{}');return;}
        if(req.url==='/test/concurrent-enrollment'){res.end(JSON.stringify(await verifySetupConcurrency(db)));return;}
        if(req.url==='/test/inspect'){
          const result=(await db.query(`select (select count(*)::integer from nohut_private.expenses where restaurant_id=$1) as expenses,
            (select jsonb_agg(rate_kurus::integer order by effective_from,set_at) from nohut_private.employee_wage_history where restaurant_id=$1) as wage_rates,
            (select e.payroll_eligible from nohut_private.employees e join nohut_private.employee_source_ids m using(restaurant_id,employee_id) where e.restaurant_id=$1 and m.local_id=1) as payroll_eligible,
            (select count(*)::integer from nohut_private.payroll_payments where restaurant_id=$1) as payroll_count,
            (select sum(amount_kurus)::text from nohut_private.payroll_payments where restaurant_id=$1) as payroll_total,
            (select count(*)::integer from nohut_private.payroll_reviews where restaurant_id=$1) as payroll_reviews,
            (select coalesce(sum(extract(epoch from ended_at-started_at)::bigint/60-break_minutes),0)::text from nohut_private.shifts where restaurant_id=$1 and source='manual' and not voided) as manual_minutes,
            (select count(*)::integer from nohut_private.shift_corrections c join nohut_private.shifts s using(restaurant_id,shift_id) where c.restaurant_id=$1 and s.source='manual') as manual_corrections,
            (select count(*)::integer from nohut_private.timesheet_submissions where restaurant_id=$1) as timesheet_submissions,
            (select jsonb_agg(minutes::integer order by ordinal) from nohut_private.timesheet_submissions where restaurant_id=$1) as submitted_minutes,
            (select count(*)::integer from nohut_private.shift_plans where restaurant_id=$1) as planned_count,
            (select count(*)::integer from nohut_private.shift_plans where restaurant_id=$1 and cancelled) as planned_cancelled,
            (select count(*)::integer from nohut_private.shift_plan_history where restaurant_id=$1) as planned_history,
            (select count(*)::integer from nohut_private.payments p join nohut_private.employee_source_ids m using(restaurant_id,employee_id) where p.restaurant_id=$1 and m.local_id=1) as session_collector_payments,
            (select count(*)::integer from nohut_private.agent_enrollment_requests where restaurant_id=$1) as enrollments,
            (select count(*)::integer from nohut_private.windows_agents where restaurant_id=$1 and revoked_at is null) as live_agents,
            (select count(*)::integer from nohut_private.orders where restaurant_id=$1) as orders,
            (select count(*)::integer from nohut_private.order_items where restaurant_id=$1) as order_items,
            (select count(*)::integer from nohut_private.combined_payment_groups where restaurant_id=$1) as combined_groups,
            (select count(*)::integer from nohut_private.combined_payment_members where restaurant_id=$1) as combined_members,
            (select sum(amount_kurus)::text from nohut_private.combined_payment_groups where restaurant_id=$1) as combined_amount,
            (select sum(cash_kurus)::text from nohut_private.combined_payment_groups where restaurant_id=$1) as combined_cash,
            (select sum(card_kurus)::text from nohut_private.combined_payment_groups where restaurant_id=$1) as combined_card,
            (select sum(expected_kurus)::text from nohut_private.cash_sessions where restaurant_id=$1) as cash_expected,
            (select sum(difference_kurus)::text from nohut_private.cash_sessions where restaurant_id=$1) as cash_variance,
            (select count(*)::integer from nohut_private.cash_movements where restaurant_id=$1) as cash_movements,
            (select count(*)::integer from nohut_private.terminal_attempts where restaurant_id=$1) as terminal_attempts,
            (select count(*)::integer from nohut_private.terminal_attempt_events where restaurant_id=$1) as terminal_events,
            (select status from nohut_private.terminal_attempts where restaurant_id=$1 limit 1) as terminal_status,
            (select count(*)::integer from nohut_private.payments where restaurant_id=$1 and terminal_reference is not null) as terminal_payments,
            (select count(*)::integer from nohut_private.platform_order_records where restaurant_id=$1) as platform_records,
            (select count(*)::integer from nohut_private.platform_order_versions where restaurant_id=$1) as platform_versions,
            (select count(*)::integer from nohut_private.platform_line_versions where restaurant_id=$1) as platform_line_versions,
            (select sum(original_qty-qty)::text from nohut_private.platform_line_versions where restaurant_id=$1) as platform_cancelled_qty,
            (select net_kurus::text from nohut_private.platform_order_records where restaurant_id=$1 limit 1) as platform_collection_net,
            (select customer_note from nohut_private.platform_order_versions where restaurant_id=$1 limit 1) as platform_note,
            (select total_kurus::text from nohut_private.platform_order_versions where restaurant_id=$1 order by source_revision limit 1) as platform_first_total,
            (select order_total_kurus::text from nohut_private.platform_order_records where restaurant_id=$1 limit 1) as platform_current_total,
            (select v.sales_eligible from nohut_private.platform_order_versions v join nohut_private.platform_order_records r
              on r.restaurant_id=v.restaurant_id and r.current_version_id=v.platform_version_id where r.restaurant_id=$1 limit 1) as platform_current_sales_eligible,
            (select count(*)::integer from nohut_private.receipt_snapshots where restaurant_id=$1) as receipt_snapshots,
            (select count(*)::integer from nohut_private.print_jobs where restaurant_id=$1) as print_jobs,
            (select count(*)::integer from nohut_private.print_job_events where restaurant_id=$1) as print_events,
            (select status from nohut_private.print_jobs where restaurant_id=$1 limit 1) as print_status,
            (select body from nohut_private.receipt_snapshots where restaurant_id=$1 limit 1) as receipt_body,
            (select count(*)::integer from nohut_private.guest_allocations where restaurant_id=$1 and deleted_at is null) as guest_allocations,
            (select count(*)::integer from nohut_private.payments where restaurant_id=$1) as payments,
            (select count(*)::integer from nohut_private.payment_refunds where restaurant_id=$1) as refunds,
            (select count(*)::integer from nohut_private.order_line_edits where restaurant_id=$1) as line_edits,
            (select count(*)::integer from nohut_private.orders where restaurant_id=$1 and deleted_at is not null) as deleted_orders,
            (select count(*)::integer from nohut_private.deleted_order_audit where restaurant_id=$1) as deletion_audits,
            (select sum(total_kurus)::text from nohut_private.orders where restaurant_id=$1) as order_total,
            (select sum(paid_kurus)::text from nohut_private.orders where restaurant_id=$1) as order_paid,
            (select sum(due_kurus)::text from nohut_private.orders where restaurant_id=$1) as order_due,
            (select jsonb_agg(v.price_kurus::integer order by v.price_kurus) from nohut_private.product_versions v
              join nohut_private.products p using(restaurant_id,product_id) where v.restaurant_id=$1 and p.source_kind='historical_sale') as historical_sale_prices,
            (select coalesce(sum(amount_kurus),0)::text from nohut_private.expenses where restaurant_id=$1) as expense_kurus,
            (select count(*)::integer from nohut_private.sync_transactions where restaurant_id=$1) as transactions,
            (select count(*)::integer from nohut_private.product_versions where restaurant_id=$1) as product_versions,
            (select count(*)::integer from nohut_private.products where restaurant_id=$1 and deleted_at is null) as active_products,
            (select jsonb_agg(price_kurus::integer order by price_kurus) from nohut_private.product_versions where restaurant_id=$1) as product_prices,
            (select last_acked_seq::integer from nohut_private.sync_checkpoints where restaurant_id=$1) as checkpoint`,[ids.restaurantId])).rows[0];
          res.end(JSON.stringify(result));return;
        }
        const method=req.url?.split('/').pop();const params=methods[method];
        if(!params||req.url!==`/rest/v1/rpc/${method}`||Object.keys(args).some(k=>!params.includes(k))){res.writeHead(400).end('{}');return;}
        const windows=['nohut_windows_owner_session','nohut_enroll_agent','nohut_revoke_agent','nohut_owner_rotate_authority_epoch'].includes(method);
        const app=windows||['nohut_enqueue_command','nohut_command_status','nohut_daily_report_view','nohut_notifications_list'].includes(method);
        if(app&&req.headers.authorization!==`Bearer ${windows?'synthetic-windows-owner-jwt':'synthetic-user-jwt'}`){res.writeHead(403).end('{}');return;}
        await db.query('begin');
        try{
          await db.query(`set local role ${app?'authenticated':'anon'}`);
          if(app)await db.query("select set_config('request.jwt.claims',$1,true)",[JSON.stringify({sub:ids.userId,session_id:windows?ids.windowsSessionId:ids.sessionId,aal:'aal2'})]);
          const boundParams=params.map(k=>k==='p_events'&&args[k]!==undefined?JSON.stringify(args[k]):args[k]);
          const result=(await db.query(`select public.${method}(${params.map((_,i)=>'$'+(i+1)).join(',')}) as value`,boundParams)).rows[0].value;
          await db.query('commit');
          if(method==='nohut_agent_ingest'&&loseAck){loseAck=false;res.writeHead(503).end('{}');return;}
          if(method==='nohut_enroll_agent'&&loseEnrollAck){loseEnrollAck=false;res.writeHead(503).end('{}');return;}
          res.end(JSON.stringify(result));
        }catch(e){await db.query('rollback');throw e;}
      }catch(e){res.writeHead(e.code==='42501'?403:400).end(JSON.stringify({code:e.code||'test_error'}));console.error('RPC test error',e.code,e.message);}
    }).catch(e=>{console.error(e);res.destroy();});
  });
  server.listen(Number(process.env.NOHUT_TEST_HTTP_PORT||55440),'127.0.0.1',()=>{
    const url=`http://127.0.0.1:${server.address().port}`;
    // CI asks the OS for an unused port; publish only after this exact
    // disposable database has migrated and this server owns the listener.
    if(process.env.NOHUT_TEST_READY_FILE) fs.writeFileSync(process.env.NOHUT_TEST_READY_FILE,url,'utf8');
    console.log(`Synthetic HTTP bridge ready on ${url}`);
  });
  async function stop(){server.close();await tail;await db.end();await admin.end();process.exit(0);}
  process.on('SIGINT',stop);process.on('SIGTERM',stop);
}
main().catch(e=>{console.error(e);process.exit(1)});
