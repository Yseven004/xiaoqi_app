import {prototypeBrand} from './config';

export const initialPlugins = [
 {id:'github',name:'GitHub',icon:'github',description:'管理代码仓库、议题与拉取请求',category:'热门',type:'mcp',installed:true,author:'GitHub',tools:['搜索代码仓库','读取文件与议题','创建拉取请求']},
 {id:'drive',name:'Google Drive',icon:'googledrive',description:'查找文档，连接你的工作资料',category:'热门',type:'plugin',tools:['搜索文件','读取文档','整理文件夹']},
 {id:'notion',name:'Notion',icon:'notion',description:'连接笔记、文档与知识库',category:'热门',type:'mcp',installed:true,author:'Notion',tools:['搜索页面','读取数据库','创建笔记']},
 {id:'supabase',name:'Supabase',icon:'supabase',description:'查询数据，管理你的项目',category:'热门',type:'mcp',author:'Supabase',tools:['查看项目','查询数据库']},
 {id:'figma',name:'Figma',icon:'figma',description:'从设计稿到可用的界面',category:'热门',type:'plugin',installed:true,author:'Figma',tools:['读取设计','查看组件','导出素材']},
 {id:'slack',name:'Slack',icon:'slack',description:'搜索消息，跟进团队协作',category:'热门',type:'mcp',author:'Slack',tools:['搜索消息','读取频道']},
 {id:'canva',name:'Canva',icon:'canva',description:'制作演示文稿与视觉内容',category:'新品推荐',type:'plugin',author:'Canva',tools:['搜索设计','创建演示文稿']},
 {id:'linear',name:'Linear',icon:'linear',description:'让项目与任务有条不紊',category:'新品推荐',type:'mcp',author:'Linear',tools:['查看任务','更新进度']},
 {id:'airtable',name:'Airtable',icon:'airtable',description:'连接表格里的想法与数据',category:'新品推荐',type:'mcp',author:'Airtable',tools:['读取表格','查找记录']},
 {id:'vercel',name:'Vercel',icon:'vercel',description:'查看部署，跟进你的项目',category:'新品推荐',type:'mcp',author:'Vercel',tools:['查看部署','读取构建日志']},
 {id:'dropbox',name:'Dropbox',icon:'dropbox',description:'查找、读取和整理文件',category:'工作与效率',type:'mcp',author:'Dropbox',tools:['查找文件','读取资料']},
 {id:'todoist',name:'Todoist',icon:'todoist',description:'管理待办，安排接下来的事',category:'工作与效率',type:'mcp',author:'Doist',tools:['读取待办','创建任务']},
 {id:'shopify',name:'Shopify',icon:'shopify',description:'查看商品与商店信息',category:'工作与效率',type:'mcp',author:'Shopify',tools:['查看商品','读取订单']},
 {id:'paper-kit',name:'阅读助手',icon:'book',description:'精读、摘录与笔记整理',category:'工作与效率',type:'plugin',author:'小七',tools:['论文精读','摘录整理','生成读书笔记']},
].map(entry=>({...entry,official:true,author:prototypeBrand.officialDeveloper,...(entry.type==='mcp'?{url:'https://mcp.example.com/mcp'}:{})}));
export const defaultBody='# 使用说明\n\n描述这个技能适用的场景，以及小七应该怎样完成任务。\n\n## 工作步骤\n1. 确认目标和输入材料。\n2. 按照你的方法处理。\n3. 给出清晰的结果。\n';
export const initialSkills=[
 {id:'skill-creator',name:'skill-creator',icon:'skill',description:'把你的工作方法整理成可复用的技能',type:'skill',installed:true,author:'个人',body:defaultBody},
 {id:'close-reading',name:'论文精读',icon:'book',description:'从研究问题到结论，梳理论文的方法、证据与局限，帮助你快速建立清晰的阅读框架。',type:'skill',installed:true,official:true,author:prototypeBrand.officialDeveloper,body:'# 论文精读\n\n先梳理研究问题，再提取方法、证据与结论。\n\n## 输出\n- 研究问题\n- 核心论点\n- 方法与证据\n- 局限与待确认的问题'},
];
export const categories=['热门','新品推荐','工作与效率'];
export const introText='我想创建一个新技能。请先询问我的使用场景、需要处理的材料和希望得到的结果，再帮我逐步整理成可复用的技能。';
export const uid=()=>`personal-${Date.now().toString(36)}`;
export const describeSize=n=>n<1024?`${n} B`:n<1048576?`${(n/1024).toFixed(1)} KB`:`${(n/1048576).toFixed(1)} MB`;
export function readSaved(){try{return JSON.parse(localStorage.getItem('xiaoqi-market-v2-demo')||'null');}catch{return null;}}
