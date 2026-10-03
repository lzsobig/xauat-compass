export function createAccountClient(hooks){
  const {state,html,icon,button,openSheet,closeSheet,toast,renderShell,renderPage,readState,persistState,mergeTasks,downloadFile,offline}=hooks;
  const guestKey='xauat_compass_v2';
  let epoch=0,syncTimer,syncPromise,syncController,conflict=null;
  let adminData={loading:false,overview:null,users:[],trials:[],userCursor:null,cardCursor:null,tab:'users',error:''};
  const ownButton=(label,action,style='',attrs='')=>`<button class="btn ${style}" data-account-action="${action}" ${attrs}>${label}</button>`;
  const snapshot=()=>({version:2,tasks:state.tasks,profile:state.profile,favorites:state.favorites});
  const cache=()=>persistState(state,localStorage,state.storageKey||guestKey);
  async function api(path,body,signal){
    const result=await fetch(path,{...(body?{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)}:{}),...(signal?{signal}:{})});
    let data;try{data=await result.json();}catch{throw new Error('服务未返回有效响应，请稍后重试');}
    if(!result.ok)throw Object.assign(new Error(data.error||'操作未完成'),{status:result.status});return data;
  }
  function applyData(data){Object.assign(state,{tasks:data.tasks,profile:data.profile,favorites:data.favorites,plan:null,storageError:''});}
  function statusLabel(){return !state.account?'计划保存在本机':state.syncState==='conflict'?'云端有更新':state.syncState==='error'?'改动待同步':state.syncDirty||state.syncState==='saving'?'正在同步':'计划已同步云端';}
  function updateBadge(){const badge=document.querySelector('[data-sync-badge]');if(badge){badge.innerHTML=`<i></i>${statusLabel()}`;badge.classList.toggle('sync-warning',['conflict','error'].includes(state.syncState));}}
  async function push(){
    if(!state.account||state.account.mustChangePassword||!state.syncDirty)return;
    if(syncPromise)return syncPromise;
    const version=epoch,owner=state.account.id,serialized=JSON.stringify(snapshot());syncController=new AbortController();state.syncState='saving';updateBadge();
    syncPromise=(async()=>{
      try{
        const result=await api('/api/user/workspace',{revision:state.syncRevision||0,payload:JSON.parse(serialized)},syncController.signal);
        if(epoch!==version||state.account?.id!==owner)return;
        state.syncRevision=result.revision;state.syncDirty=JSON.stringify(snapshot())!==serialized;state.syncState=state.syncDirty?'pending':'synced';cache();
      }catch(error){
        if(epoch!==version)return;
        state.syncState=error.status===409?'conflict':'error';
        if(error.status===409){const latest=await api('/api/user/workspace').catch(()=>null);if(epoch!==version||state.account?.id!==owner)return;conflict=latest;toast('云端计划有更新，本机改动已保留。点击右上角处理。');}
        else if(error.name!=='AbortError')toast('暂未同步到云端，改动已保存在此设备。');
        cache();
      }finally{if(epoch===version){syncPromise=null;updateBadge();if(state.syncDirty&&state.syncState==='pending')queueSync();}}
    })();
    return syncPromise;
  }
  function queueSync(){
    if(!state.account||state.account.mustChangePassword)return;
    state.syncDirty=true;state.syncState=conflict?'conflict':'pending';cache();updateBadge();clearTimeout(syncTimer);
    if(!conflict)syncTimer=setTimeout(()=>push(),650);
  }
  async function activate(user,{promptImport=false}={}){
    hooks.cancelGeneration?.();epoch++;const activationEpoch=epoch;clearTimeout(syncTimer);syncController?.abort();syncPromise=null;conflict=null;adminData={loading:false,overview:null,users:[],trials:[],userCursor:null,cardCursor:null,tab:'users',error:''};
    state.account=user;state.storageKey=`${guestKey}_user_${user.id}`;state.plan=null;
    const cached=readState(localStorage,state.storageKey);if(cached.storageError){const original=localStorage.getItem(state.storageKey);if(original)localStorage.setItem(state.storageKey+'_recovery_'+Date.now(),original);}applyData(cached);if(cached.storageError)state.storageError=cached.storageError;state.syncRevision=cached.syncRevision;state.syncDirty=cached.syncDirty;state.syncState='loading';
    if(user.mustChangePassword){renderShell();openPassword(true);return;}
    try{
      const cloud=await api('/api/user/workspace');if(epoch!==activationEpoch||state.account?.id!==user.id)return;
      if(cached.syncDirty){state.syncRevision=cached.syncRevision;if(cached.syncRevision!==cloud.revision){conflict=cloud;state.syncState='conflict';}else{state.syncState='pending';queueSync();}}
      else{applyData(cloud.payload);state.syncRevision=cloud.revision;state.syncDirty=false;state.syncState='synced';cache();}
    }catch{if(epoch!==activationEpoch||state.account?.id!==user.id)return;state.syncState='error';toast('暂时无法读取云端计划，已载入此账号的本机缓存。');}
    await hooks.loadCapabilities();if(epoch!==activationEpoch||state.account?.id!==user.id)return;renderShell();
    const guest=readState();if(promptImport&&!guest.storageError&&(guest.tasks.length||guest.favorites.length)){
      openSheet('是否导入此设备的计划？',`<p class="note">此设备有 ${guest.tasks.length} 项未登录时保存的任务、${guest.favorites.length} 项收藏。确认这些记录属于你，再导入当前账号；不同任务会合并，云端已有任务不会被覆盖。</p><div class="button-group" style="margin-top:22px">${ownButton('导入本机记录','import-guest','primary')}${ownButton('使用当前云端计划','skip-import')}</div>`);
    }
  }
  async function initialize(){
    if(offline())return;
    try{const result=await api('/api/auth/me');state.accountsEnabled=result.accountsEnabled;
      if(result.user)await activate(result.user);else{state.account=null;renderShell();}
    }catch{/* Static or offline hosting still supports the guest's local tools. */}
  }
  function openLogin(mode='login'){
    if(offline()){toast('离线版只保存本机数据，账号服务需联网使用。');return;}
    openSheet(mode==='register'?'创建你的竞赛罗盘账号':'欢迎回来',`<div class="account-brand">${icon('compass')}<span>一份计划，陪你继续向前。</span></div><form id="account-auth-form" data-mode="${mode}"><div class="field"><label for="account-username">用户名</label><input id="account-username" name="username" autocomplete="username" required minlength="3" maxlength="32" placeholder="3—32 位字母、数字、下划线或短横线"></div>${mode==='register'?'<div class="field"><label for="account-display-name">昵称 <small>可选</small></label><input id="account-display-name" name="displayName" autocomplete="nickname" maxlength="32" placeholder="希望我们怎么称呼你"></div>':''}<div class="field"><label for="account-password">密码</label><input id="account-password" type="password" name="password" autocomplete="${mode==='register'?'new-password':'current-password'}" required minlength="10" maxlength="128" placeholder="至少 10 个字符，建议使用较长的短语"></div><button class="btn primary full" type="submit">${mode==='register'?'创建账号':'登录并同步计划'} ${icon('arrow')}</button><div class="form-error" role="alert"></div></form><p class="account-switch">${mode==='register'?'已经有账号？':'第一次来到这里？'} ${ownButton(mode==='register'?'去登录':'创建账号',mode==='register'?'login':'register','ghost small')}</p><div class="note">${mode==='register'?'注册后可同步计划和收藏；智能生成需绑定卡密或获得管理员赠送额度。':'忘记密码时可联系维护者重置临时密码；当前不提供未经验证的邮箱找回。'}</div>`);
  }
  function openPassword(forced=false){
    openSheet(forced?'先设置你自己的密码':'修改账号密码',`<form id="account-password-form"><p class="note">${forced?'管理员已重置你的密码。请用临时密码设置新密码，再继续使用。':'修改密码后，其他设备上的登录会话会失效。'}</p><div class="field" style="margin-top:20px"><label for="current-password">${forced?'临时密码':'当前密码'}</label><input id="current-password" type="password" name="currentPassword" autocomplete="current-password" required minlength="10" maxlength="128"></div><div class="field"><label for="new-password">新密码</label><input id="new-password" type="password" name="newPassword" autocomplete="new-password" required minlength="10" maxlength="128"></div><button class="btn primary full" type="submit">保存新密码</button><div class="form-error" role="alert"></div></form>`);
  }
  async function openPanel(){
    if(!state.account){openLogin();return;}
    if(conflict){openConflict();return;}
    const panelOwner=state.account.id,panelEpoch=epoch;const cards=state.account.mustChangePassword?[]:(await api('/api/user/trials')).trials;if(epoch!==panelEpoch||state.account?.id!==panelOwner)return;
    openSheet('我的账号',`<div class="account-summary"><div class="account-monogram">${html(state.account.displayName.slice(0,1))}</div><div><h3>${html(state.account.displayName)}</h3><p>@${html(state.account.username)} · ${state.account.role==='admin'?'管理员':'用户'}</p></div></div><div class="account-sync-note"><span>${icon('shield')} ${html(statusLabel())}</span>${ownButton('同步现在','sync-now','ghost small')}</div><h3 style="margin-top:22px">我的智能生成额度</h3><p class="muted" style="font-size:12px;margin:8px 0 14px">每张卡密分别按北京时间更新，已绑定卡密不会重复增加额度。</p>${cards.length?cards.map(card=>`<div class="account-card-row"><div><strong>${card.kind==='grant'?'管理员赠送':'卡密 #'+card.id}</strong><small>${card.active?'可用':'已停用'} · 每天 ${card.daily_limit} 次</small></div><span>剩余 <b>${card.remaining}</b> 次</span></div>`).join(''):'<div class="note">尚未绑定卡密。查询、基础推荐和云端计划仍可使用。</div>'}<div class="button-group" style="margin-top:22px">${button('绑定新卡密','trial','primary')}${ownButton('修改密码','password')}${ownButton('导入本机记录','import-guest')}</div>${state.account.role==='admin'?`<hr>${ownButton('进入管理后台 '+icon('arrow'),'open-admin','blue full')}`:''}<hr><div class="row between"><small class="muted">退出后，此账号的计划不会显示给访客。</small>${ownButton('退出登录','logout','ghost')}</div>`);
  }
  function openConflict(){openSheet('选择要保留的计划版本',`<p class="note warning">另一设备已经更新了云端计划。本机改动仍在当前账号的缓存中，暂未覆盖云端。选择版本前，会自动导出被替换版本的备份。</p><div class="button-group" style="margin-top:22px">${ownButton('保留本机版本','conflict-local','primary')}${ownButton('使用云端版本','conflict-cloud')}${ownButton('退出并保留本机改动','logout','ghost')}</div>`);}
  async function logout(){
    hooks.cancelGeneration?.();clearTimeout(syncTimer);if(state.syncDirty&&!conflict)await push();
    epoch++;syncController?.abort();syncPromise=null;await api('/api/auth/logout',{});
    if(!state.syncDirty&&state.storageKey)localStorage.removeItem(state.storageKey);state.account=null;adminData={loading:false,overview:null,users:[],trials:[],userCursor:null,cardCursor:null,tab:'users',error:''};state.storageKey=guestKey;state.syncDirty=false;state.syncState='guest';conflict=null;applyData(readState());state.syncRevision=0;
    await hooks.loadCapabilities();closeSheet();renderShell();toast('已退出登录，此账号计划已保留。');
  }
  async function importGuest(){const guest=readState();if(guest.storageError)throw new Error('本机访客数据读取失败，请先从备份恢复');const count=state.tasks.length;state.tasks=mergeTasks(state.tasks,guest.tasks);state.favorites=[...new Set([...state.favorites,...guest.favorites])];if(state.syncRevision===0)state.profile=guest.profile;queueSync();await push();if(!state.syncDirty){localStorage.setItem(state.storageKey+'_import_backup',JSON.stringify(guest));localStorage.removeItem(guestKey);}closeSheet();renderShell();toast(state.syncDirty?'已合并到此账号的本机缓存，联网后继续同步。':`已合并 ${state.tasks.length-count} 项新增任务，已有云端任务保留。`);}
  async function loadAdmin(append=false){
    if(state.account?.role!=='admin')return;
    const adminEpoch=epoch,adminOwner=state.account.id;adminData.loading=true;adminData.error='';if(state.route==='admin')renderPage();
    try{const [overview,users,trials]=await Promise.all([api('/api/admin/overview'),api('/api/admin/users?cursor='+(append&&adminData.tab==='users'?adminData.userCursor||0:0)),api('/api/admin/trials?cursor='+(append&&adminData.tab==='cards'?adminData.cardCursor||0:0))]);
      if(epoch!==adminEpoch||state.account?.id!==adminOwner)return;Object.assign(adminData,{overview,users:append&&adminData.tab==='users'?[...adminData.users,...users.users]:users.users,trials:append&&adminData.tab==='cards'?[...adminData.trials,...trials.trials]:trials.trials,userCursor:users.nextCursor,cardCursor:trials.nextCursor});
    }catch(error){if(epoch===adminEpoch)adminData.error=error.message;}finally{if(epoch===adminEpoch){adminData.loading=false;if(state.route==='admin')renderPage();}}
  }
  function renderAdmin(){
    if(state.account?.role!=='admin')return `<section class="empty panel"><h3>需要管理员账号</h3><p>请登录有管理权限的账号，查看用户与卡密。</p>${ownButton('登录账号','login','primary')}</section>`;
    const data=adminData,stats=data.overview;
    return `<div class="page-heading"><div><div class="eyebrow">ACCOUNT & ACCESS</div><h1>账号与权益管理</h1><p>管理真实用户、卡密与每日额度，修改会立即生效。</p></div>${ownButton(icon('refresh')+' 刷新','admin-refresh')}</div>${data.error?`<div class="error-banner" role="alert">${html(data.error)}</div>`:''}<div class="admin-kpis">${[['注册用户',stats?.users.total??'—'],['可用卡密',stats?.cards.active??'—'],['今日成功生成',stats?.usage.successes??'—'],['今日模型用量',stats?.usage.tokens??'—']].map(([label,value])=>`<div><small>${label}</small><strong>${value||0}</strong></div>`).join('')}</div><div class="admin-toolbar"><div class="segmented"><button class="${data.tab==='users'?'active':''}" data-account-action="admin-tab" data-tab="users">用户管理</button><button class="${data.tab==='cards'?'active':''}" data-account-action="admin-tab" data-tab="cards">卡密管理</button></div>${ownButton(icon('plus')+' 生成卡密','admin-create-cards','primary')}</div>${data.loading&&!stats?'<div class="note" role="status">正在读取管理数据…</div>':`<div class="table-wrap admin-table-wrap"><table class="data-table">${data.tab==='users'?`<thead><tr><th>用户</th><th>角色 / 状态</th><th>每日赠送</th><th>最近登录</th><th>操作</th></tr></thead><tbody>${data.users.map(u=>`<tr><td><strong>${html(u.displayName)}</strong><br><small class="muted">@${html(u.username)} · #${u.id}</small></td><td>${u.role==='admin'?'管理员':'用户'} · ${u.status==='active'?'正常':'停用'}</td><td>${u.dailyGrant} 次</td><td>${u.lastLoginAt?html(new Date(u.lastLoginAt).toLocaleDateString('zh-CN')):'尚未登录'}</td><td>${ownButton('管理','admin-edit-user','small',`data-user-id="${u.id}"`)}</td></tr>`).join('')}</tbody>`:`<thead><tr><th>卡密</th><th>归属账号</th><th>状态</th><th>每日 / 今日使用</th><th>操作</th></tr></thead><tbody>${data.trials.map(t=>`<tr><td>#${t.id}<br><small class="muted">仅保存卡密哈希</small></td><td>${html(t.owner||'未绑定')}</td><td>${t.active?'可用':'停用'}</td><td>${t.daily_limit} / ${t.used}</td><td>${ownButton('管理','admin-edit-card','small',`data-card-id="${t.id}"`)}</td></tr>`).join('')}</tbody>`}</table></div>${(data.tab==='users'?data.userCursor:data.cardCursor)?`<div class="load-more">${ownButton('读取更多','admin-more')}</div>`:''}`}<p class="note" style="margin-top:22px">管理后台不展示用户密码或私人计划。新卡密和重置密码只在操作完成时提供一次，请及时保存并交给预期用户。</p>`;
  }
  function afterRender(){updateBadge();if(state.route==='admin'&&state.account?.role==='admin'&&!adminData.overview&&!adminData.loading)loadAdmin();}
  async function action(el){const act=el.dataset.accountAction;
    if(act==='login'||act==='register'){openLogin(act);return;}
    if(act==='panel'){await openPanel();return;}
    if(act==='password'){openPassword(state.account?.mustChangePassword);return;}
    if(act==='logout'){await logout();return;}
    if(act==='skip-import'){closeSheet();return;}
    if(act==='import-guest'){if(!state.account){openLogin();return;}await importGuest();return;}
    if(act==='sync-now'){await push();if(conflict)openConflict();else toast(state.syncDirty?'改动仍在本机，请稍后再试':'计划已同步');return;}
    if(act==='conflict-local'||act==='conflict-cloud'){
      if(!conflict)throw new Error('没有待处理的同步冲突');
      downloadFile('竞赛罗盘-同步冲突备份.json',JSON.stringify(act==='conflict-local'?conflict.payload:snapshot(),null,2));
      if(act==='conflict-cloud'){applyData(conflict.payload);state.syncDirty=false;}else state.syncDirty=true;
      state.syncRevision=conflict.revision;conflict=null;state.syncState='synced';cache();if(state.syncDirty)await push();closeSheet();renderShell();return;
    }
    if(act==='open-admin'){closeSheet();location.hash='admin';return;}
    if(act==='admin-tab'){adminData.tab=el.dataset.tab;renderPage();return;}
    if(act==='admin-refresh'||act==='admin-more'){await loadAdmin(act==='admin-more');return;}
    if(act==='admin-create-cards'){openSheet('生成一批卡密',`<form id="admin-cards-form"><div class="field"><label for="card-count">数量</label><input id="card-count" name="count" type="number" min="1" max="50" value="20" required></div><div class="field"><label for="card-daily">每张每天有效生成次数</label><input id="card-daily" name="dailyLimit" type="number" min="1" max="100" value="3" required></div><button class="btn primary full" type="submit">生成并下载卡密</button><div class="form-error" role="alert"></div></form>`);return;}
    if(act==='admin-edit-user'){
      const u=adminData.users.find(u=>u.id===Number(el.dataset.userId));if(!u)throw new Error('请刷新用户列表');
      openSheet('管理 @'+html(u.username),`<form id="admin-user-form" data-user-id="${u.id}"><div class="field"><label for="admin-user-status">账号状态</label><select id="admin-user-status" name="status"><option value="active" ${u.status==='active'?'selected':''}>正常</option><option value="disabled" ${u.status==='disabled'?'selected':''}>停用</option></select></div><div class="field"><label for="admin-user-role">角色</label><select id="admin-user-role" name="role"><option value="user" ${u.role==='user'?'selected':''}>普通用户</option><option value="admin" ${u.role==='admin'?'selected':''}>管理员（可管理所有用户与卡密）</option></select></div><div class="field"><label for="admin-user-grant">每日赠送额度 <small>额外于已绑定卡密</small></label><input id="admin-user-grant" name="dailyGrant" type="number" min="0" max="100" value="${u.dailyGrant}" required></div><button class="btn primary full" type="submit">保存账号与权益</button><div class="form-error" role="alert"></div></form>${u.id!==state.account.id?`<hr>${ownButton('重置为临时密码','admin-reset-password','ghost full',`data-user-id="${u.id}"`)}`:''}`);return;
    }
    if(act==='admin-reset-password'){
      const data=await api('/api/admin/users/reset-password',{userId:Number(el.dataset.userId)});downloadFile('竞赛罗盘-临时密码.txt',`用户名：${data.username}\n临时密码：${data.temporaryPassword}\n请用户登录后立即修改密码。\n`,'text/plain');closeSheet();toast('已重置并导出临时密码，其他设备的会话已失效。');await loadAdmin();return;
    }
    if(act==='admin-edit-card'){
      const card=adminData.trials.find(t=>t.id===Number(el.dataset.cardId));if(!card)throw new Error('请刷新卡密列表');
      openSheet('管理卡密 #'+card.id,`<form id="admin-card-form" data-card-id="${card.id}"><p class="note">归属：${html(card.owner||'未绑定')}。停用后立即停止提供额度，重新启用不清除今日使用记录。</p><div class="field" style="margin-top:20px"><label for="admin-card-active">状态</label><select id="admin-card-active" name="active"><option value="1" ${card.active?'selected':''}>可用</option><option value="0" ${!card.active?'selected':''}>停用</option></select></div><div class="field"><label for="admin-card-limit">每日有效生成次数</label><input id="admin-card-limit" name="dailyLimit" type="number" min="1" max="100" value="${card.daily_limit}" required></div><button class="btn primary full" type="submit">保存卡密设置</button><div class="form-error" role="alert"></div></form>`);return;
    }
  }
  async function submit(form){
    const data=Object.fromEntries(new FormData(form)),error=form.querySelector('.form-error'),submit=form.querySelector('[type=submit]');error.textContent='';const originalButton=submit.innerHTML;submit.disabled=true;submit.textContent='正在处理…';
    try{
      if(form.id==='account-auth-form'){const result=await api('/api/auth/'+form.dataset.mode,data);closeSheet(true);await activate(result.user,{promptImport:true});toast(form.dataset.mode==='register'?'账号已创建':'已登录账号');}
      else if(form.id==='account-password-form'){const result=await api('/api/auth/password',data);closeSheet(true);await activate(result.user);toast('密码已修改，其他设备需要重新登录。');}
      else if(form.id==='admin-cards-form'){const result=await api('/api/admin/trials/create',{count:Number(data.count),dailyLimit:Number(data.dailyLimit)});downloadFile('竞赛罗盘-新卡密.txt',`每张每天 ${result.dailyLimit} 次\n\n`+result.codes.map((code,i)=>`${i+1}. ${code}`).join('\n'),'text/plain');closeSheet();toast(`已生成并导出 ${result.codes.length} 张卡密`);await loadAdmin();}
      else if(form.id==='admin-user-form'){await api('/api/admin/users/update',{userId:Number(form.dataset.userId),status:data.status,role:data.role,dailyGrant:Number(data.dailyGrant)});closeSheet();toast('账号与权益已更新');await loadAdmin();}
      else if(form.id==='admin-card-form'){await api('/api/admin/trials/update',{trialId:Number(form.dataset.cardId),active:Number(data.active),dailyLimit:Number(data.dailyLimit)});closeSheet();toast('卡密设置已更新');await loadAdmin();}
    }catch(err){if(form.isConnected)error.textContent=err.message;else toast(err.message);}finally{submit.disabled=false;submit.innerHTML=originalButton;}
  }
  window.addEventListener('online',()=>{if(state.account&&state.syncDirty&&!conflict)push();});
  document.addEventListener('visibilitychange',()=>{if(document.visibilityState==='hidden'&&state.account&&state.syncDirty&&!conflict)push();});
  return {initialize,queueSync,push,openLogin,openPanel,openPassword,renderAdmin,afterRender,action,submit,statusLabel};
}
