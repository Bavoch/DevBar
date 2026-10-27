// Dedicated DSH web profile + headless Chromium. No user's profile or window is changed.
import fs from 'node:fs';import path from 'node:path';import http from 'node:http';import {spawn} from 'node:child_process';import {createHash} from 'node:crypto';
const c=JSON.parse(fs.readFileSync(process.argv[2],'utf8')), cfg=c.configuration;
const base=path.join(path.dirname(c.state),c.instanceID),snapshot=path.join(base,'plugin');
fs.mkdirSync(base,{recursive:true,mode:0o700});
const project=path.dirname(c.entry), manifest=JSON.parse(fs.readFileSync(path.join(project,'package.json'),'utf8'));
if(!manifest.dsh?.client || !manifest.dsh?.bundle) throw Error('A DSH client/bundle package is required');
fs.mkdirSync(snapshot,{recursive:true});
for(const name of fs.readdirSync(project)){const source=path.join(project,name);if(['node_modules','.git','work'].includes(name)||snapshot.startsWith(source+path.sep))continue;fs.cpSync(source,path.join(snapshot,name),{recursive:true});}
const client=typeof manifest.exports?.['./client']==='string'?manifest.exports['./client']:'client.js';
const clientFile=path.resolve(snapshot,client);if(!clientFile.startsWith(snapshot+path.sep)) throw Error('Client escapes package');
const code=fs.readFileSync(clientFile,'utf8'),digest=createHash('sha256').update(code).digest('hex');
const evidence=Object.fromEntries(['sourceDigest','syncID','target','instanceID','artifactDigest'].map(k=>[k,c[k]]));
evidence.pid=process.pid;evidence.clientDigest=digest;evidence.platform="DSH";evidence.deviceKind="isolatedHost";
const observe=`{const loader=window.__ModuleLoader__, load=loader.load;loader.load=function(spec){if(spec.id===${JSON.stringify(manifest.name)}){const factory=spec.factory;spec.factory=function(...args){const plugin=factory(...args),apply=plugin.apply;plugin.apply=async function(...args){const value=await apply.apply(this,args);window.__devbarLoaded=${JSON.stringify(evidence)};return value;};return plugin;};}return load.call(this,spec);};try{\n`;
fs.writeFileSync(clientFile,observe+code+'\n}finally{loader.load=load;}}');
const home=path.join(base,'home'),profile=path.join(home,'profiles/web');fs.mkdirSync(path.join(profile,'node_modules',path.dirname(manifest.name)),{recursive:true});
fs.symlinkSync(snapshot,path.join(profile,'node_modules',manifest.name),'dir');
fs.writeFileSync(path.join(profile,'package.json'),JSON.stringify({name:'devbar-dsh-profile',private:true,dsh:{profile:{bundles:['@deepseek-ai/dsh-base','@deepseek-ai/dsh-web-app',manifest.name]}}}));
fs.writeFileSync(path.join(profile,'cordis.patch.yml'),'[]\n');
let browser,clientSocket;const pending=new Map();let nextID=1;
const host=spawn(process.execPath,[cfg.hostExecutable,'--profile','web','--no-open','--port','0'],{cwd:project,env:{...process.env,DSH_HOME:home},stdio:['ignore','pipe','inherit']});
function cleanup(){browser?.kill('SIGTERM');host.kill('SIGTERM');}
process.on('SIGTERM',()=>{cleanup();process.exit(0)});process.on('exit',cleanup);
host.on('exit',code=>{console.error('DSH host exited',code);process.exit(1)});
let buffer='';const url=await new Promise((resolve,reject)=>{
 const timer=setTimeout(()=>reject(Error('DSH readiness timeout')),90000);
 host.stdout.on('data',chunk=>{buffer=(buffer+chunk).slice(-10000);const m=/dsh web:\s*(http:\/\/\S+?\?token=[A-Za-z0-9_-]+)/.exec(buffer);if(m){clearTimeout(timer);resolve(m[1]);}});
});
const browserDir=path.join(base,'browser');browser=spawn(cfg.browserExecutable||'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',['--headless=new','--no-first-run','--no-default-browser-check','--remote-debugging-port=0','--user-data-dir='+browserDir,'about:blank'],{stdio:'ignore'});
browser.on('exit',()=>process.exit(1));
const sleep=ms=>new Promise(r=>setTimeout(r,ms));let active;
for(let i=0;i<100;i++){try{active=fs.readFileSync(path.join(browserDir,'DevToolsActivePort'),'utf8').split('\n');break}catch{}await sleep(100)}
if(!active)throw Error('Headless browser unavailable');
async function connect(address){const ws=new WebSocket(address);await new Promise((resolve,reject)=>{ws.onopen=resolve;ws.onerror=reject});ws.onmessage=e=>{const msg=JSON.parse(e.data);if(msg.id&&pending.has(msg.id)){const {resolve,reject,timer}=pending.get(msg.id);clearTimeout(timer);pending.delete(msg.id);msg.error?reject(Error(JSON.stringify(msg.error))):resolve(msg.result)}};return ws;}
function send(ws,method,params={}){return new Promise((resolve,reject)=>{const id=nextID++,timer=setTimeout(()=>{pending.delete(id);reject(Error('CDP timeout'))},3000);pending.set(id,{resolve,reject,timer});ws.send(JSON.stringify({id,method,params}))})}
const socket=await connect('ws://127.0.0.1:'+active[0]+active[1]);
const {targetId}=await send(socket,'Target.createTarget',{url});let page;
for(let i=0;i<100;i++){const pages=await fetch('http://127.0.0.1:'+active[0]+'/json/list').then(r=>r.json());page=pages.find(p=>p.id===targetId);if(page?.webSocketDebuggerUrl)break;await sleep(100)}
clientSocket=await connect(page.webSocketDebuggerUrl);
async function loaded(){if(host.exitCode!==null||browser.exitCode!==null)throw Error('Host or browser stopped');const result=await send(clientSocket,'Runtime.evaluate',{expression:'window.__devbarLoaded',returnByValue:true});const v=result.result?.value;if(!v||v.instanceID!==c.instanceID||v.clientDigest!==digest)throw Error('DSH client plugin has not applied');return v;}
let ready=false;for(let i=0;i<200;i++){try{await loaded();ready=true;break}catch{}await sleep(200)}
if(!ready)throw Error('Actual DSH client apply failed');
const server=http.createServer(async(req,res)=>{if(req.headers.authorization!=='Bearer '+c.token){res.writeHead(403).end();return}try{res.setHeader('Content-Type','application/json');res.end(JSON.stringify(await loaded()))}catch(e){res.writeHead(503).end(JSON.stringify({error:e.message}))}});
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
const temp=c.state+'.tmp';fs.writeFileSync(temp,JSON.stringify({...evidence,token:c.token,url:'http://127.0.0.1:'+server.address().port}),{mode:0o600});fs.renameSync(temp,c.state);
