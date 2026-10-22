const driveSkills = [
  {name:'Google Docs', description:'阅读、编辑和创建文档', icon:'file-text'},
  {name:'Google Drive', description:'搜索与整理云端文件', icon:'folder'},
  {name:'Google Drive Comments', description:'查看、回复和处理评论', icon:'chat-dots'},
  {name:'Google Sheets', description:'读取表格并整理数据', icon:'table'},
  {name:'Google Slides', description:'创建和编辑演示文稿', icon:'presentation'},
];

const profiles = {
  drive: {
    subtitle:'云端文件与协作', category:'工作与效率',
    overview:'搜索并整理云端文件，在聊天中处理文档、表格与演示文稿。',
    prompts:['查找最近的项目文件，整理重点与下一步行动','参考品牌指南，修改这份产品介绍','汇总文件夹中的交付物、时间安排与待办事项'],
    appDescription:'连接云端文件、文档、表格与演示文稿',
    capabilities:driveSkills,
  },
  supabase: {
    subtitle:'数据库与开发工具', category:'开发工具',
    overview:'在聊天中了解数据库结构、查询数据并协助处理开发任务。',
    prompts:['查看项目中的数据表，解释它们之间的关系','查询最近新增的数据，整理成简明摘要','检查这段 SQL，并给出修改建议'],
    appDescription:'连接项目数据库与开发工具',
    capabilities:[
      {name:'查看表结构', description:'了解数据表、字段与关联关系', icon:'database'},
      {name:'查询数据', description:'根据问题生成并执行数据查询', icon:'search'},
      {name:'分析 SQL', description:'解释查询逻辑并提供修改建议', icon:'code'},
    ],
  },
  github: {
    subtitle:'代码仓库与团队协作', category:'开发工具',
    overview:'在聊天中了解代码仓库、梳理议题与拉取请求，整理开发工作的重点。',
    prompts:['解释这个仓库的结构、主要组件与请求流程','审阅这次拉取请求，整理改动、风险与待确认的问题','汇总最近的开发进展、风险与下一步行动'],
    appDescription:'连接代码仓库、议题与拉取请求',
  },
};

export function pluginDetail(entry) {
  const profile = profiles[entry.id] || {};
  return {
    subtitle:entry.description,
    category:entry.category || '个人工具',
    overview:entry.description,
    prompts:[`使用 ${entry.name} 整理这次工作的重点`,`查找与当前任务相关的资料`,`根据已有材料，整理下一步行动`],
    appDescription:entry.description,
    capabilities:(entry.tools || ['理解任务','处理材料','整理结果']).map((name,index)=>({
      name, description:entry.type==='mcp'?'在聊天中按任务调用这项工具':'按照既定方法处理材料并整理结果',
      icon:['file-text','search','folder'][index%3],
    })),
    ...profile,
  };
}

const readingCases = [
  {id:'question',title:'研究问题与结论',image:'research-question.svg',
    description:'把论文的研究问题、主要观点与关键结论放进同一个阅读框架。',
    prompt:'请精读这篇论文，先梳理研究问题、主要观点与关键结论。'},
  {id:'method',title:'方法与实验拆解',image:'research-method.svg',
    description:'逐步解释研究设计、实验过程与证据，说明结论如何得到支持。',
    prompt:'请拆解这篇论文的研究方法、实验设计与证据，说明它们如何支持结论。'},
  {id:'limits',title:'局限与后续方向',image:'research-limits.svg',
    description:'区分论文已回答的问题、适用范围与仍需验证的研究方向。',
    prompt:'请分析这篇论文的局限、适用范围，以及值得继续研究的问题。'},
];

export function skillDetail(entry) {
  const reading = entry.id === 'close-reading';
  return {
    category:reading ? '学术研究' : '工作方法',
    version:entry.version || 'v1.0.0',
    description:reading ? '从研究问题到结论，梳理论文的方法、证据与局限，帮助你快速建立清晰的阅读框架。' : entry.description,
    introduction:reading ? [
      ['梳理核心问题','提炼研究目标、主要观点与关键结论。'],
      ['拆解方法与证据','说明研究设计、实验过程和数据如何支持结论。'],
      ['识别局限与启发','整理适用范围、未解决的问题与后续研究方向。'],
    ] : [
      ['确认目标与材料','说明使用场景、输入材料和希望得到的结果。'],
      ['按照方法处理','根据技能说明中的工作步骤逐步完成任务。'],
      ['整理清晰的结果','检查结果是否符合目标，保留需要继续确认的问题。'],
    ],
    cases:reading ? readingCases : [],
  };
}
