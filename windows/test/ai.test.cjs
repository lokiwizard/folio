const test=require('node:test'),assert=require('node:assert/strict');
const {request,decode,baseURL,chat,catalog}=require('../src/ai.cjs');
const messages=[{role:'user',text:'Figure',images:['data:image/jpeg;base64,YQ==']}];
const config=(provider, model='vision')=>({provider,model,base:'https://example.test/v1'});
test('provider formats preserve only supplied images and text',()=>{
 for(const p of ['OpenAI','Gemini','Anthropic','DeepSeek','阿里云百炼','月之暗面','智谱','火山方舟','Custom']){
  const {url,options}=request(config(p),'demo',messages,true),data=JSON.parse(options.body);
  assert.equal(options.redirect,'error');assert.equal(url.startsWith('https://example.test/v1/'),true);
  if(p==='Gemini')assert.deepEqual(data.contents[0].parts[1].inlineData,{mimeType:'image/jpeg',data:'YQ=='});
  else if(p==='Anthropic')assert.equal(data.messages[0].content[1].source.data,'YQ==');
  else assert.equal(data.messages[0].content[1].image_url.url,messages[0].images[0]);
 }
 const req=request(config('OpenAI','gpt-6-test'),'demo',messages,true);assert.ok(req.url.endsWith('/responses'));assert.equal(JSON.parse(req.options.body).store,false);
 for(const bad of ['http://example.test','https://user:pass@example.test','https://example.test/?x=1'])assert.throws(()=>baseURL(bad));
});
test('stream supports split UTF-8, provider completion and cancellation errors',async t=>{
 const fixture='data: {"choices":[{"delta":{"content":"论文"}}]}\r\n\r\ndata: [DONE]\n\n';
 const raw=new TextEncoder().encode(fixture);
 t.mock.method(global,'fetch',async()=>new Response(new ReadableStream({start(c){for(const b of raw)c.enqueue(Uint8Array.of(b));c.close();}}),{headers:{'content-type':'text/event-stream'}}));
 const chunks=[];assert.equal(await chat(config('Custom'),'demo',messages,undefined,s=>chunks.push(s)),'论文');assert.equal(chunks.join(''),'论文');
 assert.equal(decode({type:'response.output_text.delta',delta:'ok'}),'ok');assert.equal(decode({delta:{text:'ok'}}),'ok');
 assert.equal(decode({candidates:[{content:{parts:[{thought:true,text:'hidden'},{text:'ok'}]}}]}),'ok');
 assert.throws(()=>decode({type:'response.failed'}));
});
test('model discovery follows pages and removes duplicates',async t=>{
 t.mock.method(global,'fetch',async url=>Response.json(url.searchParams.has('after_id')?{data:[{id:'y'}]}:{data:[{id:'x'}],has_more:true,last_id:'x'}));
 assert.deepEqual(await catalog(config('Anthropic'),'key'),['x','y']);
});
