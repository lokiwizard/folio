import {S,T,$,el,btn,select,row,modal,inputDialog,save,toast,pageLabel,popup} from './ui.mjs';
import {go,refreshMarks} from './reader.mjs';
import {artwork,editor} from './editor.mjs';
export const cardHooks={chat:()=>{},tab:()=>{}};
let undo=[],filter='',term='',section='pin',observer;
export function resetCards(){undo=[];filter='';term='';observer?.disconnect();}
const name=c=>c.title||(c.kind==='pin'?T('图表便签','Pinned figure'):T('批注','Annotation'));
function pages(c){return [...new Set(c.anchors.map(a=>a.page))].map(pageLabel).join(', ');}
function changed(){save();refreshMarks();showCards(section);}
export function removeCard(c){
  const i=S.state.cards.indexOf(c);if(i<0)return;
  undo.push({i,c});S.state.cards.splice(i,1);if(c.source)S.state.dismissed.push(c.source);changed();toast(T('已删除，可撤销','Removed. Undo is available.'));
}
function undelete(){const item=undo.pop();if(!item)return;S.state.cards.splice(item.i,0,item.c);S.state.dismissed=S.state.dismissed.filter(s=>s!==item.c.source);changed();}
function reorder(source,target,below){
  if(!source||source===target||source.kind!==target.kind)return;
  const list=S.state.cards;list.splice(list.indexOf(source),1);list.splice(list.indexOf(target)+(below?1:0),0,source);changed();
}
function cardOptions(c,e){
  const title=btn(T('重命名','Rename'),async()=>{const v=await inputDialog(T('卡片名称','Card title'),c.title||'');if(v!==null){c.title=v;changed();}});
  const memo=btn(T('编辑备注','Edit note'),async()=>{const v=await inputDialog(T('个人备注','Personal note'),c.note||'',{multi:true});if(v!==null){c.note=v;c.noteEditedAt=Date.now();changed();}});
  const scale=select([.8,1,1.25,1.5,2].map(x=>[String(x),x*100+'%']),String(c.scale||1),v=>{c.scale=Number(v);changed();});
  const tools=[title,memo,scale,btn(T('问 AI','Ask AI'),()=>cardHooks.chat(c)),btn(T('删除','Delete'),()=>removeCard(c))];
  if(c.kind==='pin'){
    const color=el('input',{type:'color',value:c.color||'#fafafa',title:T('便签底色','Card background'),onchange:e=>{c.color=e.target.value;changed();}});
    tools.push(color,btn(T('复制图片','Copy image'),async()=>folio.copyImage((await artwork(c)).toDataURL())));
  }else tools.push(select([['',T('独立笔记','Independent note')],...S.settings.tags.map(t=>[t.id,t.name])],c.tag||'',v=>{c.tag=v;changed();}));
  popup(e.clientX,e.clientY,...tools);
}
export function showCards(kind=section,focus){
  section=kind;const host=$('rightContent');observer?.disconnect();host.replaceChildren();
  if(!S.doc)return;const paper=S.id;
  const tools=el('div',{class:'tools'});host.append(tools);
  if(kind==='note'){
    const input=el('input',{type:'search',value:term,placeholder:T('搜索批注或备注','Find annotations')});
    input.oninput=()=>{term=input.value;showCards(kind);const i=host.querySelector('input');i.focus();};
    tools.append(input,select([['',T('所有标签','All tags')],...S.settings.tags.map(t=>[t.id,t.name])],filter,v=>{filter=v;showCards(kind);}));
  }
  if(undo.length)tools.append(btn(T('撤销删除','Undo delete'),undelete));
  const list=S.state.cards.filter(c=>c.kind===kind && (kind==='pin'||((!filter||filter===c.tag)&&[c.text,c.title,c.note].some(s=>(s||'').toLowerCase().includes(term.toLowerCase())))));
  if(!list.length)host.append(el('p',{class:'muted',textContent:kind==='pin'?T('框选论文中的图表即可固定在此处。','Select a figure in the paper to pin it here.'):T('选中原文并添加高亮或笔记。','Select a passage to highlight it or add a note.')}));
  observer=new IntersectionObserver(entries=>{for(const e of entries){if(!e.isIntersecting)continue;observer.unobserve(e.target);const card=S.state.cards.find(c=>c.id===e.target.dataset.id);if(!card)continue;artwork(card,600).then(canvas=>{if(e.target.isConnected && paper===S.id)e.target.src=canvas.toDataURL();}).catch(()=>{});}}, {root:host,rootMargin:'150px'});
  for(const c of list){
    const box=el('article',{class:'card',draggable:true});box.dataset.id=c.id;
    if(c.color){box.style.background=c.color;box.style.color='#212a25';}
    const tag=S.settings.tags.find(t=>t.id===c.tag),label=el('strong',{textContent:c.title||tag?.name||name(c)});
    box.append(row(btn(c.collapsed?'▸':'▾',()=>{c.collapsed=!c.collapsed;changed();}),label,btn(pages(c),()=>{const a=c.anchors[0];go(a.page,[a.rect[0],a.rect[3]],true);}),btn('…',e=>cardOptions(c,e))));
    if(!c.collapsed){
      if(c.kind==='pin'){
        const img=el('img',{alt:name(c),onclick:()=>editor(c,()=>showCards(kind)),oncontextmenu:e=>{e.preventDefault();cardOptions(c,e);}});img.dataset.id=c.id;img.style.width=(c.scale||1)*100+'%';img.style.maxWidth=(c.scale||1)>1?'none':'100%';const wrap=el('div',{},img);wrap.style.overflow='auto';box.append(wrap);observer.observe(img);
      }else{
        const quote=el('p',{class:'quote truncated',textContent:c.text});quote.style.fontSize=(c.scale||1)+'em';box.append(quote);
        if(c.text.length>100)box.append(btn(T('展开全文','Expand text'),()=>quote.classList.toggle('truncated')));
      }
      if(c.note)box.append(el('p',{class:'memo',textContent:c.note}));
    }
    box.ondragstart=e=>{e.dataTransfer.setData('application/x-folio-card',c.id);e.dataTransfer.effectAllowed='copyMove';host.classList.add('dragging');dropZone.hidden=false;};
    box.ondragend=()=>{dropZone.hidden=true;host.classList.remove('dragging');};
    box.ondragover=e=>{if(e.dataTransfer.types.includes('application/x-folio-card'))e.preventDefault();};
    box.ondrop=e=>{const from=S.state.cards.find(s=>s.id===e.dataTransfer.getData('application/x-folio-card'));if(!from)return;e.preventDefault();e.stopPropagation();
      const b=host.getBoundingClientRect();if(e.clientX>b.right-32)removeCard(from);else reorder(from,c,e.clientY>box.getBoundingClientRect().top+box.offsetHeight/2);};
    host.append(box);
  }
  const dropZone=el('div',{class:'dragDelete',textContent:T('松开删除','Drop to delete'),hidden:true});dropZone.ondragover=e=>e.preventDefault();dropZone.ondrop=e=>{e.preventDefault();const c=S.state.cards.find(c=>c.id===e.dataTransfer.getData('application/x-folio-card'));if(c)removeCard(c);};host.append(dropZone);
  host.ondragover=e=>{const b=host.getBoundingClientRect();if(e.clientY<b.top+35)host.scrollTop-=12;if(e.clientY>b.bottom-35)host.scrollTop+=12;};
  if(focus)host.querySelector('[data-id="'+CSS.escape(focus)+'"]')?.scrollIntoView({block:'center'});
}
export async function exportNotes(){
  const id=S.id,state=structuredClone(S.state),sections=['# '+S.name,''],pictures=[];
  const tags=[...S.settings.tags,{id:'',name:T('独立笔记','Independent notes')}];
  for(const tag of tags){
    const group=state.cards.filter(c=>c.kind==='note' && (S.settings.tags.some(t=>t.id===c.tag)?c.tag:'')===tag.id);
    if(!group.length)continue;sections.push('## '+tag.name,'');
    for(const c of group)sections.push('### '+(c.title?c.title+' · ':'')+pages(c),'',...c.text.split('\n').map(s=>'> '+s),'',c.note||'','');
  }
  const pins=state.cards.filter(c=>c.kind==='pin');if(pins.length)sections.push('## '+T('固定图表','Pinned figures'),'');
  for(const c of pins){if(S.id!==id)throw Error(T('文档已切换','Document changed'));const canvas=await artwork(c,3000);sections.push('### '+(c.title?c.title+' · ':'')+pages(c),'',{figure:pictures.length},'',c.note||'','');pictures.push(canvas.toDataURL());}
  await folio.exportNotes(id,sections,pictures);
}
