'use strict';
(() => {
 let token = '', measuredReadyToken = '', lastErrors = [];
 const options = {throwOnError:true, strict:'error', trust:false, maxExpand:1000, maxSize:20, output:'htmlAndMathml'};
 function math(value, display) {
   const span=document.createElement(display?'div':'span');
   if(display) span.className='formula';
   katex.render(value,span,{...options,displayMode:display});
   return span;
 }
 function measure(t, errors) {
   if(t!==token || measuredReadyToken!==t)return;
   window.webkit.messageHandlers.mathRenderer.postMessage({token:t,height:Math.ceil(document.getElementById('content').getBoundingClientRect().height + 12),errors});
 }
 window.renderContent = async payload => {
   token=payload.token; measuredReadyToken=''; const t=token, errors=[];
   document.documentElement.style.fontSize=Math.max(20,Math.min(34,payload.fontSize||26))+'px';
   const content=document.getElementById('content'); content.replaceChildren();
   for(const block of payload.blocks) {
     try {
       if(block.kind==='math') content.append(math(block.value,true));
       else if(block.kind==='text') {
         const p=document.createElement('p'); let cursor=0;
         const pattern=/\\\(([\s\S]*?)\\\)/g; let match;
         while((match=pattern.exec(block.value))) {
           p.append(document.createTextNode(block.value.slice(cursor,match.index)),math(match[1],false)); cursor=pattern.lastIndex;
         }
         p.append(document.createTextNode(block.value.slice(cursor))); content.append(p);
       } else throw Error('未知内容类型');
     } catch(e) {
       errors.push(String(e.message));
       const p=document.createElement('p');p.className='error';p.textContent='公式排版失败，请打开原题核对。';content.append(p);
     }
   }
   if(content.querySelector('.katex')) {
     try {
       const faces=await document.fonts.load('26px KaTeX_Main','x1');
       if(faces.length===0) errors.push('离线公式主字体定义缺失');
     } catch(e) { errors.push('离线公式主字体加载失败'); }
   }
   await document.fonts.ready;
   if(t!==token)return;
   if(typeof katex==='undefined' || document.styleSheets.length < 2) errors.push('离线公式脚本或样式资源未加载');
   for(const face of document.fonts) {
     if(face.status==='error') errors.push('离线公式字体加载失败: '+face.family);
   }
   if(content.querySelector('.katex') && !document.fonts.check('26px KaTeX_Main')) errors.push('离线公式主字体未加载');
   lastErrors=errors; measuredReadyToken=t;
   requestAnimationFrame(()=>requestAnimationFrame(()=>measure(t,errors)));
 };
 window.addEventListener('resize',()=>measure(token,lastErrors));
 window.addEventListener('load',()=>window.webkit.messageHandlers.mathRenderer.postMessage({ready:true}));
})();
