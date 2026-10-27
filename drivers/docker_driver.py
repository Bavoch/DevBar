"""Local Docker Compose development namespaces with actual image and application proof."""
import json,os,pathlib,re,tempfile,time,urllib.parse,urllib.request
from native import run,read,write

def handle(action,c,root,state,proof):
    name=c['projectName'];service=c['service'];context=c.get('dockerContext','default')
    if not re.fullmatch(r'devbar-[a-z0-9][a-z0-9_-]*',name): raise RuntimeError('projectName must use an isolated devbar- namespace')
    if not re.fullmatch(r'[a-zA-Z0-9][a-zA-Z0-9_.-]*',service): raise RuntimeError('Invalid compose service')
    compose=(root/c['composeFile']).resolve()
    if not compose.is_relative_to(root) or not compose.is_file(): raise RuntimeError('composeFile must be a project file')
    docker=['docker','--context',context]
    endpoint=json.loads(run(['docker','context','inspect',context]))[0]['Endpoints']['docker']['Host']
    if not endpoint.startswith('unix://'): raise RuntimeError('Only local Unix-socket Docker contexts are supported')
    env=dict(os.environ,DOCKER_HOST=endpoint,DOCKER_CONTEXT=context)
    # Homebrew's standalone Compose also respects DOCKER_HOST; do not change user config/context.
    command=['docker-compose','-p',name,'-f',str(compose)]
    cfg=json.loads(run(command+['config','--format','json'],env=env))
    for kind in ('volumes','networks'):
        for resource in cfg.get(kind,{}).values():
            if resource.get('external') or resource.get('name') and not resource['name'].startswith(name+'_'): raise RuntimeError('Shared or external compose resources are not managed')
    target=cfg.get('services',{}).get(service)
    if not target or not target.get('build'): raise RuntimeError('A buildable compose service is required')
    if target.get('container_name') or target.get('privileged') or target.get('network_mode')=='host': raise RuntimeError('Global container names, privileged mode, and host networking are not managed')
    if any(v.get('type')=='bind' for v in target.get('volumes',[])): raise RuntimeError('Bind-mounted code is outside immutable image proof; use an image or a dedicated adapter')
    context_path=pathlib.Path(target['build']['context']).resolve()
    if not context_path.is_relative_to(root): raise RuntimeError('Build context must be inside project source scope')
    def inspect(identifier):
        rows=json.loads(run(docker+['inspect',identifier]))
        if len(rows)!=1: raise RuntimeError('Expected one container instance')
        value=rows[0]
        if value['Config']['Labels'].get('com.docker.compose.project')!=name or value['Config']['Labels'].get('com.docker.compose.service')!=service: raise RuntimeError('Container ownership changed')
        return value
    old=read(state) if state.exists() else None
    if action=='stop':
        if not old: raise RuntimeError('No managed container session')
        value=inspect(old['containerID'])
        if value['Image']!=old['imageID'] or value['State']['StartedAt']!=old['startedAt']: raise RuntimeError('Container instance changed')
        run(docker+['stop','--time','10',old['containerID']]);return {}
    if action=='sync':
        existing=run(command+['ps','-q',service],env=env)
        if existing and (not old or existing!=old['containerID']): raise RuntimeError('Namespace already has an unowned container')
        override=state.with_suffix('.compose.json')
        write(override,{'services':{service:{'build':{'args':{'DEVBAR_SOURCE_DIGEST':proof['sourceDigest']},'labels':{'local.devbar.sourceDigest':proof['sourceDigest']}},'environment':{'DEVBAR_SYNC_ID':proof['syncID'],'DEVBAR_SYNC_TARGET':proof['target']}}}})
        merged=command+['-f',str(override)]
        run(merged+['up','--build','--detach','--no-deps',service],env=env,timeout=c.get('timeout',600))
        identifier=run(merged+['ps','-q',service],env=env)
        value=inspect(identifier)
        old={'containerID':value['Id'],'imageID':value['Image'],'startedAt':value['State']['StartedAt']}
        write(state,old)
    if not old: raise RuntimeError('No container receipt')
    value=inspect(old['containerID'])
    if not value['State']['Running'] or value['Image']!=old['imageID'] or value['State']['StartedAt']!=old['startedAt']: raise RuntimeError('Container stopped or replaced')
    image=json.loads(run(docker+['image','inspect',old['imageID']]))[0]
    source=image['Config'].get('Labels',{}).get('local.devbar.sourceDigest')
    url=urllib.parse.urlsplit(c['proofURL'])
    if url.scheme!='http' or url.hostname not in ['127.0.0.1','localhost','::1'] or url.username or url.password: raise RuntimeError('Container proofURL must use local HTTP')
    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self,*args,**kwargs): return None
    deadline=time.monotonic()+(30 if action=='sync' else 0)
    while True:
        try:
            with urllib.request.build_opener(urllib.request.ProxyHandler({}),NoRedirect()).open(c['proofURL'],timeout=4) as response:
                raw=response.read(1048577)
            if len(raw)>1048576: raise RuntimeError('Container proof too large')
            runtime=json.loads(raw)
            if runtime.get('sourceDigest')!=source: raise RuntimeError('Application revision does not match built image')
            break
        except Exception:
            if time.monotonic()>=deadline: raise
            time.sleep(.2)
    runtime.update(instanceID=value['Id']+':'+runtime['instanceID'],platform='Docker',deviceKind='localContainer',artifactDigest=value['Image'])
    if action=='sync': write(state,{**old,'proof':runtime})
    elif runtime['instanceID']!=old.get('proof',{}).get('instanceID'): raise RuntimeError('Application process changed inside container')
    return runtime
