/* Device navigation and lifecycle, shared by the native shell and installed remote app. */
'use strict';
window.SapiensConnections=(()=>{
  const $=id=>document.getElementById(id),remote=document.body.hasAttribute('data-remote');
  const read=(key,fallback)=>{try{return JSON.parse(localStorage.getItem(key))??fallback;}catch{return fallback;}};
  const write=(key,value)=>{
    try{localStorage.setItem(key,JSON.stringify(value));}
    catch{
      // Drafts and navigation take priority over disposable workspace snapshots.
      if(key.startsWith('s4.snapshot.'))return;
      try{Object.keys(localStorage).filter(k=>k.startsWith('s4.snapshot.')).forEach(k=>localStorage.removeItem(k));localStorage.setItem(key,JSON.stringify(value));}
      catch{const feedback=$('corpora-startup-feedback');if(feedback)feedback.textContent='Device storage is unavailable. Keep this window open to retain your draft.';}
    }
  };
  const escape=value=>String(value??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  let records=[],sessions=new Map(),clients=new Map(),active=null,connected=false,busy=false,localAvailable=false,initialResolve,started=false,generation=0,lastSnapshot=null,listener=null,formCleanup=()=>{},installRequired=false,suppressDialogPop=false;
  const initial=new Promise(resolve=>initialResolve=resolve);
  const menu=$('corpora-menu'),statusMenu=$('corpora-status-menu'),dialog=$('corpora-dialog');
  const selectedKey=()=>active?.key;
  const notify=()=>window.dispatchEvent(new Event('sapiens-connection-change'));
  async function json(path,method='GET',data){const response=await fetch(path,{method,headers:{'Content-Type':'application/json','X-Sapiens-Local':'1'},...(data===undefined?{}:{body:JSON.stringify(data)}),signal:AbortSignal.timeout(20000)});const result=await response.json();if(!response.ok)throw new Error(result.error||'Request failed');return result;}
  const client=record=>{if(!clients.has(record.key))clients.set(record.key,new RemoteTransport(sessions.get(record.key)));return clients.get(record.key);};
  async function request(record,path,method='GET',data){
    if(!record)throw new Error('Connect a corpora first.');
    if(remote){const response=await client(record).fetch(path,{method,...(data===undefined?{}:{body:JSON.stringify(data)})});const value=await response.json();if(!response.ok)throw new Error(value.error||'Request failed');return value;}
    return json('/api/host/corpora/'+record.id+path,method,data);
  }
  function metadata(record,data){Object.assign(record,data);if(record===active)renderStatus();renderRows();}
  function renderStatus(){
    $('corpora-location').textContent=active?.location||'Remote';
    $('connection-label').textContent=busy?'Connecting…':!active?'Not connected':!connected?'Connecting…':active.stopping?'Pausing…':({active:'Active',paused:'Paused',archived:'Archived'}[active.status]||'Active');
    $('connection-status').dataset.online=String(connected&&!busy&&active?.status==='active');
    $('connection-status').disabled=!active||!connected||busy;
    $('connection-status').setAttribute('aria-expanded',String(!statusMenu.hidden));
    statusMenu.innerHTML=active?.status==='archived'?'<span>Archived</span>':`<button type="button" data-lifecycle="pause" ${active?.status==='paused'?'disabled':''}>${active?.status==='paused'?'Paused ✓':'Pause'}</button><button type="button" data-lifecycle="activate" ${active?.status==='active'?'disabled':''}>${active?.status==='active'?'Active ✓':'Activate'}</button>`;
    notify();
  }
  function renderRows(){
    const rowsHTML=records.filter(r=>!r.archived&&r.status!=='archived'||$('corpora-archived').checked).map(r=>`<div class="corpora-record" data-selected="${r.key===selectedKey()}"><span class="corpora-location-cell">${escape(r.location)}</span><span class="corpora-name-cell"><button class="corpora-name" data-enter="${escape(r.key)}" ${r.status==='archived'||busy?'disabled':''} aria-pressed="${r.key===selectedKey()}">${escape(r.name)}</button><button class="corpora-edit" data-edit="${escape(r.key)}" ${busy?'disabled':''}>Edit</button></span><span class="corpora-state"><i class="corpora-dot" data-active="${r.status==='active'}"></i>${escape({active:'Active',paused:'Paused',archived:'Archived'}[r.status]||'Active')}</span><span class="corpora-device">${escape(r.device||'Host computer')}</span></div>`).join('');
    if($('corpora-rows').innerHTML!==rowsHTML)$('corpora-rows').innerHTML=rowsHTML;
    $('create-local-corpora').hidden=!localAvailable;
    $('corpora-picker').title=active?.name||'Corpora';
    $('corpora-picker').setAttribute('aria-expanded',String(!menu.hidden));
    $('connection-status').setAttribute('aria-expanded',String(!statusMenu.hidden));
  }
  function error(message){$('corpora-notice-text').textContent=message;$('corpora-notice').showModal();}
  function show(title,html){formCleanup();formCleanup=()=>{};$('corpora-dialog-title').textContent=title;$('corpora-dialog-body').innerHTML=html;if(!dialog.open){dialog.showModal();history.pushState({sapiensDialog:true},'');}}
  function closeForm(){formCleanup();formCleanup=()=>{};dialog.close();if(history.state?.sapiensDialog){suppressDialogPop=true;history.back();}}
  $('corpora-dialog-close').onclick=closeForm;dialog.addEventListener('cancel',event=>{event.preventDefault();closeForm();});
  window.addEventListener('popstate',()=>{if(suppressDialogPop){suppressDialogPop=false;return;}if(dialog.open&&!history.state?.sapiensDialog){formCleanup();formCleanup=()=>{};dialog.close();}menu.hidden=true;statusMenu.hidden=true;renderRows();});
  $('corpora-notice-close').onclick=()=>$('corpora-notice').close();
  $('corpora-picker').onclick=()=>{menu.hidden=!menu.hidden;statusMenu.hidden=true;renderRows();};
  $('connection-status').onclick=()=>{statusMenu.hidden=!statusMenu.hidden;menu.hidden=true;renderRows();};
  $('corpora-menu-close').onclick=()=>{menu.hidden=true;renderRows();};
  document.addEventListener('click',event=>{const path=event.composedPath();if(!path.some(node=>node.id&&['corpora-picker','corpora-menu','connection-status','corpora-status-menu','corpora-dialog','corpora-notice'].includes(node.id))){menu.hidden=true;statusMenu.hidden=true;renderRows();}});
  document.addEventListener('keydown',event=>{if(event.key==='Escape'){menu.hidden=true;statusMenu.hidden=true;renderRows();}});
  $('corpora-archived').onchange=renderRows;
  function cache(snapshot){
    if(!active||snapshot.corpora.id!==active.id)return;
    try{
    const recent={...snapshot,turns:snapshot.turns.slice(-100),events:[],pulses:[]};
    if(JSON.stringify(recent).length>750000){recent.turns=[];recent.groups=(recent.groups||[]).map(group=>({...group,messages:group.messages.slice(-10)}));}
    const key='s4.snapshot.'+active.key;
    Object.keys(localStorage).filter(k=>k.startsWith('s4.snapshot.')&&k!==key).slice(0,-2).forEach(k=>localStorage.removeItem(k));
    write(key,recent);
    }catch{} // A cache failure must never prevent opening the live workspace.
  }
  function decorate(snapshot,key=selectedKey()){
    const local=read('s4.workspace.'+key,null);
    return local?{...snapshot,preferences:{...snapshot.preferences,...local,workspaces:snapshot.preferences?.workspaces||local.workspaces||{}}}:snapshot;
  }
  function deliver(snapshot){lastSnapshot=decorate(snapshot);if(!started){started=true;initialResolve(lastSnapshot);}else listener?.(lastSnapshot);}
  async function lifecycle(record,action){
    let info=await request(record,'/api/corpora');metadata(record,info);
    const data={action,revision:info.revision,operation:crypto.randomUUID()};
    // Persist the intent so a dropped response is reconciled before another transition.
    write('s4.lifecycle.pending',{key:record.key,expiresAt:Date.now()+30000,...data});
    try{info=await request(record,'/api/corpora/lifecycle','PUT',data);}
    catch(error){connected=false;renderStatus();throw error;}
    metadata(record,info);
    if(info.stopping){
      for(let attempt=0;attempt<10&&info.stopping;attempt++){
        await new Promise(resolve=>setTimeout(resolve,500));info=await request(record,'/api/corpora');metadata(record,info);
      }
      if(info.stopping)throw new Error('Work is still stopping. Try again shortly.');
    }
    write('s4.lifecycle.pending',null);return info;
  }
  async function reconcile(){
    const pending=read('s4.lifecycle.pending',null);
    if(pending){
      const record=records.find(r=>r.key===pending.key);if(!record)throw new Error('The previous switch needs its original connection.');
      const outcome=await request(record,'/api/corpora/operations/'+encodeURIComponent(pending.operation));
      const info=outcome.corpora;metadata(record,info);
      if(info.stopping)throw new Error('Work is still stopping. Try again shortly.');
      if(!outcome.applied&&Date.now()<(pending.expiresAt||0))throw new Error('The previous switch is still being confirmed. Try again shortly.');
      write('s4.lifecycle.pending',null);
      if(outcome.applied&&pending.action==='activate'&&record.key!==active?.key&&info.status==='active')await lifecycle(record,'pause');
    }
    const switching=read('s4.switch.pending',null);
    if(switching?.phase==='activating'&&switching.to!==active?.key){
      const target=records.find(r=>r.key===switching.to);
      if(!target)throw new Error('The previous switch needs its original connection.');
      metadata(target,await request(target,'/api/corpora'));
      if(target.status==='active')await lifecycle(target,'pause');
    }
    write('s4.switch.pending',null);
  }
  async function enter(record){
    if(busy||record.status==='archived')return;
    if(record.key===selectedKey()){menu.hidden=false;return;}
    busy=true;generation++;renderStatus();renderRows();
    try{
      await reconcile();
      // Both hosts are checked before changing either one's execution state.
      metadata(record,await request(record,'/api/corpora'));
      if(active)metadata(active,await request(active,'/api/corpora'));
      write('s4.switch.pending',{from:active?.key,to:record.key,phase:'pausing'});
      if(active?.status==='archived'&&active.stopping)throw new Error('Work is still stopping. Try again shortly.');
      if(active&&active.status!=='archived')await lifecycle(active,'pause');
      write('s4.switch.pending',{from:active?.key,to:record.key,phase:'activating'});
      await lifecycle(record,'activate');
      const snapshot=await request(record,'/api/state');
      window.sapiensWorkspace?.save();active=record;write('s4.active',record.key);connected=true;
      write('s4.switch.pending',null);cache(snapshot);deliver(snapshot);menu.hidden=false;$('corpora-empty').hidden=true;
      write('s4.records',records);
    }catch(e){error(e.message);}
    finally{busy=false;renderRows();renderStatus();}
  }
  $('corpora-rows').onclick=event=>{const button=event.target.closest('button');if(button?.dataset.enter)enter(records.find(r=>r.key===button.dataset.enter));if(button?.dataset.edit)edit(records.find(r=>r.key===button.dataset.edit));};
  statusMenu.onclick=async event=>{const action=event.target.closest('[data-lifecycle]')?.dataset.lifecycle;if(!action||busy)return;busy=true;renderStatus();try{await reconcile();await lifecycle(active,action);}catch(e){error(e.message);}finally{busy=false;statusMenu.hidden=true;renderStatus();}};
  function edit(record){
    show('Message to ChiefSapi',`<form id="chief-settings-form"><textarea name="message" aria-label="Message to ChiefSapi" rows="8" required></textarea><p class="corpora-feedback" role="status"></p><button type="submit">Send to ChiefSapi ↑</button></form>`);
    const form=$('chief-settings-form');form.elements.message.value=(record.settings_template||lastSnapshot?.corpora?.settings_template||'').replace(/\{(name|device|scope)\}/g,(_,field)=>record[field]||'');
    form.onsubmit=async event=>{event.preventDefault();const button=form.querySelector('button');button.disabled=true;try{const info=await request(record,'/api/corpora');if(info.status!=='active')throw new Error('Activate this corpora before sending. Your draft is kept here.');await request(record,'/api/agents/'+info.chief_id+'/messages','POST',{text:form.elements.message.value});closeForm();}catch(e){form.querySelector('[role=status]').textContent=e.message;}finally{button.disabled=false;}};
    form.elements.message.focus();
  }
  $('create-local-corpora').onclick=()=>{
    show('Create local corpora','<form id="new-corpora-form"><label>Corpora name<input name="name" required maxlength="200" autofocus></label><label>Scope of work<textarea name="scope" rows="4" maxlength="16000"></textarea></label><p role="status"></p><button type="submit">Create</button></form>');
    const form=$('new-corpora-form');form.onsubmit=async event=>{event.preventDefault();const button=form.querySelector('button');button.disabled=true;try{const record=await json('/api/host/local','POST',{name:form.elements.name.value,scope:form.elements.scope.value});record.key=record.id;records.push(record);renderRows();closeForm();await enter(record);}catch(e){form.querySelector('[role=status]').textContent=e.message;button.disabled=false;}};
  };
  async function connectForm(){
    if(installRequired){RemoteInstall.show(false);return;}
    show('Connect remote corpora',`<p>On the host, open <strong>Remote control</strong> and show its QR.</p><section id="pair-panel"><form id="corpora-form" hidden><input id="corpora-address"><button id="find-corpora"></button></form><div id="qr-step"><code id="selected-address" hidden></code><button id="change-corpora" hidden></button><button id="scan-qr" type="button">Scan QR</button><label class="qr-upload">Upload QR<input id="qr-file" type="file" accept="image/png,image/jpeg,image/webp"></label></div><div id="scanner" hidden><video id="qr-camera" autoplay playsinline muted></video><button id="stop-scan" type="button">Cancel scan</button></div><form id="paste-invitation"><label>Or paste an invitation<textarea name="invitation" rows="2" required spellcheck="false" autocomplete="off"></textarea></label><button type="submit">Connect</button></form></section><section id="verify-panel" hidden><p>Approve this matching code on the host.</p><strong id="confirmation-code"></strong></section><p id="pair-feedback" role="status"></p>`);
    let cancelled=false,connecting=false,pendingClient,pendingID;
    const feedback=text=>{if($('pair-feedback'))$('pair-feedback').textContent=text;};
    const pair=async invitation=>{
      if(cancelled||connecting)return;connecting=true;
      try{
        scanner.stop();$('pair-panel').hidden=true;$('verify-panel').hidden=false;feedback('Waiting for host approval…');let record;
        if(remote){
          pendingClient=await RemoteTransport.invitation(invitation);
          $('confirmation-code').textContent=await RemoteCode.confirmation(invitation.desktop,RemoteTransport.b64(pendingClient.session.keys.publicKey),invitation.room);
          const info=await pendingClient.authenticate(true);if(cancelled)return;
          const key=RemoteSession.key(pendingClient.session);sessions.set(key,pendingClient.session);clients.get(key)?.close();clients.set(key,pendingClient);pendingClient=null;
          record={...info,location:'Remote',key};
        }else{
          let result=await json('/api/host/pair','POST',invitation);pendingID=result.id;$('confirmation-code').textContent=result.code;
          while(!cancelled&&result.state==='waiting'){await new Promise(resolve=>setTimeout(resolve,1000));if(!cancelled)result=await json('/api/host/pair/'+pendingID);}
          if(cancelled)return;if(result.state!=='approved')throw new Error(result.error||'Connection cancelled');record={...result.corpora,key:result.corpora.id};pendingID=null;
        }
        records=records.filter(r=>r.key!==record.key);records.push(record);write('s4.records',records);renderRows();closeForm();await enter(record);
      }catch(e){if(!cancelled){feedback(e.message);$('pair-panel').hidden=false;$('verify-panel').hidden=true;}}finally{connecting=false;}
    };
    const scanner=RemoteOnboarding.mount(pair,feedback);
    $('paste-invitation').onsubmit=async event=>{event.preventDefault();try{await pair(RemoteCode.decode(event.target.elements.invitation.value));}catch(e){feedback(e.message);}};
    formCleanup=()=>{cancelled=true;scanner.stop();pendingClient?.close();if(pendingID)json('/api/host/pair/'+pendingID,'POST',{}).catch(()=>{});};
  }
  $('connect-remote-corpora').onclick=connectForm;$('empty-connect-corpora').onclick=connectForm;
  $('empty-create-corpora').onclick=()=>$('create-local-corpora').click();
  async function remoteControl(){
    if(active?.location!=='Local'){error('Open Remote control on the host computer to manage its trusted device.');return;}
    const record=active;
    show('Remote control','<div id="remote-host-content"></div><p id="remote-host-feedback" role="status"></p>');
    let cancelled=false,timer;
    const status=text=>{if($('remote-host-feedback'))$('remote-host-feedback').textContent=text;};
    async function refresh(){
      try{
        const data=await request(record,'/api/remote');if(cancelled)return;
        const html=data.paired?'<p>One remote device is trusted.</p><button data-remote-action="replace">Replace device</button><button data-remote-action="revoke">Revoke access</button>':data.pending?`<p>Approve only if this code matches your remote device.</p><strong>${escape(data.pending.confirmation_code)}</strong><button data-remote-action="approve" data-peer="${escape(data.pending.peer)}">Approve device</button>`:data.invitation?'<p>In the installed app, choose Connect remote corpora and scan this QR.</p><canvas id="host-pair-qr"></canvas><button data-remote-action="revoke">Cancel invitation</button>':data.configured_relay?'<button data-remote-action="pair">Show QR</button>':'<form id="relay-setup"><label>Relay URL<input name="relay" type="url" required></label><label>Connection token<input name="token" type="password" required autocomplete="off"></label><button>Show QR</button></form>';
        const container=$('remote-host-content');if(container.dataset.content!==html){container.innerHTML=html;container.dataset.content=html;if(data.invitation&&$('host-pair-qr'))await RemoteVendor.QRCode.toCanvas($('host-pair-qr'),RemoteCode.link(data.invitation),{width:320,margin:3});}
        status(data.error||'');
      }catch(e){status(e.message);}finally{if(!cancelled)timer=setTimeout(refresh,2500);}
    }
    $('remote-host-content').onclick=async event=>{const button=event.target.closest('[data-remote-action]');if(!button)return;button.disabled=true;try{const action=button.dataset.remoteAction;if(action==='replace'&&!confirm('Replace the trusted remote device? The previous device will lose access.'))return;if(action==='replace'||action==='revoke')await request(record,'/api/remote/revoke','POST',{});if(action==='replace'||action==='pair')await request(record,'/api/remote/pair','POST',{saved:true});if(action==='approve')await request(record,'/api/remote/approve','POST',{peer:button.dataset.peer});clearTimeout(timer);await refresh();}catch(e){status(e.message);}finally{button.disabled=false;}};
    $('remote-host-content').onsubmit=async event=>{event.preventDefault();try{await request(record,'/api/remote/pair','POST',{relay:event.target.elements.relay.value,token:event.target.elements.token.value});clearTimeout(timer);await refresh();}catch(e){status(e.message);}};
    formCleanup=()=>{cancelled=true;clearTimeout(timer);};refresh();
  }
  async function restore(){
    try{
      if(remote){
        const saved=await RemoteSession.list();sessions=new Map(saved.filter(s=>s.relay===location.origin).map(s=>[RemoteSession.key(s),s]));
        records=[...sessions].map(([key,s])=>({...s.corpora,key,location:'Remote'}));
      }else{const data=await json('/api/host');localAvailable=data.local_available;records=data.corpora.map(r=>({...r,key:r.id}));}
      write('s4.records',records);
      if(!active)active=records.find(r=>r.key===read('s4.active',null))||records[0]||null;
      else active=records.find(r=>r.key===active.key)||null;
      $('empty-create-corpora').hidden=!localAvailable;$('corpora-empty').hidden=!!active;renderRows();renderStatus();
      if(active){
        write('s4.active',active.key);
        const cached=read('s4.snapshot.'+active.key,null);if(!started&&cached)deliver(cached);
        if(remote)metadata(active,await client(active).authenticate());
        const snapshot=await request(active,'/api/state');metadata(active,snapshot.corpora);connected=true;$('corpora-startup-feedback').textContent='';cache(snapshot);deliver(snapshot);renderStatus();
      }
    }catch(e){$('corpora-startup-feedback').textContent=e.message;renderStatus();if(!started)setTimeout(restore,3000);}
  }
  function start(){
    if(remote&&'serviceWorker' in navigator)navigator.serviceWorker.register('/sw.js').catch(()=>{});
    if(remote&&RemoteInstall.mobile&&!RemoteInstall.installed()){
      installRequired=true;$('mobile-install-gate').hidden=false;$('corpora-empty').hidden=true;
      $('mobile-install-action').onclick=()=>RemoteInstall.show(false);return;
    }
    installRequired=false;$('mobile-install-gate').hidden=true;
    records=read('s4.records',[]);active=records.find(r=>r.key===read('s4.active',null))||null;
    if(active){const cached=read('s4.snapshot.'+active.key,null);if(cached)deliver(cached);}renderRows();renderStatus();restore();
  }
  const fragment=location.hash.slice(1);if(remote&&fragment)history.replaceState(null,'',location.pathname);
  window.matchMedia?.('(display-mode: standalone)').addEventListener('change',()=>{if(installRequired&&RemoteInstall.installed())start();});
  window.addEventListener('online',()=>{if(!started&&!installRequired)restore();});
  start();
  return {initial,remote,get active(){return active;},get connected(){return connected;},get busy(){return busy;},get generation(){return generation;},
    subscribe:fn=>{listener=fn;if(lastSnapshot)fn(lastSnapshot);},
    async fetch(path,options={}){const record=active;if(!record||busy)throw new Error('Connecting…');const response=remote?await client(record).fetch(path,options):await fetch('/api/host/corpora/'+record.id+path,options);if(record!==active)throw new Error('Workspace changed');return response;},
    snapshot:snapshot=>{if(snapshot.corpora.id!==active?.id)return;$('corpora-startup-feedback').textContent='';metadata(active,snapshot.corpora);connected=true;cache(snapshot);renderStatus();},
    offline:error=>{connected=false;if(error?.revoked||/revoked|another window/.test(error?.message||''))$('corpora-startup-feedback').textContent=error.message;renderStatus();},
    save:preferences=>{if(active)write('s4.workspace.'+active.key,preferences);},decorate,remoteControl,connectForm,
  };
})();
