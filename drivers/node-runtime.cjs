'use strict';
// The witness lives in the serving runtime, after the application's HTTP listener starts.
const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const cp = require('node:child_process');
const directory = process.env.DEVBAR_WITNESS_DIRECTORY;
const binary = process.env.DEVBAR_WITNESS_BINARY;
const root = process.env.DEVBAR_PROJECT_PATH;
const target = process.env.DEVBAR_SYNC_TARGET;
const syncID = process.env.DEVBAR_SYNC_ID;
if (directory && binary && root && target && syncID && process.env.DEVBAR_WITNESS_MODE === 'nodeProcess') require('./node-process.cjs');
if (directory && binary && root && target && syncID && process.env.DEVBAR_WITNESS_MODE !== 'nodeProcess') {
  if (process.env.DEVBAR_WITNESS_MODE === 'nodeGraph') require('./node-graph.cjs')();
  const emit = http.Server.prototype.emit;
  const internal = new WeakSet();
  http.Server.prototype.emit = function(event, ...args) {
    const result = emit.call(this, event, ...args);
    if (event !== 'listening' || internal.has(this) || process.env.DEVBAR_WITNESS_DRIVER === 'worker') return result;
    try {
      const env = {...process.env, DEVBAR_WITNESS_PID: String(process.pid)};
      delete env.NODE_OPTIONS;
      // Hash independently inside the running process; never echo the expected digest.
      const measured = JSON.parse(cp.execFileSync(binary, ['--runtime-source', root, '--target', target],
        {env, encoding: 'utf8', timeout: 60000, maxBuffer: 1048576}));
      const address = this.address();
      const host = address && address.address === '::1' ? '[::1]' : '127.0.0.1';
      const entryURL = address && typeof address === 'object' ? 'http://' + host + ':' + address.port + (process.env.DEVBAR_WITNESS_ENTRY_PATH || '/') : null;
      const proof = {...measured, componentID:process.env.DEVBAR_COMPONENT_ID, entryURL, syncID, target, pid: process.pid, runtimeVersion: process.version};
      const route = '/' + syncID + '/' + process.pid;
      const witness = http.createServer((req, res) => {
        if (req.url !== route || req.method !== 'GET') {res.writeHead(404); res.end(); return;}
        res.writeHead(200, {'Content-Type': 'application/json', 'Cache-Control': 'no-store'});
        res.end(JSON.stringify(proof));
      });
      internal.add(witness);
      witness.listen(0, '127.0.0.1', () => {
        fs.mkdirSync(directory, {recursive: true, mode: 0o700});
        const record = {...proof, witnessURL: 'http://127.0.0.1:' + witness.address().port + route};
        const file = path.join(directory, process.pid + '-' + address.port + '.json');
        fs.writeFileSync(file + '.tmp', JSON.stringify(record), {mode: 0o600});
        fs.renameSync(file + '.tmp', file);
        if (process.env.DEVBAR_WITNESS_MODE === 'nodeGraph' && process.env.DEVBAR_COMPONENT_ID) fs.writeFileSync(path.join(directory,'graph',process.env.DEVBAR_COMPONENT_ID+'.serving'),'1',{mode:0o600});
      });
      witness.unref();
      this.once('close', () => {witness.close(); try {fs.unlinkSync(path.join(directory, process.pid + '-' + address.port + '.json'));} catch {}});
    } catch (error) {process.stderr.write('DevBar runtime witness: ' + error.message + '\n');}
    return result;
  };
}
