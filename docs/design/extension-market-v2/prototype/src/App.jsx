import React,{useState,useRef,useEffect} from 'react';
import {Check,X,SlidersHorizontal,ArrowUpRight} from '@phosphor-icons/react';
import {MarketContext,IconButton} from './ui';
import {initialPlugins,initialSkills,readSaved,defaultBody,uid} from './data';
import {restoreCatalog} from './config';
import {Market,ListPage,Connections,Chat} from './views';
import {Detail} from './details';
import {Editor} from './editor';
import {Modals} from './dialogs';

const readRoute=()=>decodeURIComponent(location.hash.slice(1)||'plugins').split('/');
export function App(){
 const initial=useRef(readSaved());
 const [route,setRoute]=useState(readRoute),[plugins,setPlugins]=useState(()=>restoreCatalog(initial.current?.plugins,initialPlugins)),[skills,setSkills]=useState(()=>restoreCatalog(initial.current?.skills,initialSkills)),[drafts,setDrafts]=useState(initial.current?.drafts||[]);
 const [chatPrompt,setChatPrompt]=useState(null);
 const [query,setQuery]=useState(''),[visibility,setVisibility]=useState('public'),[menu,setMenu]=useState(null),[modal,setModal]=useState(null),[toast,setToast]=useState('');
 const [review,setReview]=useState(false),[viewport,setViewport]=useState('auto'),[demoState,setDemoState]=useState('normal'),[editor,setEditor]=useState(null);
 const dirty=useRef(false),discard=useRef(null),routeRef=useRef(route),timer=useRef(null),modalRef=useRef(modal);routeRef.current=route;modalRef.current=modal;
 const kind=route[0]==='skills'?'skills':'plugins',screen=route[1]||'home';
 const entries=kind==='skills'?skills:plugins,installed=entries.filter(x=>x.installed),entry=[...plugins,...skills].find(x=>x.id===route[2]);
 useEffect(()=>{try{localStorage.setItem('xiaoqi-market-v2-demo',JSON.stringify({plugins,skills,drafts}));}catch{}},[plugins,skills,drafts]);
 useEffect(()=>{const pop=()=>{const next=readRoute();if(modalRef.current){history.pushState({},'',`#${routeRef.current.join('/')}`);setModal(null);return;}if(dirty.current&&routeRef.current[1]==='editor'&&next.join('/')!==routeRef.current.join('/')){history.pushState({},'',`#${routeRef.current.join('/')}`);discard.current=()=>go(next.join('/'),true);setModal({type:'discard'});return;}setRoute(next);setQuery('');setMenu(null);setModal(null);};const unload=e=>{if(dirty.current){e.preventDefault();e.returnValue='';}};window.addEventListener('popstate',pop);window.addEventListener('beforeunload',unload);return()=>{window.removeEventListener('popstate',pop);window.removeEventListener('beforeunload',unload);};},[]);
 useEffect(()=>{const key=e=>{if(e.key==='Escape')setMenu(null);};document.addEventListener('keydown',key);return()=>document.removeEventListener('keydown',key);},[]);
 function notify(text){setToast(text);clearTimeout(timer.current);timer.current=setTimeout(()=>setToast(''),1700);}
 function go(path,replace=false){setMenu(null);setModal(null);setQuery('');setDemoState('normal');history[replace?'replaceState':'pushState']({},'',`#${path}`);setRoute(path.split('/'));window.scrollTo({top:0});}
 function back(){if(screen==='editor'&&dirty.current){discard.current=()=>go('skills');setModal({type:'discard'});}else go(kind);}
 function install(item,value){(item.type==='skill'?setSkills:setPlugins)(xs=>xs.map(x=>x.id===item.id?{...x,installed:value,status:value?'ready':undefined}:x));notify(value?`已添加 ${item.name}`:`已移除 ${item.name}`);}
 function startChat(item,prompt=''){setChatPrompt({entryId:item.id,text:prompt});go(`${item.type==='skill'?'skills':'plugins'}/chat/${item.id}`);}
 function openEditor(item){const d=item||{id:uid(),name:'',description:'',body:defaultBody,new:true};setEditor({...d,files:d.files||[{name:'SKILL.md',content:d.body||defaultBody}],active:'SKILL.md',filePanel:false});dirty.current=false;go('skills/editor');}
 function saveSkill(){const content=editor.files.find(f=>f.name==='SKILL.md')?.content||'';const value={...editor,name:editor.name.trim(),body:content,icon:'skill',type:'skill',personal:true,installed:true,author:'你',new:undefined,filePanel:undefined};setSkills(xs=>[...xs.filter(x=>x.id!==value.id),value]);setDrafts(xs=>xs.filter(x=>x.id!==value.id));dirty.current=false;go('skills');notify('技能已保存');}
 function saveDraft(){setDrafts(xs=>[...xs.filter(x=>x.id!==editor.id),{...editor,name:editor.name||'未命名技能'}]);dirty.current=false;setModal(null);discard.current?.();notify('草稿已保留');}
 const api={route,kind,screen,plugins,setPlugins,skills,setSkills,drafts,setDrafts,entries,installed,entry,query,setQuery,visibility,setVisibility,menu,setMenu,modal,setModal,demoState,setDemoState,editor,setEditor,dirty,discard,go,back,install,openEditor,saveSkill,saveDraft,notify,startChat,chatPrompt};
 const screens={home:Market,installed:ListPage,category:ListPage,detail:Detail,connections:Connections,editor:Editor,chat:Chat};const Screen=screens[screen]||Market;
 return <MarketContext.Provider value={api}><div className={`prototype-stage viewport-${viewport}`} onClick={e=>{if(menu&&!e.target.closest('.popover,.add-anchor,.row-menu-anchor,.detail-menu-anchor'))setMenu(null);}}><div className={`app-surface ${screen==='editor'?'editor-mode':''} ${screen==='chat'?'chat-mode':''} ${screen==='detail'&&entry?.type==='skill'?'skill-detail-mode':''}`} aria-label="小七扩展市场设计原型"><Screen key={route.join('/')}/></div><div className="review-launcher"><button onClick={()=>setReview(!review)} aria-label="打开原型评审工具"><SlidersHorizontal size={17}/><span>设计预览</span></button></div>{review&&<aside className="review-panel" aria-label="原型评审工具"><header><strong>原型评审</strong><IconButton label="关闭评审工具" onClick={()=>setReview(false)}><X size={18}/></IconButton></header><p>演示数据 · 不连接正式服务</p><label>预览尺寸<select aria-label="预览尺寸" value={viewport} onChange={e=>setViewport(e.target.value)}><option value="auto">跟随窗口</option><option value="tablet">平板 · 834</option><option value="phone">手机 · 390</option></select></label><label>页面状态<select aria-label="页面状态" value={demoState} onChange={e=>setDemoState(e.target.value)}><option value="normal">正常</option><option value="loading">加载占位</option><option value="empty">空状态</option><option value="error">加载失败</option></select></label><button className="button secondary" onClick={()=>{dirty.current=false;setPlugins(initialPlugins);setSkills(initialSkills);setDrafts([]);setVisibility('public');go('plugins');notify('已重置演示数据');}}>重置演示数据</button><a href="/review.html" target="_blank" rel="noreferrer">查看评审说明<ArrowUpRight size={15}/></a></aside>}{toast&&<div className="toast" role="status"><Check size={18}/>{toast}</div>}<Modals/></div></MarketContext.Provider>;
}
