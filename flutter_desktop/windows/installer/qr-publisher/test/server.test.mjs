// node --test flutter_desktop/windows/installer/qr-publisher/test
// Lifecycle only: health/version, auth on shutdown, clean exit, taken port.
// Uses a throwaway RSA key; never talks to GitHub.
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {generateKeyPairSync,randomBytes} from 'node:crypto';
import {mkdtempSync,writeFileSync,readFileSync} from 'node:fs';
import {createServer} from 'node:net';
import {tmpdir} from 'node:os';
import {join,dirname} from 'node:path';
import {fileURLToPath} from 'node:url';

const here=dirname(fileURLToPath(import.meta.url));
const server=join(here,'..','server.mjs');
const dir=mkdtempSync(join(tmpdir(),'nohut-pub-'));
const keyFile=join(dir,'key.pem');
writeFileSync(keyFile,generateKeyPairSync('rsa',{modulusLength:2048})
  .privateKey.export({type:'pkcs8',format:'pem'}));
const token=randomBytes(40).toString('base64url');
const expected=/const VERSION='([^']+)'/.exec(readFileSync(server,'utf8'))[1];

async function freePort(){
  return await new Promise(r=>{const s=createServer().listen(0,'127.0.0.1',()=>{
    const {port}=s.address();s.close(()=>r(port));});});
}
function start(port){
  const child=spawn(process.execPath,[server],{env:{...process.env,
    GITHUB_APP_PRIVATE_KEY_FILE:keyFile,QR_PUBLISH_ADMIN_TOKEN:token,
    QR_PUBLISH_PORT:String(port)},stdio:['ignore','pipe','pipe']});
  let out='';child.stdout.on('data',d=>out+=d);child.stderr.on('data',d=>out+=d);
  const exited=new Promise(r=>child.on('exit',code=>r(code)));
  return {child,exited,log:()=>out};
}
async function waitHealth(port){
  for(let i=0;i<50;i++){
    try{const r=await fetch(`http://127.0.0.1:${port}/health`);if(r.ok)return r.json();}
    catch{}
    await new Promise(r=>setTimeout(r,100));
  }
  throw new Error('no health');
}

test('health reports the version; shutdown needs the token and exits cleanly',async()=>{
  const port=await freePort();
  const s=start(port);
  const health=await waitHealth(port);
  assert.deepEqual(health,{service:'Nohut QR Publisher',status:'ready',version:expected});
  const anon=await fetch(`http://127.0.0.1:${port}/shutdown`,{method:'POST'});
  assert.equal(anon.status,401);
  const wrong=await fetch(`http://127.0.0.1:${port}/shutdown`,{method:'POST',
    headers:{authorization:'Bearer '+'x'.repeat(48)}});
  assert.equal(wrong.status,401);
  const ok=await fetch(`http://127.0.0.1:${port}/shutdown`,{method:'POST',
    headers:{authorization:'Bearer '+token}});
  assert.equal(ok.status,200);
  assert.equal(await s.exited,0);
  assert.ok(!s.log().includes(token),'token never logged');
});

test('a taken port exits with 98 and a plain message',async()=>{
  const port=await freePort();
  const blocker=createServer().listen(port,'127.0.0.1');
  await new Promise(r=>blocker.once('listening',r));
  const s=start(port);
  assert.equal(await s.exited,98);
  assert.match(s.log(),/PORT_IN_USE 127\.0\.0\.1:\d+/);
  blocker.close();
});

test('binds to loopback only',async()=>{
  const port=await freePort();
  const s=start(port);
  await waitHealth(port);
  assert.match(s.log(),new RegExp(`only on http://127\\.0\\.0\\.1:${port}`));
  s.child.kill();
  await s.exited;
});
