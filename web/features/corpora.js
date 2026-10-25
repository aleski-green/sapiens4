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
  const client=record=>{
    // A cached page can resume before IndexedDB has restored its credentials.
    // Do not retain an unusable transport for the rest of that page's lifetime.
    if(!sessions.has(record.key))throw new Error('Connecting…');
    if(!clients.has(record.key))clients.set(record.key,new RemoteTransport(sessions.get(record.key)));
    return clients.get(record.key);
  };
  async function request(record,path,method='GET',data){
    if(!record)throw new Error('Connect a corpora first.');
    if(record===active&&!connected&&method!=='GET')throw new Error('Offline — read only.');
    if(remote){const response=await client(record).fetch(path,{method,...(data===undefined?{}:{body:JSON.stringify(data)})});const value=await response.json();if(!response.ok)throw new Error(value.error||'Request failed');return value;}
    return json('/api/host/corpora/'+record.id+path,method,data);
  }
  function metadata(record,data){Object.assign(record,data);if(record===active)renderStatus();renderRows();}
  function renderStatus(){
    $('corpora-location').textContent=active?.location||'Remote';
    $('connection-label').textContent=busy?'Connecting…':!active?'Not connected':!connected?'Offline':active.stopping?'Pausing…':({active:'Active',paused:'Paused',archived:'Archived'}[active.status]||'Active');
    $('connection-status').dataset.online=String(connected&&!busy&&active?.status==='active');
    $('connection-status').disabled=!active||!connected||busy;
    $('connection-status').setAttribute('aria-expanded',String(!statusMenu.hidden));
    statusMenu.innerHTML=active?.status==='archived'?'<span>Archived</span>':`<button type="button" data-lifecycle="pause" ${active?.status==='paused'?'disabled':''}>${active?.status==='paused'?'Paused ✓':'Pause'}</button><button type="button" data-lifecycle="activate" ${active?.status==='active'?'disabled':''}>${active?.status==='active'?'Active ✓':'Activate'}</button>`;
    renderRows();notify();
  }
  function renderRows(){
    const hasLocal=!remote&&records.some(r=>r.location==='Local');
    menu.dataset.hasLocal=String(hasLocal);
    menu.querySelector('.corpora-remote-column').hidden=!hasLocal;
    const rowsHTML=records.filter(r=>!r.archived&&r.status!=='archived'||$('corpora-archived').checked).map(r=>`<div class="corpora-record" data-selected="${r.key===selectedKey()}"><span class="corpora-location-cell">${escape(r.location)}</span><span class="corpora-name-cell"><button class="corpora-name" data-enter="${escape(r.key)}" ${r.status==='archived'||busy?'disabled':''} aria-pressed="${r.key===selectedKey()}">${escape(r.name)}</button><button class="corpora-edit" data-edit="${escape(r.key)}" ${busy?'disabled':''}>Edit</button></span><span class="corpora-state"><i class="corpora-dot" data-active="${r.status==='active'&&(r!==active||connected)}"></i>${escape(r===active&&!connected?'Offline':({active:'Active',paused:'Paused',archived:'Archived'}[r.status]||'Active'))}</span><span class="corpora-device">${escape(r.device||'Host computer')}</span>${hasLocal?`<span class="corpora-pairing-cell">${r.location==='Local'?`<button data-pairing="${escape(r.key)}" ${busy?'disabled':''}>${r.paired?'Edit Pairing':'New Pairing'}</button>`:''}</span>`:''}</div>`).join('');
    if($('corpora-rows').innerHTML!==rowsHTML)$('corpora-rows').innerHTML=rowsHTML;
    $('create-local-corpora').hidden=!localAvailable;
    $('manage-relay-servers').hidden=remote;
    $('corpora-picker').title=active?.name||'Corpora';
    $('corpora-picker').setAttribute('aria-expanded',String(!menu.hidden));
    $('connection-status').setAttribute('aria-expanded',String(!statusMenu.hidden));
  }
  async function refreshPairings(){
    await Promise.all(records.filter(r=>!remote&&r.location==='Local').map(async record=>{try{const data=await request(record,'/api/remote');record.paired=data.paired;renderRows();}catch{}}));
  }
  function error(message){$('corpora-notice-text').textContent=message;$('corpora-notice').showModal();}
  function show(title,html){formCleanup();formCleanup=()=>{};$('corpora-dialog-title').textContent=title;$('corpora-dialog-body').innerHTML=html;if(!dialog.open){dialog.showModal();history.pushState({sapiensDialog:true},'');}}
  function closeForm(){formCleanup();formCleanup=()=>{};dialog.close();if(history.state?.sapiensDialog){suppressDialogPop=true;history.back();}}
  $('corpora-dialog-close').onclick=closeForm;dialog.addEventListener('cancel',event=>{event.preventDefault();closeForm();});
  window.addEventListener('popstate',()=>{if(suppressDialogPop){suppressDialogPop=false;return;}if(dialog.open&&!history.state?.sapiensDialog){formCleanup();formCleanup=()=>{};dialog.close();}menu.hidden=true;statusMenu.hidden=true;renderRows();});
  $('corpora-notice-close').onclick=()=>$('corpora-notice').close();
  $('corpora-picker').onclick=()=>{menu.hidden=!menu.hidden;statusMenu.hidden=true;renderRows();if(!menu.hidden)refreshPairings();};
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
      const cached=read('s4.snapshot.'+record.key,null);
      const snapshot=cached||await request(record,'/api/state');metadata(record,snapshot.corpora);
      window.sapiensWorkspace?.save();active=record;write('s4.active',record.key);connected=!cached;
      cache(snapshot);deliver(snapshot);menu.hidden=false;$('corpora-empty').hidden=true;
      write('s4.records',records);
    }catch(e){error(e.message);}
    finally{busy=false;renderRows();renderStatus();}
  }
  $('corpora-rows').onclick=event=>{const button=event.target.closest('button');if(button?.dataset.enter)enter(records.find(r=>r.key===button.dataset.enter));if(button?.dataset.edit)edit(records.find(r=>r.key===button.dataset.edit));if(button?.dataset.pairing)remoteControl(records.find(r=>r.key===button.dataset.pairing));};
  statusMenu.onclick=async event=>{const action=event.target.closest('[data-lifecycle]')?.dataset.lifecycle;if(!action||busy)return;busy=true;renderStatus();try{await reconcile();await lifecycle(active,action);}catch(e){error(e.message);}finally{busy=false;statusMenu.hidden=true;renderStatus();}};
  function edit(record){
    show('Message to ChiefSapi',`<form id="chief-settings-form"><textarea name="message" aria-label="Message to ChiefSapi" rows="8" required></textarea><p class="corpora-feedback" role="status"></p><button type="submit">Send to ChiefSapi ↑</button></form>`);
    const form=$('chief-settings-form');form.elements.message.value=(record.settings_template||lastSnapshot?.corpora?.settings_template||'').replace(/\{(name|device|scope)\}/g,(_,field)=>record[field]||'');
    form.onsubmit=async event=>{
      event.preventDefault();if(busy)return;
      const button=form.querySelector('button'),feedback=form.querySelector('[role=status]');
      button.disabled=true;busy=true;generation++;renderStatus();renderRows();
      try{
        await reconcile();
        let info=await request(record,'/api/corpora');metadata(record,info);
        if(info.status==='archived')throw new Error('Restore this archived corpora before sending. Your draft is kept here.');
        if(info.status==='paused'){feedback.textContent='Activating corpora…';info=await lifecycle(record,'activate');}
        feedback.textContent='Sending to ChiefSapi…';
        await request(record,'/api/agents/'+info.chief_id+'/messages','POST',{text:form.elements.message.value});
        closeForm();
      }catch(e){feedback.textContent=e.message;}
      finally{button.disabled=false;busy=false;renderRows();renderStatus();}
    };
    form.elements.message.focus();
  }
  $('create-local-corpora').onclick=()=>{
    show('Create local corpora','<form id="new-corpora-form"><label>Corpora name<input name="name" required maxlength="200" autofocus></label><label>Scope of work<textarea name="scope" rows="4" maxlength="16000"></textarea></label><p role="status"></p><button type="submit">Create</button></form>');
    const form=$('new-corpora-form');form.onsubmit=async event=>{event.preventDefault();const button=form.querySelector('button');button.disabled=true;try{const record=await json('/api/host/local','POST',{name:form.elements.name.value,scope:form.elements.scope.value});record.key=record.id;records.push(record);renderRows();closeForm();await enter(record);}catch(e){form.querySelector('[role=status]').textContent=e.message;button.disabled=false;}};
  };
  async function connectForm(){
    if(installRequired){RemoteInstall.mount();return;}
    show('Connect remote corpora',`<p>On the host, open the corpora menu and choose <strong>New Pairing</strong> in its Remote column.</p><section id="pair-panel"><div id="qr-step"><button id="scan-qr" type="button">Scan QR</button><label class="qr-upload">Upload QR<input id="qr-file" type="file" accept="image/png,image/jpeg,image/webp"></label></div><div id="scanner" hidden><video id="qr-camera" autoplay playsinline muted></video><button id="stop-scan" type="button">Cancel scan</button></div><form id="paste-invitation"><label>Or paste an invitation<textarea name="invitation" rows="2" required spellcheck="false" autocomplete="off"></textarea></label><button type="submit">Connect</button></form></section><section id="verify-panel" hidden><p>Approve this matching code on the host.</p><strong id="confirmation-code"></strong></section><p id="pair-feedback" role="status"></p>`);
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
    formCleanup=()=>{cancelled=true;scanner.dispose();pendingClient?.close();if(pendingID)json('/api/host/pair/'+pendingID,'POST',{}).catch(()=>{});};
  }
  $('connect-remote-corpora').onclick=connectForm;$('empty-connect-corpora').onclick=connectForm;
  $('empty-create-corpora').onclick=()=>$('create-local-corpora').click();
  async function resetRelayConnections(broadcast=true){
    generation++;
    const removed=records.filter(row=>row.location==='Remote');
    removed.forEach(row=>{clients.get(row.key)?.close();clients.delete(row.key);sessions.delete(row.key);localStorage.removeItem('s4.snapshot.'+row.key);});
    records=records.filter(row=>row.location==='Local');records.forEach(row=>{row.paired=false;});
    if(active?.location==='Remote'){
      active=records[0]||null;lastSnapshot=null;connected=false;
      write('s4.active',active?.key||null);
    }
    write('s4.records',records);write('s4.lifecycle.pending',null);write('s4.switch.pending',null);
    if(broadcast)write('s4.relay-reset',crypto.randomUUID());
    await restore();
  }
  function relayManager(record){
    if(remote||busy)return;
    RelayServers.mount({show,json,reset:resetRelayConnections,pairing:!!record,
      done:record?()=>remoteControl(record,true):closeForm,
      cleanup:fn=>{formCleanup=fn;}});
  }
  $('manage-relay-servers').onclick=()=>relayManager();
  window.addEventListener('storage',event=>{
    if(!remote&&event.key==='s4.relay-reset'){closeForm();resetRelayConnections(false);}
  });
  async function remoteControl(record,ready=false){
    if(remote||record?.location!=='Local')return;
    if(!ready){
      try{const data=await request(record,'/api/remote');if(!data.enabled&&!data.paired){relayManager(record);return;}}catch(e){error(e.message);return;}
    }
    show(record.paired?'Edit Pairing':'New Pairing','<div id="remote-host-content"></div><p id="remote-host-feedback" role="status"></p>');
    let cancelled=false,timer,invitationLink='';
    const container=$('remote-host-content');
    const status=text=>{if(!cancelled)$('remote-host-feedback').textContent=text;};
    const date=value=>typeof value==='number'&&Number.isFinite(value)?new Date(value*1000).toLocaleString([], {dateStyle:'medium',timeStyle:'long'}):'Not recorded';
    async function refresh(){
      try{
        const data=await request(record,'/api/remote');if(cancelled)return;
        record.paired=data.paired;renderRows();$('corpora-dialog-title').textContent=data.paired?'Edit Pairing':'New Pairing';
        const info=data.device_info||{},invitation=data.enabled&&data.invitation?.expires>Date.now()/1000?data.invitation:null;
        invitationLink=invitation?RemoteCode.link(invitation):'';
        const html=data.available===false?'<p>Remote control is unavailable. Install the remote dependencies and restart Sapiens4.</p>':data.paired?`<p class="pairing-corpora">${escape(record.name)}</p><dl class="pairing-details"><dt>Device</dt><dd>${escape(info.name||'Not recorded')}</dd><dt>Device info</dt><dd>${escape([info.platform,info.client].filter(Boolean).join(' · ')||'Not recorded')}</dd><dt>Paired</dt><dd>${escape(date(data.paired_at))}</dd><dt>Last connected</dt><dd>${escape(date(data.last_connected_at))}</dd></dl><div class="pairing-actions"><button data-remote-action="replace">Replace remote</button><button data-remote-action="revoke">Revoke remote</button></div>`
          :data.pending?`<p>Approve only if this code matches your remote device.</p><strong>${escape(data.pending.confirmation_code||'')}</strong><button data-remote-action="approve" data-peer="${escape(data.pending.peer)}" ${data.pending.confirmation_code?'':'disabled'}>Approve device</button>`
          :invitation?`<p>In the installed app, choose Connect remote corpora and scan this QR.</p><canvas id="host-pair-qr"></canvas><p>Expires ${escape(date(invitation.expires))}</p><div class="pairing-actions"><button data-remote-action="link">Show link</button><a id="download-pair-qr" download="sapiens4-pairing.png">Download QR</a><a href="${escape(invitation.relay)}" target="_blank" rel="noopener noreferrer">Open app ↗</a><button data-remote-action="revoke">Cancel invitation</button></div><input id="host-pair-link" aria-label="Pairing link" readonly hidden>`
          :data.enabled?'<p>Invitation expired.</p><button data-remote-action="revoke">Cancel invitation</button>'
          :'<div class="pairing-actions"><button data-remote-action="pair">Show QR</button><button data-remote-action="servers">Relay servers</button></div>';
        const content=html+(data.error?`<p>${escape(data.error)}</p>`:'');
        if(container.dataset.content!==content){
          container.innerHTML=content;container.dataset.content=content;
          const canvas=$('host-pair-qr');
          if(canvas){await RemoteVendor.QRCode.toCanvas(canvas,RemoteCode.link(invitation),{width:320,margin:3});if(!cancelled&&canvas.isConnected)$('download-pair-qr').href=canvas.toDataURL('image/png');}
        }
      }catch(e){status(e.message);}finally{if(!cancelled){clearTimeout(timer);timer=setTimeout(refresh,2500);}}
    }
    async function action(button,perform){
      button.disabled=true;status('');
      try{await perform();if(!cancelled)await refresh();}catch(e){status(e.message);}finally{if(button.isConnected)button.disabled=false;}
    }
    container.onclick=event=>{
      const button=event.target.closest('[data-remote-action]');if(!button||button.disabled)return;
      const command=button.dataset.remoteAction;
      if(command==='servers'){relayManager(record);return;}
      if(command==='link'){const field=$('host-pair-link');field.value=invitationLink;field.hidden=false;field.focus();field.select();return;}
      if(command==='revoke'&&!confirm('Revoke this remote access? It will need to pair again.'))return;
      if(command==='replace'&&!confirm('Replace the trusted remote device? The previous device will lose access.'))return;
      action(button,async()=>{
        if(command==='replace'||command==='revoke'){
          const result=await request(record,'/api/remote/revoke','POST',{});
          if(result.relay_deleted===false)status('Revoked locally. Relay could not be reached.');
        }
        if(['replace','pair','local'].includes(command))await request(record,'/api/remote/pair','POST',command==='local'?{local:true}:{saved:true});
        if(command==='approve')await request(record,'/api/remote/approve','POST',{peer:button.dataset.peer});
      });
    };
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
      if(!remote&&new URLSearchParams(location.search).get('pairing')==='local'){history.replaceState(null,'',location.pathname);remoteControl(records.find(r=>r.location==='Local'));}
      $('empty-create-corpora').hidden=!localAvailable;$('corpora-empty').hidden=!!active;renderRows();renderStatus();
      if(active){
        write('s4.active',active.key);
        const cached=read('s4.snapshot.'+active.key,null);if(!started&&cached)deliver(cached);
        const record=active,version=generation;
        if(remote)await client(record).authenticate();
        const snapshot=await request(record,'/api/state');if(record!==active||version!==generation)return;metadata(record,snapshot.corpora);connected=true;$('corpora-startup-feedback').textContent='';cache(snapshot);deliver(snapshot);renderStatus();
      }
    }catch(e){$('corpora-startup-feedback').textContent=e.message;renderStatus();if(!started)setTimeout(restore,3000);}
  }
  function start(){
    if(remote&&'serviceWorker' in navigator)navigator.serviceWorker.register('/sw.js').catch(()=>{});
    if(remote&&RemoteInstall.mobile&&!RemoteInstall.installed()){
      installRequired=true;$('mobile-install-gate').hidden=false;$('corpora-empty').hidden=true;
      RemoteInstall.mount();return;
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
    // Metadata refreshes keep the corpora identity; navigation invalidates in-flight requests.
    async fetch(path,options={}){const record=active,version=generation;if(!record||busy)throw new Error('Connecting…');if(!connected&&!['GET','HEAD'].includes((options.method||'GET').toUpperCase()))throw new Error('Offline — read only.');const response=remote?await client(record).fetch(path,options):await fetch('/api/host/corpora/'+record.id+path,options);if(record.key!==active?.key||version!==generation)throw new Error('Workspace changed');return response;},
    snapshot:snapshot=>{if(snapshot.corpora.id!==active?.id)return;$('corpora-startup-feedback').textContent='';metadata(active,snapshot.corpora);connected=true;cache(snapshot);renderStatus();},
    offline:error=>{connected=false;if(error?.revoked||/revoked|another window/.test(error?.message||''))$('corpora-startup-feedback').textContent=error.message;renderStatus();},
    save:preferences=>{if(active)write('s4.workspace.'+active.key,preferences);},decorate,remoteControl,connectForm,
  };
})();
