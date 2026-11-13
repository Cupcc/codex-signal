(() => {
  const api=window.CodexMascot;
  if(!api)return;
  document.querySelector(".motion-controls").hidden=false;
  const labels={idle:'休息',working:'工作',attention:'等待审批',question:'有个问题',error:'运行中断',ready:'待查看'};
  const tasks={idle:'暂无待查看结果',working:'检查数据库迁移',attention:'确认数据库迁移',question:'选择迁移策略',error:'连接中断，请检查',ready:'结果已就绪，等待查看'};
  const choices=[...document.querySelectorAll('[data-state-choice]')];
  const main=()=>document.querySelectorAll('.hero-main .codex-mascot,.stage .codex-mascot');
  const pause=document.querySelector('#motion-pause');
  const reduce=document.querySelector('#motion-reduce');
  const note=document.querySelector('#motion-note');
  let paused=false;
  function refresh(){
    pause.disabled=api.reduced;
    document.querySelector('#motion-replay').disabled=api.reduced;
    pause.textContent=paused?'继续播放':'暂停动效';pause.setAttribute('aria-pressed',String(paused));
    note.textContent=api.reduced?'减少动态效果已开启 · 当前显示静止姿态':paused?'已暂停 · 再次播放会从当前位置继续':'工作起伏 · 休息呼吸 · 等待只提醒一次';
  }
  choices.forEach(button=>button.addEventListener('click',()=>{
    const state=button.dataset.stateChoice;
    if(button.getAttribute('aria-pressed')==='true')return;
    main().forEach(svg=>api.setState(svg,state));
    choices.forEach(b=>b.setAttribute('aria-pressed',String(b===button)));
    document.querySelectorAll('.session p').forEach(p=>p.textContent=tasks[state]);
    document.querySelectorAll('.session b').forEach(b=>{b.textContent=labels[state];
      b.style.color={idle:'#adc0d5',working:'#9dceff',attention:'#ffcd92',question:'#c3e2ff',error:'#ffada6',ready:'#c5b8ff'}[state];});
    document.querySelector('#motion-state').textContent='当前：'+labels[state];
  }));
  document.querySelector('#motion-replay').addEventListener('click',()=>{
    if(paused){paused=false;api.setPaused(false);}
    main().forEach(svg=>api.replay(svg));refresh();
  });
  pause.addEventListener('click',()=>{paused=!paused;api.setPaused(paused);refresh();});
  reduce.addEventListener('change',()=>{api.setReduced(reduce.checked);refresh();});
  window.addEventListener('mascot-motion-change',refresh);refresh();
})();
