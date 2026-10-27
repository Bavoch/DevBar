'use strict';
// Long-running non-HTTP jobs: attest the source actually loaded as the entry,
// independently of the controller's expected digest. This is version evidence,
// not a claim that a job's database/network work is healthy.
const fs=require('node:fs'), path=require('node:path'), http=require('node:http');
const crypto=require('node:crypto'), cp=require('node:child_process'), moduleAPI=require('node:module');
if (typeof moduleAPI.registerHooks !== 'function') throw Error('DevBar non-HTTP job proof requires Node 22.15+ with module.registerHooks');
const root=fs.realpathSync(process.env.DEVBAR_PROJECT_PATH);
const main=process.argv[1] && fs.realpathSync(process.argv[1]);
if (!main || !main.startsWith(root+path.sep) || main.includes(path.sep+'node_modules'+path.sep)) return;
const mainURL=require('node:url').pathToFileURL(main).href;
const marker=Symbol.for('devbar.entry.'+process.env.DEVBAR_SYNC_ID);
let started=false, loadedHash;
const hash=buffer=>crypto.createHash('sha256').update(buffer).digest('hex');
globalThis[marker]=()=>{
  if(started)return;started=true;
  setTimeout(()=>{
    try {
    if(hash(fs.readFileSync(main))!==loadedHash) return;
    const env={...process.env,DEVBAR_WITNESS_PID:String(process.pid)};delete env.NODE_OPTIONS;
    const measured=JSON.parse(cp.execFileSync(env.DEVBAR_WITNESS_BINARY,['--runtime-source',root,'--target',env.DEVBAR_SYNC_TARGET],{env,encoding:'utf8',timeout:60000,maxBuffer:1048576}));
    const proof={...measured,syncID:env.DEVBAR_SYNC_ID,target:env.DEVBAR_SYNC_TARGET,pid:process.pid,runtimeVersion:'nodeProcess',componentID:env.DEVBAR_COMPONENT_ID};
    const route='/'+proof.syncID+'/'+process.pid;
    const server=http.createServer((q,s)=>{
      if(q.url!==route||q.method!=='GET'){s.writeHead(404);s.end();return;}
      try {if(hash(fs.readFileSync(main))!==loadedHash) throw Error('changed');}
      catch {s.writeHead(409);s.end();return;}
      s.writeHead(200,{'Content-Type':'application/json','Cache-Control':'no-store'});s.end(JSON.stringify(proof));
    });
    server.listen(0,'127.0.0.1',()=>{
      fs.mkdirSync(env.DEVBAR_WITNESS_DIRECTORY,{recursive:true,mode:0o700});
      const file=path.join(env.DEVBAR_WITNESS_DIRECTORY,process.pid+'-process.json');
      fs.writeFileSync(file,JSON.stringify({...proof,witnessURL:'http://127.0.0.1:'+server.address().port+route}),{mode:0o600});
    });server.unref();
    } catch(error) {process.stderr.write('DevBar job witness: '+error.message+'\n');}
  },500).unref();
};
moduleAPI.registerHooks({load(url,context,next){
  const result=next(url,context);
  if(url===mainURL && result.source!=null && ['module','commonjs'].includes(result.format)){
    const source=Buffer.from(result.source);loadedHash=hash(source);
    if(loadedHash!==hash(fs.readFileSync(main))) throw Error('Job entry transform differs from the project source; an application-specific witness is required');
    const text=source.toString('utf8').replace(/^#![^\n]*\n/,'');
    const enter='globalThis[Symbol.for('+JSON.stringify(Symbol.keyFor(marker))+')]();\n';
    return {...result,source:result.format==='module'?enter+text:text+'\n;'+enter};
  }return result;
}});
