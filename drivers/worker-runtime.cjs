'use strict';
const fs = require('node:fs');
const path = require('node:path');
const cp = require('node:child_process');
const {createRequire} = require('node:module');
(async () => {
  const [first, second] = process.argv.slice(2);
  const descriptor = first === "--descriptor" ? JSON.parse(fs.readFileSync(second,"utf8")) : null;
  const [directory, launchID] = descriptor ? [descriptor.directory, ""] : [first, second];
  process.chdir(directory);
  const projectRequire = createRequire(path.join(directory, 'package.json'));
  const pkg = JSON.parse(fs.readFileSync(path.join(directory, 'package.json'), 'utf8'));
  const key = Object.keys(pkg.scripts || {}).sort((a,b)=>b.length-a.length).find(k=>launchID === k || launchID.endsWith(':'+k));
  const command = pkg.scripts[key];
  if (!descriptor && (!command || /[;|&`$<>\n]/.test(command))) throw Error('Worker script must be a direct local wrangler dev command');
  const args = descriptor ? ['wrangler','dev',...descriptor.args] : JSON.parse(cp.execFileSync('python3', ['-c', 'import json,shlex,sys;print(json.dumps(shlex.split(sys.argv[1])))', command], {encoding:'utf8'}));
  if (args.shift() !== 'wrangler' || args.shift() !== 'dev') throw Error('Unsupported Worker launcher');
  const options = {local:true, ip:'127.0.0.1', port:0, inspectorPort:0, logLevel:'error',
    experimental:{disableExperimentalWarning:true, disableDevRegistry:true, forceLocal:true, watch:false, showInteractiveDevSession:false}};
  for (let i=0;i<args.length;i++) {
    const [flag, inline] = args[i].split(/=(.*)/s);
    if (['--local','-l'].includes(flag)) continue;
    const fields = {'--config':'config','-c':'config','--env':'env','-e':'env','--port':'port','--ip':'ip','--inspector-port':'inspectorPort','--local-protocol':'localProtocol','--persist-to':'persistTo','--log-level':'logLevel'};
    if (flag === '--var') {
      const value = inline ?? args[++i]; const split = value.indexOf(':');
      if (split <= 0) throw Error('Invalid local Worker variable declaration');
      (options.vars ||= {})[value.slice(0,split)] = value.slice(split+1); continue;
    }
    if (!fields[flag]) throw Error('Unsupported Worker development flag: '+flag);
    const value = inline ?? args[++i];
    if (value === undefined) throw Error('Missing Worker development flag value');
    options[fields[flag]] = ['port','inspectorPort'].includes(fields[flag]) ? Number(value) : value;
  }
  // Proof and persistence stay local, independently of production resource configuration.
  options.ip = '127.0.0.1'; options.localProtocol = 'http';
  if (!options.persistTo && process.env.DEVBAR_DATA_DIR) options.persistTo = path.join(process.env.DEVBAR_DATA_DIR,'worker-data',require('node:crypto').createHash('sha256').update(process.env.DEVBAR_PROJECT_PATH+'\n'+process.env.DEVBAR_SYNC_TARGET).digest('hex'));
  let wrangler;
  try {wrangler=projectRequire('wrangler');}
  catch(error) {
    if (pkg.dependencies?.wrangler || pkg.devDependencies?.wrangler || pkg.optionalDependencies?.wrangler) throw error;
    // An undeclared CLI is resolved from the actual PATH; do not borrow an arbitrary project version.
    for (const bin of (process.env.PATH || '').split(path.delimiter)) {
      let entry;try {entry=fs.realpathSync(path.join(bin,'wrangler'));} catch {continue;}
      let parent=path.dirname(entry);
      for(let depth=0;depth<5;depth++,parent=path.dirname(parent)) {
        try {const metadata=JSON.parse(fs.readFileSync(path.join(parent,'package.json'),'utf8'));
          if(metadata.name==='wrangler'){wrangler=require(parent);break;}
        } catch {}
      }
      if(wrangler) break;
    }
    if(!wrangler) throw Error('No declared local Wrangler or installed PATH Wrangler is available');
  }
  const config = wrangler.unstable_readConfig({config:options.config, env:options.env}, {hideWarnings:true});
  if (config.configPath) options.config=path.resolve(config.configPath);
  else if (!options.config) throw Error('No project Wrangler configuration was resolved');
  const entry = fs.realpathSync(config.main);
  const sourceRoot = fs.realpathSync(process.env.DEVBAR_PROJECT_PATH);
  if (!entry.startsWith(sourceRoot+path.sep)) throw Error('Worker entry is outside the project source scope');
  const env = {...process.env, DEVBAR_WITNESS_PID:String(process.pid)}; delete env.NODE_OPTIONS;
  const measured = JSON.parse(cp.execFileSync(env.DEVBAR_WITNESS_BINARY, ['--runtime-source',sourceRoot,'--target',env.DEVBAR_SYNC_TARGET],{env,encoding:'utf8',timeout:60000,maxBuffer:1048576}));
  const folder = env.DEVBAR_WITNESS_DIRECTORY;
  fs.mkdirSync(folder,{recursive:true,mode:0o700});
  const workerFirst=config.assets?.run_worker_first;
  const prefix=Array.isArray(workerFirst)?workerFirst.find(rule=>typeof rule==='string' && rule.startsWith('/') && !rule.startsWith('!') && rule.endsWith('/*'))?.slice(0,-1):'';
  const route = (prefix || '/')+'__devbar/runtime/'+env.DEVBAR_SYNC_ID;
  const revision = {sourceDigest:measured.sourceDigest, syncID:env.DEVBAR_SYNC_ID, target:env.DEVBAR_SYNC_TARGET,
    componentID:env.DEVBAR_COMPONENT_ID, transportPID:process.pid, hostInstanceID:measured.instanceID, runtimeVersion:'workerd'};
  const generatedFolder = path.join(folder,env.DEVBAR_COMPONENT_ID || 'worker');
  fs.mkdirSync(generatedFolder,{recursive:true,mode:0o700});
  const generated = path.join(generatedFolder,'entry.mjs');
  const code = `import * as Module from ${JSON.stringify(entry)};
export * from ${JSON.stringify(entry)};
const Original=Module.default;
const proof=${JSON.stringify(revision)};let instanceID;
function witness(request){return new URL(request.url).pathname===${JSON.stringify(route)}?Response.json({...proof,instanceID:instanceID ||= crypto.randomUUID(),entryURL:new URL(request.url).origin+'/'},{headers:{'Cache-Control':'no-store'}}):null;}
const Wrapped=typeof Original==='function'?class extends Original{fetch(request,...args){return witness(request)||super.fetch(request,...args);}}:{...Original,fetch(request,...args){return witness(request)||(Original?.fetch?Original.fetch(request,...args):new Response('Not Found',{status:404}));}};
export default Wrapped;
`;
  fs.writeFileSync(generated,code,{mode:0o600});
  const worker = await Promise.race([wrangler.unstable_dev(generated,options),new Promise((_,reject)=>{const timer=setTimeout(()=>reject(Error('Local workerd did not become ready')),45000);timer.unref();})]);
  const base = 'http://127.0.0.1:'+worker.port;
  const response = await worker.fetch(base+route);
  if (!response.ok) throw Error('Worker runtime did not load the revision entry');
  const proof = await response.json();
  if (proof.sourceDigest !== measured.sourceDigest || proof.syncID !== env.DEVBAR_SYNC_ID) throw Error('Worker runtime revision mismatch');
  const file = path.join(folder,process.pid+'.json');
  fs.writeFileSync(file,JSON.stringify({...proof,witnessURL:base+route,entryURL:base+'/'}),{mode:0o600});
  if (env.DEVBAR_WITNESS_MODE === 'nodeGraph' && env.DEVBAR_COMPONENT_ID) fs.writeFileSync(path.join(folder,'graph',env.DEVBAR_COMPONENT_ID+'.serving'),'1',{mode:0o600});
  let stopping=false;
  const stop=async()=>{if(stopping)return;stopping=true;try{fs.unlinkSync(file);}catch{}await worker.stop();process.exit(0);};
  process.on('SIGTERM',stop);process.on('SIGINT',stop);
  await worker.waitUntilExit();
})().catch(error=>{process.stderr.write('DevBar Worker runtime: '+error.message+'\n');const group=Number(process.env.DEVBAR_RUNTIME_GROUP);if(group>1){try{process.kill(-group,'SIGTERM');}catch{}}process.exit(1);});
