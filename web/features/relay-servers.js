/* App-wide relay settings. Provisioning credentials stay on the local host. */
'use strict';
window.RelayServers=(()=>{
  const escape=value=>String(value??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const guide='https://github.com/aleski-green/sapiens4/blob/codex/remote-control-mvp/documentation/specs/RemoteMVP.md';
  function mount({show,json,reset,done,cleanup,pairing=false}){
    let state,archived=false,closed=false,working=false;
    const $=id=>document.getElementById(id);
    function screen(title,html){
      show(title,html+'<p id="relay-feedback" role="status"></p>');
      cleanup(()=>{closed=true;});closed=false;
      const heading=$('corpora-dialog-title');heading.tabIndex=-1;heading.focus();
    }
    function feedback(text){if(!closed&&$('relay-feedback'))$('relay-feedback').textContent=text;}
    async function run(fn){
      if(working||closed)return;working=true;
      try{await fn();}catch(e){feedback(e.message);}
      finally{working=false;}
    }
    async function change(data){
      state=await json('/api/host/relays','POST',{revision:state.revision,...data});
      if(state.reset)await reset();
    }
    function confirmChange(data,nextName,back){
      const current=state.servers.find(row=>row.id===state.selected);
      screen(data.action==='save'?'Change connection?':'Switch server?',`<dl class="pairing-details"><dt>From</dt><dd>${escape(current.name)}</dd><dt>To</dt><dd>${escape(nextName)}</dd></dl><p>Switching revokes <strong>all paired devices and remote corpora connections</strong> for this local app.</p><p>Pair all devices and reconnect all remote corpora again.</p><div class="pairing-actions"><button id="relay-cancel">Cancel</button><button id="relay-confirm">Switch &amp; revoke all</button></div>`);
      $('relay-cancel').onclick=back;$('relay-cancel').focus();
      $('relay-confirm').onclick=()=>run(async()=>{await change({...data,confirm_revoke:true});if(!closed)list();});
    }
    function list(){
      if(closed)return;
      const rows=state.servers.filter(row=>archived||!row.archived);
      screen('Remote Control Relay Servers',`<div id="relay-list" class="relay-list ${rows.length>=3?'relay-scroll':''}" role="group" aria-label="Relay servers">${rows.map(row=>`<div class="relay-row" data-current="${row.id===state.selected}"><label><input type="radio" name="relay-server" value="${escape(row.id)}" ${row.id===state.selected?'checked':''} ${row.archived||!row.available?'disabled':''}><span><strong>${escape(row.name)}</strong><small>${escape(row.address.replace(/^https?:\/\//,''))}</small></span></label><span class="relay-badge">${row.archived?'Archived':!row.available?'Inactive':row.id===state.selected?'Current':''}</span><div class="relay-row-actions"><button data-edit-relay="${escape(row.id)}">Edit</button><button data-archive-relay="${escape(row.id)}">${row.archived?'Restore':'Archive'}</button></div></div>`).join('')}</div><label class="relay-check"><input id="relay-archived" type="checkbox" ${archived?'checked':''}>Show archived</label><button id="relay-add" class="relay-add">+ Add your own relay <small>Recommended</small></button><p class="relay-warning">ⓘ Beta: use at your own risk. Self-host for sensitive work.</p><button id="relay-continue">${pairing?'Continue':'Done'}</button>`);
      $('relay-archived').onchange=event=>{archived=event.target.checked;list();};
      $('relay-add').onclick=()=>editor();
      $('relay-list').onchange=event=>{
        const row=state.servers.find(row=>row.id===event.target.value);
        if(!row||row.id===state.selected)return;
        confirmChange({action:'switch',id:row.id},row.name,list);
      };
      $('relay-list').onclick=event=>{
        const button=event.target.closest('button');if(!button)return;
        if(button.dataset.editRelay)run(async()=>{const row=await json('/api/host/relays/'+button.dataset.editRelay);if(!closed)editor(row);});
        if(button.dataset.archiveRelay)run(async()=>{const row=state.servers.find(row=>row.id===button.dataset.archiveRelay);await change({action:row.archived?'restore':'archive',id:row.id});if(!closed)list();});
      };
      $('relay-continue').onclick=()=>{
        const current=state.servers.find(row=>row.id===state.selected);
        if(pairing&&current.beta&&!state.beta_accepted)terms();else done?.();
      };
    }
    function editor(row=null,draft=null){
      screen(row?'Edit relay':'Add your own relay',`<p><a href="${guide}" target="_blank" rel="noopener noreferrer">Deploy on GitHub ↗</a></p><form id="relay-editor"><label>Name<input name="name" required maxlength="200" autocomplete="off"></label><label>Connection JSON<textarea name="connection" rows="6" required spellcheck="false" autocomplete="off" maxlength="4096"></textarea></label><label class="qr-upload">Import JSON<input name="file" type="file" accept="application/json,.json"></label><p class="relay-private">Stored privately on this desktop.</p><div class="pairing-actions"><button type="button" id="relay-editor-cancel">Cancel</button><button type="submit">Save</button></div></form>`);
      const form=$('relay-editor');
      form.elements.name.value=draft?.name??row?.name??'';
      form.elements.connection.value=draft?.json??(row?JSON.stringify(row.connection,null,2):'');
      form.elements.connection.placeholder='Paste your relay.connection.json';
      $('relay-editor-cancel').onclick=list;
      form.elements.file.onchange=()=>run(async()=>{
        const file=form.elements.file.files[0];if(!file)return;
        if(file.size>4096)throw new Error('Connection file is too large.');
        const raw=await file.text();parse(raw);form.elements.connection.value=raw;feedback('');
      });
      form.onsubmit=event=>{
        event.preventDefault();if(!form.reportValidity()||working)return;
        const draft={name:form.elements.name.value.trim(),json:form.elements.connection.value};
        let connection;try{connection=parse(draft.json);}catch(e){feedback(e.message);return;}
        const data={action:'save',...(row?{id:row.id}:{}),name:draft.name,connection};
        if(row?.id===state.selected&&JSON.stringify(connection)!==JSON.stringify(parse(JSON.stringify(row.connection)))){
          confirmChange(data,draft.name,()=>editor(row,draft));
        }else run(async()=>{await change(data);if(!closed)list();});
      };
      form.elements.name.focus();
    }
    function terms(){
      screen('Use beta relay?',`<p>For sensitive work, use your own securely maintained relay.</p><p>Provided “as is,” without warranties. Use at your own risk.</p><p>To the extent permitted by law, authors, contributors, and operators disclaim liability for losses or damages from this service.</p><p>Non-excludable rights and liabilities remain unaffected.</p><label class="relay-check"><input id="relay-accept" type="checkbox">I accept these beta terms.</label><div class="pairing-actions"><button id="relay-beta-back">Back</button><button id="relay-own">Use my relay</button><button id="relay-beta-use" disabled>Use beta</button></div>`);
      $('relay-beta-back').onclick=list;$('relay-own').onclick=()=>editor();
      $('relay-accept').onchange=event=>{$('relay-beta-use').disabled=!event.target.checked;};
      $('relay-beta-use').onclick=()=>run(async()=>{await change({action:'accept-beta',accepted:true});if(!closed)done();});
    }
    function parse(raw){
      try{
        if(raw.length>4096)throw new Error();
        const value=JSON.parse(raw),url=new URL(value.relay);
        if(value.format!=='sapiens-relay-connection-v1'||url.username||url.password||url.search||url.hash||url.pathname!=='/'||!(url.protocol==='https:'||(url.protocol==='http:'&&['localhost','127.0.0.1','[::1]'].includes(url.hostname))))throw new Error();
        if(value.beta===true&&!value.token)return {format:value.format,relay:url.origin,beta:true};
        if(typeof value.token!=='string'||!/^[\x21-\x7e]{32,256}$/.test(value.token))throw new Error();
        return {format:value.format,relay:url.origin,token:value.token};
      }catch{throw new Error('Enter valid relay connection JSON.');}
    }
    screen('Remote Control Relay Servers','<p>Loading…</p>');
    run(async()=>{state=await json('/api/host/relays');if(!closed)list();});
  }
  return {mount};
})();
