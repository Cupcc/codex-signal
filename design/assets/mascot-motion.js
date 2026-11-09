/* Offline SVG enhancement. Original images remain the no-script fallback. */
(() => {
  'use strict';
  if (!window.CodexMascotArt || window.CodexMascot) return;
  const records = new Set();
  const motionQuery = matchMedia('(prefers-reduced-motion: reduce)');
  let paused = false, reduced = false, serial = 0;
  const ease = 'cubic-bezier(.22,.7,.3,1)';
  const style = document.createElement('style');
  style.textContent = '.codex-mascot{display:inline-block;vertical-align:middle;overflow:visible}.codex-mascot .m-character,.codex-mascot .m-body,.codex-mascot .m-left,.codex-mascot .m-right,.codex-mascot .m-eyes,.codex-mascot .m-badge{transform-box:fill-box;transform-origin:center}.codex-mascot .m-right{transform-origin:30% 80%}.codex-mascot .m-left{transform-origin:70% 80%}';
  document.head.append(style);

  function animate(record, selector, frames, options) {
    const node = record.svg.querySelector(selector);
    if (node) record.animations.push(node.animate(frames, {easing:ease, ...options}));
  }
  function buildMotion(record) {
    record.built = true;
    // Match the native tracks in 128-point art coordinates, including per-segment easing.
    function track(part, property, values, times, duration, loops=false, delay=0, linear=false) {
      const frames = values.map((value, i) => ({[property]:value, offset:times[i], easing:linear?'linear':ease}));
      animate(record, '.m-'+part, frames, {duration, iterations:loops?Infinity:1, delay, easing:'linear'});
    }
    const y = values => values.map(value => `translateY(${value}px)`);
    const rotate = values => values.map(value => `rotate(${value}deg)`);
    if (record.state === 'working') {
      track('character','transform',y([0,-8,1,-5,0,0]),[0,.2,.4,.6,.8,1],1800,true);
      for (const [side, sign, delay] of [['left',1,0],['right',-1,120]]) {
        track(side,'transform',[0,22,0,16,0,0].map((angle,i) =>
          `translateY(${[0,-3,0,-2,0,0][i]}px) rotate(${sign*angle}deg)`),
          [0,.16,.34,.52,.72,1],1800,true,delay);
      }
      track('eyes','transform',[1,1,.12,1,1].map(v=>`scaleY(${v})`),
        [0,.9,.93,.97,1],4600,true,0,true);
    } else if (record.state === 'idle') {
      track('character','transform',y([0,-4,0]),[0,.5,1],3200,true);
      track('body','transform',[1,1.045,1].map(v=>`scaleY(${v})`),[0,.5,1],3200,true);
      track('idle-open','opacity',[0,0,1,1,0,0],[0,.44,.47,.57,.6,1],6400,true,0,true);
      track('idle-closed','opacity',[1,1,0,0,1,1],[0,.44,.47,.57,.6,1],6400,true,0,true);
    } else if (!record.suppressEntrance) {
      if (record.state === 'attention') {
        track('character','transform',y([0,3,-10,1,-4,0]),[0,.12,.35,.58,.76,1],1100);
        track('right','transform',rotate([0,38,-18,28,-10,0]),[0,.18,.38,.58,.78,1],1100);
      } else if (record.state === 'question') {
        track('character','transform',rotate([0,-12,-12,4,0]),[0,.28,.55,.8,1],1200);
        track('right','transform',rotate([0,28,28,-6,0]),[0,.24,.5,.78,1],1200);
      } else if (record.state === 'error') {
        track('character','transform',[0,-7,7,-5,3,0].map(v=>`translateX(${v}px)`),
          [0,.16,.34,.52,.72,1],800);
      }
      track('badge','transform',[.72,1.18,.96,1].map(v=>`scale(${v})`),[0,.45,.72,1],600);
    }
  }

  function sync(record) {
    if (!record.svg.isConnected) {
      record.animations.forEach(a=>a.cancel()); observer.unobserve(record.svg); records.delete(record); return;
    }
    if (reduced || motionQuery.matches) {
      record.animations.forEach(a=>a.cancel()); record.animations=[]; record.built=false;
      record.suppressEntrance=true; record.svg.dataset.motion='reduced'; return;
    }
    if (!record.built) buildMotion(record);
    const stop = paused || document.hidden || !record.visible;
    record.svg.dataset.motion=stop?'paused':'playing';
    for (const animation of record.animations) {
      if (animation.playState === 'finished') continue;
      if (stop) animation.pause(); else if (animation.playState !== 'running') animation.play();
    }
  }
  const observer = new IntersectionObserver(entries => {
    for (const entry of entries) {
      const record = [...records].find(r=>r.svg===entry.target);
      if (record) { record.visible=entry.isIntersecting; sync(record); }
    }
  });
  function mount(element, state, mini=false) {
    const source = window.CodexMascotArt[(mini?'mini-':'')+state];
    if (!source) return element;
    const prior = [...records].find(r=>r.svg===element);
    if (prior) {prior.animations.forEach(a=>a.cancel());observer.unobserve(element);records.delete(prior);}
    const prefix='cm-'+(++serial)+'-';
    const doc = new DOMParser().parseFromString(source.replace(/id="([^"]+)"/g,(_,id)=>`id="${prefix}${id}"`)
      .replace(/url\(#([^\)]+)\)/g,(_,id)=>`url(#${prefix}${id})`),'image/svg+xml');
    const svg = document.importNode(doc.documentElement,true);
    svg.querySelectorAll('style').forEach(node=>node.remove());
    if(mini) svg.querySelectorAll('.detail').forEach(node=>node.style.display='none');
    for (const attr of element.attributes) {
      if (!['src','alt','role','aria-label','data-state','data-motion'].includes(attr.name)) svg.setAttribute(attr.name,attr.value);
    }
    svg.classList.add('codex-mascot'); svg.dataset.state=state; svg.dataset.mini=String(mini);
    if (!prior && element.getAttribute('alt') === '') {svg.setAttribute('aria-hidden','true');}
    // Each inline SVG has private paint IDs, avoiding collisions across instances.
    if (state === 'idle') {
      const eye = svg.querySelector('.m-eyes');
      const closed=document.createElementNS('http://www.w3.org/2000/svg','g'); closed.setAttribute('class','m-idle-closed');
      while(eye.firstChild) closed.append(eye.firstChild);
      eye.append(closed);
      const open=document.createElementNS('http://www.w3.org/2000/svg','g');open.setAttribute('class','m-idle-open');open.style.opacity='0';
      for(const x of [45,72]) { const rect=document.createElementNS('http://www.w3.org/2000/svg','rect');
        for(const [k,v] of Object.entries({x,y:57,width:8,height:10,rx:4,fill:'#15345F'}))rect.setAttribute(k,v);open.append(rect); }
      eye.append(open);
    }
    element.replaceWith(svg);
    const record={svg,state,mini,animations:[],built:false,visible:false,suppressEntrance:false};
    records.add(record);observer.observe(svg);sync(record);return svg;
  }
  function refresh(){document.documentElement.dataset.mascotReduced=String(reduced||motionQuery.matches);records.forEach(sync);}
  window.CodexMascot={
    setState(element,state) {return mount(element,state,element.dataset.mini==='true');},
    replay(element) {const r=[...records].find(r=>r.svg===element);if(!r)return;
      r.animations.forEach(a=>a.cancel());r.animations=[];r.built=false;r.suppressEntrance=false;sync(r);},
    setPaused(value){paused=Boolean(value);refresh();},
    setReduced(value){reduced=Boolean(value);refresh();},
    get reduced(){return reduced||motionQuery.matches;}
  };
  for(const image of document.querySelectorAll('img[src*="toy-"]')) {
    const match=image.getAttribute('src').match(/toy-(mini-)?(idle|working|attention|question|error)\.svg$/);
    if(match)mount(image,match[2],Boolean(match[1]));
  }
  document.addEventListener('visibilitychange',refresh);
  motionQuery.addEventListener('change',()=>{refresh();window.dispatchEvent(new Event('mascot-motion-change'));});
  refresh();
  window.dispatchEvent(new Event('mascot-ready'));
})();
