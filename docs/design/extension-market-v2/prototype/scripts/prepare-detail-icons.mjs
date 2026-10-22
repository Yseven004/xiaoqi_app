import React from 'react';
import {renderToStaticMarkup} from 'react-dom/server';
import {ArrowLeft,ArrowRight,CaretRight,CaretUp,DotsThree,Plus,ChatCircle,GearSix,LinkSimple,Trash,ArrowSquareOut,FileText,Folder,ChatDots,Table,Presentation,Database,MagnifyingGlass,Code,FileMagnifyingGlass,NotePencil,BookOpen,PlugsConnected} from '@phosphor-icons/react';
import {mkdir,writeFile} from 'node:fs/promises';

const icons={back:ArrowLeft,'arrow-right':ArrowRight,'caret-right':CaretRight,'caret-up':CaretUp,dots:DotsThree,plus:Plus,chat:ChatCircle,gear:GearSix,link:LinkSimple,'trash-danger':Trash,external:ArrowSquareOut,'file-text':FileText,folder:Folder,'chat-dots':ChatDots,table:Table,presentation:Presentation,database:Database,search:MagnifyingGlass,code:Code,research:FileMagnifyingGlass,edit:NotePencil,book:BookOpen,plugs:PlugsConnected};
const directory=new URL('../public/icons/detail/',import.meta.url);
await mkdir(directory,{recursive:true});
for(const [name,Icon] of Object.entries(icons)){
  const svg=renderToStaticMarkup(React.createElement(Icon,{size:64,weight:'regular',color:name==='trash-danger'?'#a52b25':'#191919'}));
  await writeFile(new URL(`${name}.svg`,directory),`${svg}\n`);
}
console.log(`Prepared ${Object.keys(icons).length} independent Phosphor SVGs at public/icons/detail (viewBox 0 0 256 256).`);
