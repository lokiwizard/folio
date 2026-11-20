const {app,BrowserWindow,ipcMain,dialog,clipboard,nativeImage,safeStorage,shell,protocol,net,Menu}=require('electron');
const fs=require('node:fs/promises'), path=require('node:path');
const {pathToFileURL}=require('node:url');
const {randomUUID,createHash}=require('node:crypto');
const ai=require('./ai.cjs');
protocol.registerSchemesAsPrivileged([{scheme:'folio',privileges:{standard:true,secure:true,supportFetchAPI:true,corsEnabled:true,stream:true,codeCache:true}}]);
const origin='folio://desktop';
const allowed=new Map(), commands=new Map();
let win, pendingFile, prefs={}, secrets={}, requests=new Map(), flush=Promise.resolve(), closing=false, waiting=false, ready=false;
const folder=()=>path.join(app.getPath('userData'),'Folio');
async function readJSON(name,fallback) {
  try{return JSON.parse(await fs.readFile(path.join(folder(),name),'utf8'));}
  catch(error){if(error.code==='ENOENT')return fallback;throw error;}
}
async function atomic(file,data) {
  const temp=file+'.'+randomUUID()+'.tmp';
  try {await fs.writeFile(temp,data,{flag:'wx'});await fs.rename(temp,file);}
  finally{await fs.rm(temp,{force:true});}
}
function persist(name,value) {
  const data=JSON.stringify(value);
  const job=flush.then(()=>atomic(path.join(folder(),name),data));
  flush=job.catch(()=>{});return job;
}
function handle(name,call){
  ipcMain.handle('folio:'+name,(event,...args)=>{
    if(event.senderFrame!==win.webContents.mainFrame || new URL(event.senderFrame.url).host!=='desktop') throw Error('Invalid window');
    return call(...args);
  });
}
function send(event,data){if(win && !win.isDestroyed())win.webContents.send('folio:'+event,data);}
function offer(file) {
  if(!file || path.extname(file).toLowerCase()!=='.pdf')return;
  pendingFile=path.resolve(file);
  if(ready){send('open',true);}
}
function cleanSettings(){const {recents=[],profiles=[],...settings}=prefs;return {settings,profiles,recents:recents.map(({id,name})=>({id,name})),endpoints:ai.endpoints};}
async function loadPDF(file) {
  if (!file) return null;
  if(path.extname(file).toLowerCase()!=='.pdf')throw Error('PDF required');
  const bytes=await fs.readFile(file);
  const id=createHash('sha256').update(bytes).digest('hex');
  allowed.set(id,file);
  const name=path.basename(file);
  return {id,name,bytes,state:await readJSON(id+'.json',null)};
}
function fileFor(id){const file=allowed.get(id);if(!file)throw Error('Open a document first');return file;}
function profileFor(id){const entry=prefs.profiles?.find(p=>p.id===id);if(!entry)throw Error('Configure AI service first');return entry;}
function keyFor(id){if(!secrets[id])throw Error('API Key required');return safeStorage.decryptString(Buffer.from(secrets[id],'base64'));}
function commandLinePDF(argv){return argv.find(a=>path.extname(a).toLowerCase()==='.pdf');}
app.setName('Folio');
if(!app.requestSingleInstanceLock())app.quit();
else {
 app.on('second-instance',(_,argv)=>{offer(commandLinePDF(argv));if(win){win.restore();win.focus();}});
 app.on('open-file',(ev,file)=>{ev.preventDefault();offer(file);});
 app.whenReady().then(async()=>{
  await fs.mkdir(folder(),{recursive:true});
  prefs=await readJSON('preferences.json',{});secrets=await readJSON('credentials.json',{});
  protocol.handle('folio',request=>{
    const url=new URL(request.url),relative=decodeURIComponent(url.pathname).slice(1);
    if(url.host!=='desktop'|| !/^(src|assets)\//.test(relative)||relative.includes('..')||/[\\:\0]/.test(relative)||relative.endsWith('.cjs'))return new Response(null,{status:404});
    return net.fetch(pathToFileURL(path.join(__dirname,'..',relative)).href);
  });
  win=new BrowserWindow({title:'Folio',width:1400,height:900,minWidth:840,minHeight:540,backgroundColor:'#f4f5f4',webPreferences:{preload:path.join(__dirname,'preload.cjs'),contextIsolation:true,sandbox:true,nodeIntegration:false}});
  Menu.setApplicationMenu(null);
  win.webContents.setWindowOpenHandler(()=>({action:'deny'}));
  win.webContents.on('will-navigate',event=>event.preventDefault());
  win.webContents.session.setPermissionRequestHandler((_wc,_perm,callback)=>callback(false));
  win.on('close',event=>{if(!closing && ready && !win.webContents.isCrashed()){event.preventDefault();if(!waiting){waiting=true;send('closing');}}});
  handle('closed',async success=>{waiting=false;if(success){closing=true;await flush;win.close();}});
  handle('ready',()=>{ready=true;if(pendingFile)send('open',true);});
  handle('init',cleanSettings);
  handle('open',async fromLaunch=>{
    if(fromLaunch){const file=pendingFile;pendingFile=null;return loadPDF(file);}
    const result=await dialog.showOpenDialog(win,{filters:[{name:'PDF',extensions:['pdf']}],properties:['openFile']});
    return loadPDF(result.filePaths[0]);
  });
  handle('drop',file=>loadPDF(file));
  handle('read',async id=>fs.readFile(fileFor(id)));
  handle('recent',id=>loadPDF(prefs.recents?.find(x=>x.id===id)?.path));
  handle('paper',async id=>{
    const file=fileFor(id);prefs.recents=[{id,path:file,name:path.basename(file)},...(prefs.recents??[]).filter(x=>x.id!==id)].slice(0,40);
    await persist('preferences.json',prefs);
  });
  handle('savePaper',(id,data)=>{fileFor(id);return persist(id+'.json',data);});
  handle('settings',async changes=>{
    const keys=['lang','theme','glass','font','tags','defaultTag','prompts','active','widths','leftWidth'];
    for(const k of keys)if(Object.hasOwn(changes,k))prefs[k]=changes[k];
    await persist('preferences.json',prefs);
  });
  handle('profile',async ({provider,base,model,key,models})=>{
    base=ai.baseURL(base);if(!Object.hasOwn(ai.endpoints,provider)||!model.trim())throw Error('Provider and model required');
    prefs.profiles??=[];let item=prefs.profiles.find(p=>p.base===base && p.provider===provider);
    const id=item?.id??randomUUID();
    if(key){
      if(!safeStorage.isEncryptionAvailable())throw Error('System credential encryption unavailable');
      secrets[id]=safeStorage.encryptString(key).toString('base64');await persist('credentials.json',secrets);
    }
    if(!secrets[id])throw Error('API Key required');
    const next={id,provider,base,model,models:[...new Set([...(models??item?.models??[]),model])]};
    prefs.profiles=[...prefs.profiles.filter(p=>p.id!==id),next];prefs.active=id;
    await persist('preferences.json',prefs);return cleanSettings();
  });
  handle('removeProfile',async id=>{
    prefs.profiles=(prefs.profiles??[]).filter(p=>p.id!==id);if(prefs.active===id)prefs.active=prefs.profiles[0]?.id??'';
    await persist('preferences.json',prefs);delete secrets[id];await persist('credentials.json',secrets);return cleanSettings();
  });
  handle('models',async id=>{const p=profileFor(id);p.models=await ai.catalog(p,keyFor(id));await persist('preferences.json',prefs);return p.models;});
  handle('test',id=>ai.chat(profileFor(id),keyFor(id),[{role:'user',text:'Reply OK.'}],AbortSignal.timeout(30000),()=>{},false));
  handle('chat',async (id,token,history)=>{
    if(requests.size)throw Error('A response is already running');
    const ctrl=new AbortController();requests.set(token,ctrl);
    try{return await ai.chat(profileFor(id),keyFor(id),history,AbortSignal.any([ctrl.signal,AbortSignal.timeout(300000)]),text=>send('delta',{token,text}));}
    finally{requests.delete(token);}
  });
  handle('stop',token=>requests.get(token)?.abort());
  handle('external',async raw=>{const u=new URL(raw);if(!['https:','http:'].includes(u.protocol))return;const r=await dialog.showMessageBox(win,{message:u.href,buttons:['Open link','Cancel'],defaultId:1,cancelId:1});if(r.response===0)await shell.openExternal(u.href);});
  handle('fullscreen',()=>win.setFullScreen(!win.isFullScreen()));
  handle('copyImage',data=>{const image=nativeImage.createFromDataURL(data);if(image.isEmpty())throw Error('Invalid image');clipboard.writeImage(image);});
  handle('print',()=>new Promise((resolve,reject)=>win.webContents.print({printBackground:true},(ok,why)=>ok||/cancel/i.test(why)?resolve():reject(Error(why)))));
  handle('extract',async (id,data)=>{
    const input=fileFor(id),result=await dialog.showSaveDialog(win,{defaultPath:path.parse(input).name+'-pages.pdf',filters:[{name:'PDF',extensions:['pdf']}]});
    if(result.canceled)return;
    const output=result.filePath;
    const dest=await fs.stat(output).catch(()=>null),src=await fs.stat(input);
    if(dest && dest.ino===src.ino && dest.dev===src.dev)throw Error('Choose a different file to preserve the original PDF');
    await atomic(output,Buffer.from(data));
  });
  handle('exportNotes',async (id,sections,pictures)=>{
    const result=await dialog.showSaveDialog(win,{defaultPath:path.parse(fileFor(id)).name+'.md',filters:[{name:'Markdown',extensions:['md']}]});
    if(result.canceled)return;
    const stem='figures-'+randomUUID(),dir=path.join(path.dirname(result.filePath),stem);
    if(pictures.length)await fs.mkdir(dir);
    try{
      for(const [i,image] of pictures.entries()){
        const file='clip-'+String(i+1).padStart(3,'0')+'.png';
        await fs.writeFile(path.join(dir,file),Buffer.from(image.split(',')[1],'base64'));
      }
      const body=sections.map(s=>typeof s==='string'?s:'![]('+stem+'/clip-'+String(s.figure+1).padStart(3,'0')+'.png)').join('\n');
      await atomic(result.filePath,body);
    }catch(error){if(pictures.length)await fs.rm(dir,{recursive:true,force:true});throw error;}
  });
  offer(commandLinePDF(process.argv));await win.loadURL(origin+'/src/index.html');
 }).catch(error=>{dialog.showErrorBox('Folio',error.message);app.quit();});
 app.on('window-all-closed',()=>app.quit());
}
