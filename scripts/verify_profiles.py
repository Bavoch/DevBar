"""Profile/target selection tests, using isolated fixture projects and saved state."""
from pathlib import Path
import json,os,subprocess,tempfile
root=Path(__file__).resolve().parents[1];binary=str(root/'.build/release/DevBar')
with tempfile.TemporaryDirectory(prefix='Launch profiles ',dir=root/'work') as folder:
 base=Path(folder);env=dict(os.environ,DEVBAR_DATA_DIR=str(base/'state'))
 def cli(*args,ok=True):
  r=subprocess.run([binary,*args],env=env,capture_output=True,text=True,timeout=45)
  if ok:assert r.returncode==0,r.stderr
  return r
 def profile(name,files):
  project=base/name;project.mkdir()
  for f,value in files.items():
   p=project/f;p.parent.mkdir(parents=True,exist_ok=True);p.write_text(json.dumps(value) if isinstance(value,dict) else value)
  return project,json.loads(cli('--profile-project',str(project)).stdout)
 cases=[
 ('Vite',{'package.json':{'scripts':{'dev':'vite'},'dependencies':{'vite':'1'}}},'web','npm run dev'),
 ('Still',{'package.json':{'scripts':{'dev':'vite','desktop':'node electron/dev.mjs'},'devDependencies':{'electron':'1'}}},'desktop','npm run desktop'),
 ('Tauri',{'package.json':{'scripts':{'dev':'tauri dev','dev:web':'vite'},'dependencies':{'@tauri-apps/cli':'1'}}},'desktop','npm run dev'),
 ('Expo',{'package.json':{'scripts':{'start':'expo start --dev-client','ios':'expo run:ios','android':'expo run:android','web':'expo start --web'},'dependencies':{'expo':'1'}}},'service','npm run start'),
 ('Taro',{'package.json':{'scripts':{'dev:weapp':'taro build --type weapp --watch','dev:h5':'taro build --type h5 --watch'},'dependencies':{'@tarojs/taro':'1'}}},'miniapp','npm run dev:weapp'),
 ('Python',{'pyproject.toml':'[project]\nname="example"\n[project.scripts]\nexample="example:main"\n'},'script',"uv run 'example'"),
 ('Swift',{'Package.swift':'let package = Package(targets: [.executableTarget(name: "Example")])'},'script','swift run'),
 ('Rust',{'Cargo.toml':'[package]\nname="example"','src/main.rs':'fn main() {}'},'script','cargo run'),
 ('Go',{'go.mod':'module example','main.go':'package main\nfunc main(){}'},'script','go run .'),
 ('Static',{'index.html':'<title>Example</title>'},'staticWeb','python3 -m http.server 0 --bind 127.0.0.1'),
 ]
 for name,files,kind,command in cases:
  project,p=profile(name,files)
  assert p['targets'][0]['kind']==kind,(name,p)
  assert (('live-static.py' in p['targets'][0]['command']) if name == 'Static' else p['targets'][0]['command']==command),(name,p)
 project,p=profile('Tauri renderer only',{'package.json':{'scripts':{'dev':'vite','tauri':'tauri'},'devDependencies':{'@tauri-apps/cli':'2'}}})
 assert p['targets'][0]['kind']=='desktop' and p['targets'][0]['command']=="npm run 'tauri' -- dev",p
 assert any(t['kind']=='web' and t['command']=='npm run dev' for t in p['targets']),p
 project,p=profile('Tauri parent',{'package.json':{'scripts':{'dev':'tauri dev','dev:web':'vite'},'devDependencies':{'@tauri-apps/cli':'1'}},'src-tauri/tauri.conf.json':{'identifier':'local.devbar.tauri'},'src-tauri/Cargo.toml':'[package]\nname="fixture"','src-tauri/src/main.rs':'fn main(){}'})
 child=json.loads(cli('--profile-project',str(project/'src-tauri')).stdout)
 assert child['targets'][0]['kind']=='desktop' and child['targets'][0]['command']=="cd '..' && npm run dev"
 project,p=profile('No fabricated entry',{'Cargo.toml':'[lib]\nname="lib"','src/lib.rs':'pub fn hello() {}'})
 assert not p['targets']
 project,p=profile('Swift library',{'Package.swift':'let package = Package(products: [.library(name: "Lib", targets: ["Lib"])])'})
 assert not p['targets']
 project,p=profile('Root workspace',{'package.json':{'scripts':{'dev':'node server.js'},'packageManager':'pnpm@10','workspaces':['apps/*']},'apps/mobile/package.json':{'scripts':{'start':'expo start','ios':'expo run:ios'},'dependencies':{'expo':'1'}}})
 assert any(t['id']=='apps/mobile:start' and 'pnpm run start' in t['command'] for t in p['targets'])
 project,p=profile('Extension',{'manifest.json':{'manifest_version':3,'name':'Example','version':'1','background':{'service_worker':'worker.js'}},'worker.js':'console.log("ready")'})
 assert p['targets'][0]['kind']=='browserExtension' and '--run-target' in p['targets'][0]['command']
 project,p=profile('Choice',{'package.json':{'scripts':{'dev':'tauri dev','dev:web':'vite'},'dependencies':{'@tauri-apps/cli':'1'}}})
 ident=cli('--add-project',str(project)).stdout.strip()
 cli('--select-target',ident,'--target','dev:web')
 stored=next(p for p in json.loads(cli('--list-projects').stdout) if p['id']==ident)
 assert stored['targetID']=='dev:web' and stored['command']=='npm run dev:web'
 project,p=profile('Native helpers',{'Package.swift':'let package=Package(products:[.executable(name:"capture-helper",targets:["Capture"]),.executable(name:"cursor-helper",targets:["Cursor"])])'})
 assert len(p['targets'])==2 and all(t['kind']=='tool' and t['id'].startswith('swift:') for t in p['targets']),p
 project,p=profile('Windows POC',{'Cargo.toml':"[package]\nname='poc'\n[target.'cfg(windows)'.dependencies]\nwindows='1'",'src/main.rs':'#[cfg(windows)] fn main(){} #[cfg(not(windows))] fn main(){println!("no-op");}'})
 assert p['targets'][0]['requiredPlatform']=='Windows' and 'Windows' in p['targets'][0]['environmentIssue'],p
 print('PASS: web, desktop, Expo, Taro, Python, Swift, Rust, Go, static HTML, extensions, workspace children, library exclusion and persisted target selection')
