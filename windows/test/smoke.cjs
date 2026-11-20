const {_electron}=require('playwright-core');
const fs=require('node:fs/promises'),os=require('node:os'),path=require('node:path');
(async()=>{
 const dir=await fs.mkdtemp(path.join(os.tmpdir(),'folio-ui-')),root=path.resolve(__dirname,'..'),pdf=path.join(root,'../Tests/Fixtures/embedded-highlights.pdf');
 const app=await _electron.launch({executablePath:process.env.FOLIO_TEST_EXE||require('electron'),args:['--user-data-dir='+dir,...(process.env.FOLIO_TEST_EXE?[]:[root]),pdf],timeout:30000});
 try{
  const win=await app.firstWindow();win.on('console',m=>console.log('renderer',m.type(),m.text().slice(0,240)));win.on('pageerror',err=>console.log('pageerror',err.message));
  await win.waitForSelector('#desk:not([hidden])',{timeout:16000});await win.waitForSelector('.page canvas');await win.waitForSelector('.textLayer span');
  console.log('Opened',await win.title(),await win.locator('#pageCount').textContent());
  await win.getByRole('button',{name:'批注',exact:true}).click();await win.waitForSelector('.card');console.log('Imported annotations',await win.locator('.card').count());
 }catch(e){console.log('state',await (await app.firstWindow()).locator('body').innerText({timeout:2000}));throw e;}
 finally{await app.close();await fs.rm(dir,{recursive:true,force:true});}
})().catch(e=>{console.error(e);process.exitCode=1;});
