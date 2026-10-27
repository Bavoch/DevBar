'use strict';
// Preserve project orchestration and preflight checks. Every live application leaf
// must supply its own proof; one successful port never validates its siblings.
const fs = require('node:fs');
const path = require('node:path');
const cp = require('node:child_process');
const crypto = require('node:crypto');
module.exports = function graph() {
  const directory = process.env.DEVBAR_WITNESS_DIRECTORY;
  const folder = path.join(directory, 'graph');
  fs.mkdirSync(folder, {recursive:true, mode:0o700});
  const write = (id, value) => {
    const file = path.join(folder, id+'.json');
    const temporary = file+'.'+process.pid+'.tmp';
    fs.writeFileSync(temporary, JSON.stringify(value), {mode:0o600});
    fs.renameSync(temporary,file);
  };
  if (!process.env.DEVBAR_COMPONENT_ID) {
    process.env.DEVBAR_COMPONENT_ID = 'root';
    const env = {...process.env, DEVBAR_WITNESS_PID:String(process.pid)}; delete env.NODE_OPTIONS;
    const measured = JSON.parse(cp.execFileSync(env.DEVBAR_WITNESS_BINARY,
      ['--runtime-source',env.DEVBAR_PROJECT_PATH,'--target',env.DEVBAR_SYNC_TARGET],
      {env,encoding:'utf8',timeout:60000,maxBuffer:1048576}));
    write('root',{id:'root',parent:null,pid:process.pid,signature:measured.instanceID.slice(String(process.pid).length+1),instanceID:measured.instanceID,sourceDigest:measured.sourceDigest,status:'running'});
  }
  const parent = process.env.DEVBAR_COMPONENT_ID;
  const spawn = cp.spawn;
  cp.spawn = function(command, args, options) {
    if (!Array.isArray(args)) {options=args;args=[];}
    options = {...options};
    const cwd = path.resolve(String(options.cwd || process.cwd()));
    const base = path.basename(String(command));
    // Build tools and auxiliary transport processes do not serve application code.
    const ignored = /^(?:esbuild|git|which|ps|lsof|xcrun|cloudflared|osascript|open)(?:$|-)/.test(base);
    const inside = cwd === process.env.DEVBAR_PROJECT_PATH || cwd.startsWith(process.env.DEVBAR_PROJECT_PATH+path.sep);
    if (ignored || process.env.DEVBAR_WITNESS_DRIVER === 'worker') return spawn.call(this,command,args,options);
    const id = crypto.randomUUID();
    const record = {id,parent,pid:null,status:'starting',scoped:inside};
    const env = {...(options.env || process.env), DEVBAR_COMPONENT_ID:id};
    // A pinned local workerd owns Worker proof, not Wrangler's Node proxy.
    let workerArgs;
    if (base === 'wrangler' && args[0] === 'dev') workerArgs=args.slice(1);
    if ((base === 'npx' || base === 'npm') && args[0] === 'wrangler' && args[1] === 'dev') workerArgs=args.slice(2);
    if (workerArgs) {
      const descriptor = path.join(folder,id+'.worker');
      fs.writeFileSync(descriptor,JSON.stringify({directory:cwd,args:workerArgs}),{mode:0o600});
      command=process.execPath;args=[path.join(__dirname,'worker-runtime.cjs'),'--descriptor',descriptor];
      options.shell=false;env.DEVBAR_WITNESS_DRIVER='worker';
    }
    options.env=env;
    write(id,record);
    let child;
    try {child=spawn.call(this,command,args,options);}
    catch(error){write(id,{...record,status:'failed'});throw error;}
    record.pid=child.pid || null;
    try {record.signature=cp.execFileSync('/bin/ps',['-p',String(child.pid),'-o','lstart='],{encoding:'utf8'}).trim().split(/\s+/).join(' ');} catch {}
    record.status=inside?'running':'failed';write(id,record);
    child.once('error',()=>write(id,{...record,status:'failed'}));
    child.once('exit',(code,signal)=>write(id,{...record,status:code===0 && inside?'completed':'failed',exitCode:code,signal}));
    return child;
  };
  require('node:module').syncBuiltinESMExports();
};
