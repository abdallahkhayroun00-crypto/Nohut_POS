import {test} from 'node:test';
import assert from 'node:assert/strict';
import {generateKeyPairSync,verify} from 'node:crypto';
import {makeHandler} from './index.ts';
const {privateKey, publicKey}=generateKeyPairSync('rsa',{modulusLength:2048});
const env={NOHUT_QR_CHECK_KEY:'synthetic-check-key-not-for-production-123',NOHUT_QR_GITHUB_APP_ID:'123',NOHUT_QR_GITHUB_PRIVATE_KEY:privateKey.export({type:'pkcs1',format:'pem'}).toString()};
const req=(token='synthetic-check-key-not-for-production-123',method='POST')=>new Request('https://local.invalid',{method,headers:{'x-nohut-check-key':token}});
function fixture({wrongApp=false,wrongPermission=false,missing=false}={}) {
 const calls=[];
 const h=makeHandler(k=>env[k],async (url,init)=>{
  const p=new URL(url).pathname; calls.push([p,init.method]); assert.equal(new URL(url).origin,'https://api.github.com');
  if(p==='/app') { const [head,payload,sig]=init.headers.authorization.slice(7).split('.'); assert(verify('RSA-SHA256',Buffer.from(head+'.'+payload),publicKey,Buffer.from(sig,'base64url'))); return Response.json({id:123,slug:wrongApp?'other':'nohut-qr-publisher'}); }
  if(p.endsWith('/installation')) return Response.json({id:42,app_id:123,account:{login:'nohutfalafel'},permissions:{contents:'write'},repository_selection:'selected'});
  if(p.endsWith('/access_tokens')) {assert.deepEqual(JSON.parse(init.body),{repositories:['qr-menu'],permissions:{contents:'read'}});return Response.json({token:'fake-github-secret',permissions:{contents:wrongPermission?'write':'read'}});}
  assert.equal(init.method,'GET'); assert(p.startsWith('/repos/nohutfalafel/qr-menu/contents/cms/'));
  if(missing&&p.endsWith('pos-managed-menu.json'))return new Response(null,{status:404});
  return Response.json({encoding:'base64',sha:'fake-revision',content:Buffer.from(JSON.stringify({products:[{}],categories:[{}],campaigns:[]})).toString('base64')});
 });return {h,calls};
}
test('deny unprivileged before network',async()=>{const {h,calls}=fixture();assert.equal((await h(req('user-jwt'))).status,403);assert.equal(calls.length,0)});
test('deny GET before network',async()=>{const {h,calls}=fixture();assert.equal((await h(req(undefined,'GET'))).status,405);assert.equal(calls.length,0)});
test('successful fixed-repository read and no token in response',async()=>{const {h,calls}=fixture();const result=await h(req());assert.equal(result.status,200);const s=await result.text();assert.equal(JSON.parse(s).products,1);assert(!s.includes('fake-github-secret'));assert.equal(calls.filter(c=>c[1]==='POST').length,1)});
test('wrong app is rejected before installation',async()=>{const {h,calls}=fixture({wrongApp:true});assert.equal((await h(req())).status,502);assert.equal(calls.length,1)});
test('unexpected write token is rejected before content read',async()=>{const {h,calls}=fixture({wrongPermission:true});assert.equal((await h(req())).status,502);assert.equal(calls.length,3)});
test('missing managed catalog reads bootstrap',async()=>{const {h,calls}=fixture({missing:true});assert.equal((await h(req())).status,200);assert(calls.at(-1)[0].endsWith('catalog-v1.json'))});
test('invalid PEM emits no key content',async()=>{const h=makeHandler(k=>k==='NOHUT_QR_GITHUB_PRIVATE_KEY'?'bad-secret':env[k],()=>{throw Error('unexpected network')});const res=await h(req());assert.equal(res.status,502);assert(!(await res.text()).includes('bad-secret'))});

test('absent or short diagnostic key fails closed before network',async()=>{for(const value of [undefined,'short']){const h=makeHandler(k=>k==='NOHUT_QR_CHECK_KEY'?value:env[k],()=>{throw Error('unexpected network')});assert.equal((await h(req())).status,403);}});
