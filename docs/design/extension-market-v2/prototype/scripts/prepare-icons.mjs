import fs from 'node:fs/promises';
import path from 'node:path';
import * as icons from 'simple-icons';
const dir=path.resolve('public/icons');
await fs.mkdir(dir,{recursive:true});
const all=Object.values(icons).filter(x=>x&&typeof x==='object'&&x.slug);
const names=['github','googledrive','notion','supabase','figma','slack','canva','linear','airtable','vercel','dropbox','todoist','shopify'];
for(const slug of names){
 const icon=all.find(x=>x.slug===slug);
 let svg,hex;
 if(icon){svg=icon.svg;hex=icon.hex;}
 else{const response=await fetch(`https://raw.githubusercontent.com/simple-icons/simple-icons/13.21.0/icons/${slug}.svg`);if(!response.ok)throw new Error(`${slug}: HTTP ${response.status}`);svg=await response.text();hex=slug==='slack'?'4A154B':'00C4CC';}
 if(!svg.includes('<svg')||!svg.includes('viewBox="0 0 24 24"'))throw new Error(`Unexpected SVG for ${slug}`);
 await fs.writeFile(path.join(dir,slug+'.svg'),svg.replace('<svg ',`<svg fill="#${hex}" `));
 console.log(`${slug}: independent SVG, viewBox 0 0 24 24`);
}
