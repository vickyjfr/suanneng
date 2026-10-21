import hashlib,http.client,json,os,socket,subprocess,tempfile,time,sys
root=tempfile.mkdtemp(prefix='se9-store-',dir='/tmp');storage=root+'/files';os.mkdir(storage)
sock=socket.socket();sock.bind(('127.0.0.1',0));port=sock.getsockname()[1];sock.close();proc=None
headers={'X-Agent-Proxy-Token':'isolated-test-secret','X-SE9-User-ID':'user-test','X-SE9-Device-ID':'device-test'}
def start():
 global proc
 proc=subprocess.Popen([sys.argv[1] if len(sys.argv)>1 else '/tmp/se9-rtc-build/se9_file_api'],env={**os.environ,'STORAGE_ROOT':storage,'FILE_API_BIND_ADDR':'127.0.0.1','FILE_API_PORT':str(port),'SE9_AGENT_PROXY_TOKEN':'isolated-test-secret'},stdout=subprocess.DEVNULL)
 for i in range(50):
  try:
   c=http.client.HTTPConnection('127.0.0.1',port,timeout=2);c.request('GET','/api/v2/health');c.getresponse().read();return
  except OSError:time.sleep(.05)
 raise RuntimeError('startup')
def request(method,path,body=None,task=None,extra=None,status=200):
 h=dict(headers)
 if task:h.update({'X-SE9-Resume-Token':task['resumeToken'],'X-SE9-Epoch':task['epoch']})
 if extra:h.update(extra)
 if isinstance(body,dict):body=json.dumps(body).encode()
 c=http.client.HTTPConnection('127.0.0.1',port,timeout=10);c.request(method,'/api/v2/transfers'+path,body=body,headers=h);r=c.getresponse();b=r.read();assert r.status==status,(method,path,r.status,b)
 c.close();return json.loads(b)['data'] if r.getheader('Content-Type')=='application/json' else b
def new(name,data,direction='upload'):
 return request('POST','',{'requestId':hashlib.sha256((direction+name).encode()).hexdigest()[:32],'direction':direction,'path':name,'size':str(len(data)),'sha256':hashlib.sha256(data).hexdigest(),'blockBytes':1048576,'overwrite':False},status=201)
def path(t,s=''):return '/'+t['transferId']+s
def put(t,i,b,status=200,epoch=None):return request('PUT',path(t,'/blocks/'+str(i)),b,t,{'X-SE9-Block-SHA256':hashlib.sha256(b).hexdigest(),**({'X-SE9-Epoch':str(epoch)} if epoch else {})},status)
def finish(t):return request('POST',path(t,'/complete'),{'size':t['size'],'sha256':t['sha256']},t)
try:
 start();data=bytes(i%251 for i in range(1048576+73));t=new('resume.bin',data);assert new('resume.bin',data)['transferId']==t['transferId'];put(t,0,data[:1048576]);put(t,0,data[:1048576]);request('PUT',path(t,'/blocks/1'),data[1048576:],t,{'X-SE9-Block-SHA256':'0'*64},409)
 proc.terminate();proc.wait();start();assert int(request('GET',path(t),task=t)['durableBytes'])==1048576
 resumed=request('POST',path(t,'/resume'),{},t);resumed['resumeToken']=t['resumeToken'];put(resumed,1,data[1048576:],409,epoch=1);t=resumed;put(t,1,data[1048576:]);finish(t);assert open(storage+'/resume.bin','rb').read()==data
 # Simulate restart after link publication but before completion persistence.
 taskdir=storage+'/.se9-transfers/'+t['transferId'];m=json.load(open(taskdir+'/manifest.json'));m['state']='committing';os.link(storage+'/resume.bin',taskdir+'/merged');json.dump(m,open(taskdir+'/manifest.json','w'));proc.terminate();proc.wait();start();finish(t);assert open(storage+'/resume.bin','rb').read()==data
 empty=new('empty.bin',b'');finish(empty);assert os.path.getsize(storage+'/empty.bin')==0
 download=new('resume.bin',b'','download') if False else request('POST','',{'requestId':'download-check-long-enough','direction':'download','path':'resume.bin','overwrite':False},status=201)
 open(storage+'/resume.bin','wb').write(b'changed')
 assert request('GET',path(download,'/blocks/0'),task=download)==data[:1048576]
 request('POST',path(download,'/blocks/0/ack'),{'sha256':hashlib.sha256(data[:1048576]).hexdigest()},download)
 request('POST',path(download,'/blocks/1/ack'),{'sha256':hashlib.sha256(data[1048576:]).hexdigest()},download);finish(download)
 request('GET',path(t),task=t,extra={'X-SE9-User-ID':'someone-else'},status=403)
 request('POST','',{'requestId':'unsafe-long-request','direction':'upload','path':'../escape','size':'0','sha256':hashlib.sha256(b'').hexdigest()},status=400)
 os.symlink('/tmp',storage+'/escape-link');request('POST','',{'requestId':'symlink-long-request','direction':'upload','path':'escape-link/nope','size':'0','sha256':hashlib.sha256(b'').hexdigest()},status=400)
 request('POST','',{'requestId':'collision-long-request','direction':'upload','path':'empty.bin','size':'0','sha256':hashlib.sha256(b'').hexdigest()},status=409)
 print('PASS: store restart, durable ACK, idempotency, checksum rejection, stale epoch, publish recovery, empty file, immutable snapshot, ownership, traversal/symlink, no-overwrite')
finally:
 if proc:proc.terminate();proc.wait()
 print('Artifacts:',root)
