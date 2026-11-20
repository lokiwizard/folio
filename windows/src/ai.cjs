const endpoints = {
  OpenAI: 'https://api.openai.com/v1', Anthropic: 'https://api.anthropic.com/v1',
  Gemini: 'https://generativelanguage.googleapis.com/v1beta', DeepSeek: 'https://api.deepseek.com',
  '阿里云百炼': 'https://dashscope.aliyuncs.com/compatible-mode/v1', '月之暗面': 'https://api.moonshot.cn/v1',
  '智谱': 'https://open.bigmodel.cn/api/paas/v4', '火山方舟': 'https://ark.cn-beijing.volces.com/api/v3', Custom: ''
};
function baseURL(base) {
  const url = new URL(base);
  if (url.protocol !== 'https:' || url.username || url.password || url.search || url.hash) throw Error('HTTPS URL required');
  return url.href.replace(/\/+$/, '');
}
function headers(provider, key) {
  if (!key) throw Error('API Key required');
  if (provider === 'Anthropic') return {'x-api-key':key, 'anthropic-version':'2023-06-01'};
  if (provider === 'Gemini') return {'x-goog-api-key':key};
  return {Authorization:'Bearer ' + key};
}
function request(profile, key, history, stream) {
  const {provider, model} = profile;
  if (!model.trim()) throw Error('Model ID required');
  const isResponse = provider === 'OpenAI' && model.startsWith('gpt-6');
  const messages = history.map(({role,text,images = []}) => {
    const blobs = images.map(data => {
      const match = /^data:(image\/(?:jpeg|png|webp));base64,([\w+/=]+)$/.exec(data);
      if (!match) throw Error('Invalid image');
      return {mimeType:match[1], data:match[2]};
    });
    if (provider === 'Gemini') return {role:role === 'assistant' ? 'model' : 'user', parts:[{text}, ...blobs.map(inlineData => ({inlineData}))]};
    if (!images.length) return {role, content:text};
    const content = [{type:isResponse ? 'input_text' : 'text',text}];
    for (const [i,blob] of blobs.entries()) {
      if (provider === 'Anthropic') content.push({type:'image',source:{type:'base64',media_type:blob.mimeType,data:blob.data}});
      else if (isResponse) content.push({type:'input_image',image_url:images[i]});
      else content.push({type:'image_url',image_url:{url:images[i]}});
    }
    return {role,content};
  });
  let route = '/chat/completions', body = {model,messages,stream};
  if (isResponse) { route='/responses'; body={model,input:messages,store:false,stream}; }
  if (provider === 'Anthropic') { route='/messages'; body.max_tokens=4096; }
  if (provider === 'Gemini') {
    if (!/^[\w.-]+$/.test(model)) throw Error('Invalid Gemini model');
    route='/models/'+model+(stream ? ':streamGenerateContent?alt=sse' : ':generateContent');
    body={contents:messages};
  }
  return {url:baseURL(profile.base)+route, options:{method:'POST', redirect:'error', headers:{...headers(provider,key),'Content-Type':'application/json'},body:JSON.stringify(body)}};
}
function decode(json) {
  if (json.error || ['error','response.failed','response.incomplete'].includes(json.type)) throw Error('Model request failed');
  const parts = json.candidates?.[0]?.content?.parts ?? json.content ?? json.output?.flatMap(x=>x.content ?? []);
  if (parts) return parts.filter(x=>!x.thought).map(x=>x.text || '').join('');
  return json.choices?.[0]?.delta?.content ?? json.choices?.[0]?.message?.content ?? (json.type==='response.output_text.delta' ? json.delta : json.delta?.text) ?? '';
}
async function chat(profile,key,history,signal,update,stream=true) {
  const req=request(profile,key,history,stream);
  const response=await fetch(req.url,{...req.options,signal});
  if (!response.ok) throw Error('HTTP '+response.status);
  if (!response.headers.get('content-type')?.includes('event-stream')) {
    const answer=decode(await response.json());
    if (!answer.trim()) throw Error('Empty response');
    update(answer); return answer;
  }
  let answer='', pending='',done=false;
  const decoder=new TextDecoder();
  function line(raw) {
    if (!raw.startsWith('data:')) return;
    const value=raw.slice(5).trim();
    if (value==='[DONE]') {done=true;return;}
    if (!value) return;
    const event=JSON.parse(value), delta=decode(event);
    if (delta) {answer+=delta; update(delta);}
    if (event.choices?.[0]?.finish_reason || event.candidates?.[0]?.finishReason || ['response.completed','message_stop'].includes(event.type)) done=true;
  }
  for await (const bytes of response.body) {
    pending+=decoder.decode(bytes,{stream:true});
    const lines=pending.split('\n'); pending=lines.pop(); lines.forEach(line);
    if (done) break;
  }
  if (pending.trim()) line(pending+decoder.decode());
  if (!done || !answer.trim()) throw Error('Interrupted or empty response');
  return answer;
}
async function catalog(profile,key) {
  const models=new Set(), seen=new Set(); let cursor='';
  do {
    const url=new URL(baseURL(profile.base)+'/models');
    if (cursor) url.searchParams.set(profile.provider==='Gemini'?'pageToken':'after_id',cursor);
    const response=await fetch(url,{headers:headers(profile.provider,key),redirect:'error',signal:AbortSignal.timeout(30000)});
    if (!response.ok) throw Error('HTTP '+response.status);
    const data=await response.json();
    if (profile.provider==='Gemini') {
      for (const row of data.models ?? []) if (row.supportedGenerationMethods?.includes('generateContent')) models.add(row.name.replace(/^models\//,''));
      cursor=data.nextPageToken;
    } else {
      for (const row of data.data ?? []) if (row.id) models.add(row.id);
      cursor=data.has_more && data.last_id;
    }
    if (seen.has(cursor)) break; seen.add(cursor);
  } while (cursor);
  if (!models.size) throw Error('Empty model catalog');
  return [...models].sort();
}
module.exports={baseURL,endpoints,request,decode,chat,catalog};
