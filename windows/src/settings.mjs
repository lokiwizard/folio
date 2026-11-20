import {S,T,el,btn,select,row,modal,inputDialog,preference,uid,toast,save,localize} from './ui.mjs';
export const configHooks={refresh:()=>{},modelsChanged:()=>{}};
const palette=['#e87b72','#68a9d6','#71b893','#a686c8','#e6c452'];
const tagNames=[['局限','Limitations'],['疑问','Questions'],['核心创新','Key ideas'],['写作参考','Writing reference'],['默认','Default']];
const prompts=[
 ['这篇论文解决了什么问题？','What problem does this paper address?'],['主要结论有哪些实验证据？','What evidence supports the main findings?'],['从输入到输出，这个方法分哪几步？','How does the method go from input to output?'],['和已有方法相比，关键改进在哪里？','How does this method improve on prior work?'],['作者提到了哪些局限或失败案例？','What limitations or failure cases do the authors report?']
];
let endpoints={};
export function init(config){
  endpoints=config.endpoints;S.profiles=config.profiles;S.recents=config.recents;
  S.settings={lang:'zh',theme:'system',glass:88,font:14,defaultTag:'preset-4',tags:tagNames.map(([name,en],i)=>({id:'preset-'+i,name,en,preset:name,color:palette[i]})),prompts:prompts.map(([zh,en])=>({zh,en})),widths:{three:32,two:42},leftWidth:205,...config.settings};apply();
}
export function apply(){
  const s=S.settings;document.documentElement.dataset.dark=String(s.theme==='dark'||(s.theme==='system'&&matchMedia('(prefers-color-scheme:dark)').matches));
  document.documentElement.style.setProperty('--glass',s.glass+'%');document.documentElement.style.setProperty('--memo',s.font+'pt');localize();
}
export const tagTitle=t=>t.preset===t.name && t.en?T(t.name,t.en):t.name;
export async function language(){await preference({lang:S.settings.lang==='en'?'zh':'en'});apply();configHooks.refresh();}
const field=(label,input)=>el('label',{class:'field'},label,input);
export function settings(tab='appearance'){
 const body=el('div'),tabs=el('div',{class:'tabs'}),d=modal(T('设置','Settings'),tabs,body);d.style.width='540px';
 function show(t){body.replaceChildren();tabs.replaceChildren(...[['appearance',T('外观','Appearance')],['tags',T('语义高亮','Highlights')],['ai',T('AI 服务','AI services')]].map(([v,n])=>btn(n,()=>show(v),v===t?'active':'')));
 if(t==='appearance'){
   const change=async values=>{await preference(values);apply();configHooks.refresh();};
   body.append(field(T('语言','Language'),select([['zh','简体中文'],['en','English']],S.settings.lang,async v=>{await change({lang:v});d.close();settings(t);})),
     field(T('主题','Theme'),select([['system',T('跟随系统','System')],['light',T('浅色','Light')],['dark',T('深色','Dark')]],S.settings.theme,v=>change({theme:v}))),
     field(T('毛玻璃强度','Glass intensity'),el('input',{type:'range',min:0,max:100,value:S.settings.glass,oninput:e=>change({glass:+e.target.value})})),
     field(T('备注字号','Note font size'),select(Array.from({length:23},(_,i)=>[String(i+10),(i+10)+' pt']),String(S.settings.font),v=>change({font:+v}))));
 }else if(t==='tags'){
   const update=async()=>{await preference({tags:S.settings.tags,defaultTag:S.settings.defaultTag});configHooks.refresh();show(t);};
   for(const tag of S.settings.tags){
     const name=el('input',{value:tagTitle(tag),onchange:async e=>{if(e.target.value.trim()){tag.name=e.target.value.trim();tag.preset=null;await update();}}});
     const color=el('input',{type:'color',value:tag.color,onchange:async e=>{tag.color=e.target.value;await update();}});
     body.append(row(color,name,btn(tag.id===S.settings.defaultTag?'●':'○',async()=>{S.settings.defaultTag=tag.id;await update();})));
   }
   body.append(btn(T('添加标签','Add tag'),async()=>{const name=await inputDialog(T('标签名称','Tag name'));if(name?.trim()){S.settings.tags.push({id:uid(),name:name.trim(),color:'#73b588'});await update();}}));
 }else serviceForm(body,()=>show(t));
 }
 show(tab);
}
function absorb(result){S.profiles=result.profiles;S.settings.active=result.settings.active;configHooks.modelsChanged();}
function serviceForm(body,refresh){
  let selected=S.profiles.find(p=>p.id===S.settings.active)||S.profiles[0];
  const chooser=select([['',T('添加服务','Add service')],...S.profiles.map(p=>[p.id,p.provider+' · '+p.model])],selected?.id||'',id=>{selected=S.profiles.find(p=>p.id===id);fill();});
  const provider=select(Object.keys(endpoints).map(p=>[p,p]),selected?.provider||'OpenAI',v=>{base.value=endpoints[v];key.value='';model.value='';});
  const base=el('input',{type:'url'}),model=el('input'),key=el('input',{type:'password',autocomplete:'off'}),status=el('output');
  function fill(){provider.value=selected?.provider||'OpenAI';base.value=selected?.base||endpoints[provider.value];model.value=selected?.model||'';key.value='';key.placeholder=selected?T('留空保留已有密钥','Leave blank to keep saved key'):'API Key';}fill();
  async function store(){const config=await folio.profile({provider:provider.value,base:base.value.trim(),model:model.value.trim(),key:key.value.trim()});key.value='';absorb(config);selected=S.profiles.find(p=>p.id===S.settings.active);return selected;}
  body.append(field(T('账户','Account'),chooser),field(T('厂商','Provider'),provider),field(T('HTTPS 服务地址','HTTPS service address'),base),field('Model ID',model),field('API Key',key),
   row(btn(T('保存并使用','Save and use'),async()=>{await store();refresh();toast(T('已保存','Saved'));},'primary'),btn(T('测试连接','Test connection'),async()=>{const p=await store();status.textContent=await folio.test(p.id);}),btn(T('删除服务','Remove service'),async()=>{if(selected){absorb(await folio.removeProfile(selected.id));refresh();}})),status);
}
export function modelPicker(){
  if(!S.profiles.length){settings('ai');return;}
  let profile=S.profiles.find(p=>p.id===S.settings.active)||S.profiles[0];
  const search=el('input',{type:'search',placeholder:T('搜索或输入模型 ID','Search or enter model ID')}),list=el('div'),body=el('div');
  const d=modal(T('切换模型','Choose model'),body);
  const applyModel=async model=>{if(!model.trim())return;absorb(await folio.profile({...profile,model:model.trim(),key:''}));d.close();};
  function draw(){list.replaceChildren(...[...new Set([profile.model,...profile.models])].filter(m=>m.toLowerCase().includes(search.value.toLowerCase())).map(m=>btn(m,()=>applyModel(m))));}
  const chooser=select(S.profiles.map(p=>[p.id,p.provider+' · '+p.base]),profile.id,id=>{profile=S.profiles.find(p=>p.id===id);draw();});
  body.append(chooser,field(T('模型','Model'),search),row(btn(T('刷新目录','Refresh catalog'),async()=>{profile.models=await folio.models(profile.id);draw();}),btn(T('使用输入的 ID','Use entered ID'),()=>applyModel(search.value)),btn(T('配置服务','Configure'),()=>{d.close();settings('ai');})),list);
  search.oninput=draw;draw();
}
