#!/usr/bin/env node
'use strict';
// Local-only content checking. Input paths are read locally; nothing is sent over a network.
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const katex=require('../App/MathRenderer/katex.min.js');
const options={throwOnError:true,strict:'error',trust:false,maxExpand:1000,maxSize:20,output:'htmlAndMathml'};
function validateBlock(b,where){
 if(!['math','text'].includes(b.kind)||typeof b.value!=='string') throw Error(where+': invalid RichBlock');
 const expressions=[];
 if(b.kind==='math') expressions.push(b.value);
 else {
  const pattern=/\\\(([\s\S]*?)\\\)/g; let m;
  while((m=pattern.exec(b.value))) expressions.push(m[1]);
  const plain=b.value.replace(pattern,'');
  if(plain.includes('\\(')||plain.includes('\\)')) throw Error(where+': unbalanced inline delimiters');
 }
 for(const tex of expressions){
  if(/\\(?:href|url|includegraphics|html\w*|class|style|cssId)\b/.test(tex)) throw Error(where+': external or HTML command forbidden');
  katex.renderToString(tex,{...options,displayMode:b.kind==='math'});
 }
 return expressions.length;
}
function walk(value,where='$'){
 if(Array.isArray(value)) return value.reduce((n,x,i)=>n+walk(x,where+'['+i+']'),0);
 if(value&&typeof value==='object'){
  if(Object.hasOwn(value,'kind')&&Object.hasOwn(value,'value')) return validateBlock(value,where);
  return Object.entries(value).reduce((n,[k,v])=>n+walk(v,where+'.'+k),0);
 }
 return 0;
}
const synthetic=[
 {kind:'text',value:'合成测试：若 \\(x_1^2+\\frac{1}{2}=0\\)，求根。'},
 {kind:'math',value:'\\frac{a+b}{c+d}=x_i^{n+1}'},
 {kind:'math',value:'A=\\begin{pmatrix}1&2\\\\3&4\\end{pmatrix}'},
 {kind:'math',value:'f(x)=\\begin{cases}x^2&x>0\\\\0&x\\le0\\end{cases}'},
 {kind:'math',value:'\\int_0^1 x^2\\,\\mathrm{d}x=\\frac13'}
];
assert.equal(walk(synthetic),5);
assert.throws(()=>walk([{kind:'math',value:'\\frac{1}'}]));
assert.throws(()=>walk([{kind:'math',value:'\\href{https://example.invalid}{x}'}]));
assert.throws(()=>walk([{kind:'text',value:'bad \\(x'}]));
for(const file of process.argv.slice(2)){
 const count=walk(JSON.parse(fs.readFileSync(file,'utf8').replace(/^\uFEFF/,'')));
 if(count===0) throw Error(file+': no math expressions found');
 console.log(path.basename(file)+': '+count+' TeX expressions passed');
}
console.log('Synthetic fraction, scripts, matrix, cases, inline and rejection checks passed; KaTeX '+katex.version);
