import React,{useEffect,useRef,useState} from 'react';
import {useMarket,Brand,IconButton,Empty} from './ui';
import {developerName} from './config';
import {pluginDetail,skillDetail} from './detail-data';
import './details.css';

export function DetailIcon({name,size=22,className=''}) {
  return <img className={`detail-icon ${className}`} src={`/icons/detail/${name}.svg`} width={size} height={size} alt="" aria-hidden="true"/>;
}

function MoreMenu({entry}) {
  const {menu,setMenu,setModal,notify,openEditor}=useMarket();
  const button=useRef(null),panel=useRef(null);
  const id=`detail-${entry.id}`,open=menu===id;
  useEffect(()=>{if(open)panel.current?.querySelector('button')?.focus();},[open]);
  function close(){setMenu(null);button.current?.focus();}
  async function copyLink(){
    setMenu(null);
    const link=new URL(location.href);link.hash=`${entry.type==='skill'?'skills':'plugins'}/detail/${entry.id}`;
    try{await navigator.clipboard.writeText(link.href);notify('链接已复制');}
    catch{setModal({type:'copy-link',url:link.href});}
  }
  function keydown(event){
    const buttons=[...panel.current.querySelectorAll('button')],index=buttons.indexOf(document.activeElement);
    if(event.key==='Escape'){event.stopPropagation();close();}
    if(event.key==='ArrowDown'||event.key==='ArrowUp'){event.preventDefault();buttons[(index+(event.key==='ArrowDown'?1:-1)+buttons.length)%buttons.length]?.focus();}
    if(event.key==='Tab')setMenu(null);
  }
  return <div className="detail-menu-anchor">
    <button ref={button} type="button" className="icon-button detail-more" aria-label={`更多 ${entry.name} 操作`} aria-haspopup="menu" aria-expanded={open} onClick={()=>setMenu(open?null:id)}><DetailIcon name="dots" size={25}/></button>
    {open&&<div ref={panel} className="popover detail-more-menu" role="menu" aria-label={`${entry.name} 操作`} onKeyDown={keydown}>
      <button role="menuitem" onClick={copyLink}><DetailIcon name="link"/>复制链接</button>
      {entry.personal&&entry.type==='skill'&&<button role="menuitem" onClick={()=>openEditor(entry)}><DetailIcon name="edit"/>编辑技能</button>}
      {entry.installed&&<button role="menuitem" className="detail-danger" onClick={()=>{setMenu(null);setModal({type:'remove',entry});}}><DetailIcon name="trash-danger"/>卸载</button>}
    </div>}
  </div>;
}

function Capabilities({entry,profile}) {
  return <>
    <section className="extension-detail-section"><h2>应用 <span>1</span></h2><div className="detail-flat-row"><Brand entry={entry}/><div><h3>{entry.name}</h3><p>{profile.appDescription}</p></div></div></section>
    <section className="extension-detail-section"><h2>{entry.type==='mcp'?'工具':'技能'} <span>{profile.capabilities.length}</span></h2>
      <div>{profile.capabilities.map(item=><div className="detail-flat-row" key={item.name}><span className="detail-capability-icon"><DetailIcon name={item.icon}/></span><div><h3>{item.name}</h3><p>{item.description}</p></div></div>)}</div>
    </section>
  </>;
}

function PluginDetail({entry}) {
  const {go,setModal,startChat}=useMarket(),profile=pluginDetail(entry);
  const mcp=entry.type==='mcp';
  function example(prompt){if(entry.installed)startChat(entry,prompt);else setModal({type:'install',entry,prompt});}
  return <article className="extension-detail">
    <nav className="breadcrumbs detail-breadcrumbs" aria-label="当前位置"><button onClick={()=>go('plugins')}>插件</button><DetailIcon name="caret-right" size={16}/><span>{entry.name}</span></nav>
    <header className="extension-detail-header">
      <div className="extension-detail-identity"><Brand entry={entry} large/><div><h1>{entry.name}</h1><p>{mcp?'MCP 服务':developerName(entry)}<span aria-hidden="true"> · </span>{profile.subtitle}</p></div></div>
      <div className="extension-detail-actions"><MoreMenu entry={entry}/>{entry.installed?<><button className="button detail-manage" onClick={()=>setModal({type:mcp?'mcp':'manage-plugin',entry})}><DetailIcon name="gear" size={20}/>管理</button><button className="button primary" onClick={()=>startChat(entry)}><DetailIcon name="chat" size={20}/>在聊天中试用</button></>:<button className="button primary" onClick={()=>setModal({type:'install',entry})}><DetailIcon name="plus" size={20}/>安装插件</button>}</div>
    </header>
    <section className="prompt-preview" aria-label="使用示例">{profile.prompts.map(prompt=><button className="detail-prompt" key={prompt} onClick={()=>example(prompt)}><Brand entry={entry}/><span><strong>{entry.name}</strong><span>{prompt}</span></span><span className="prompt-arrow"><DetailIcon name="arrow-right" size={20}/></span></button>)}</section>
    <p className="extension-overview">{profile.overview}</p>
    <Capabilities entry={entry} profile={profile}/>
    <section className="extension-detail-section detail-information"><h2>信息</h2><dl>
      <div><dt>开发者</dt><dd>{developerName(entry)}</dd></div>
      {mcp&&<div><dt>类型</dt><dd>MCP 服务</dd></div>}
      <div><dt>类别</dt><dd>{profile.category}</dd></div>
      {mcp&&<><div><dt>连接状态</dt><dd>{!entry.installed?'未连接':entry.status==='error'?'连接中断':entry.status==='auth'?'需要登录':'已连接'}</dd></div><div><dt>传输方式</dt><dd>HTTP</dd></div><div><dt>服务器地址</dt><dd className="detail-url">{entry.url||'https://mcp.example.com/mcp'}</dd></div></>}
      <div><dt>网站</dt><dd>{entry.website?<a className="detail-external" href={entry.website} target="_blank" rel="noreferrer" aria-label={`打开 ${entry.name} 网站`}><DetailIcon name="external" size={19}/></a>:<span className="unprovided">未提供</span>}</dd></div>
      {!mcp&&<div><dt>隐私政策</dt><dd>{entry.privacyUrl?<a className="detail-external" href={entry.privacyUrl} target="_blank" rel="noreferrer" aria-label={`打开 ${entry.name} 隐私政策`}><DetailIcon name="external" size={19}/></a>:<span className="unprovided">未提供</span>}</dd></div>}
    </dl></section>
  </article>;
}

function SkillDetail({entry}) {
  const {go,setModal,startChat}=useMarket(),profile=skillDetail(entry);
  const [expanded,setExpanded]=useState(true);
  return <article className="skill-detail">
    <header className="skill-detail-nav"><IconButton label="返回技能" onClick={()=>go('skills')}><DetailIcon name="back" size={24}/></IconButton><h1>技能详情</h1><MoreMenu entry={entry}/></header>
    <div className="skill-detail-identity"><span className="skill-detail-mark"><DetailIcon name="research" size={58}/></span><div><h2>{entry.name}</h2><p>{profile.description}</p><span className="skill-detail-meta">{profile.category}<span> · </span>{developerName(entry)}<span> · </span>{profile.version}</span></div></div>
    <section className="skill-introduction"><h2>技能介绍</h2><ol id="skill-introduction-content">{profile.introduction.slice(0,expanded?undefined:1).map(([title,text])=><li key={title}><strong>{title}：</strong>{text}</li>)}</ol><button className="skill-expand" aria-expanded={expanded} aria-controls="skill-introduction-content" onClick={()=>setExpanded(!expanded)}>{expanded?'收起':'展开介绍'}<DetailIcon name="caret-up" size={18} className={expanded?'':'flipped'}/></button></section>
    {profile.cases.length>0&&<section className="skill-cases"><h2>精选案例</h2><div className="skill-case-grid">{profile.cases.map(item=><button className="skill-case" key={item.id} onClick={()=>setModal({type:'skill-case',entry,item})}><h3>{item.title}</h3><img src={`/previews/${item.image}`} alt={`${item.title}的结构化报告示例`}/></button>)}</div></section>}
    <footer className="skill-detail-footer"><button className="button primary" onClick={()=>entry.installed?startChat(entry):setModal({type:'install',entry})}>{entry.installed?'在聊天中试用':'添加技能'}</button></footer>
  </article>;
}

export function Detail() {
  const {entry,kind,go}=useMarket();
  if(!entry)return <Empty title="内容不存在" body="它可能已被移除。" action="返回市场" onAction={()=>go(kind)}/>;
  return entry.type==='skill'?<SkillDetail key={entry.id} entry={entry}/>:<PluginDetail entry={entry}/>;
}
