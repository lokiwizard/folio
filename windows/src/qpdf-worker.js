importScripts('../assets/qpdf/qpdf.js');
onmessage=async ({data:{bytes,password,range,wasm}})=>{
  try {
    const compiled=await WebAssembly.compile(wasm);
    const q=await Module({instantiateWasm(imports,ready){const instance=new WebAssembly.Instance(compiled,imports);ready(instance);return instance.exports;},printErr:()=>{}});
    q.FS.writeFile('/paper.pdf',new Uint8Array(bytes));
    const code=q.callMain(['--empty','--pages','/paper.pdf','--password='+password,range,'--','/extract.pdf']);
    if (code!==0 && code!==3) throw Error('PDF extraction failed');
    const out=q.FS.readFile('/extract.pdf');
    postMessage({out},[out.buffer]);
  } catch(error){ postMessage({error:String(error)}); }
};
