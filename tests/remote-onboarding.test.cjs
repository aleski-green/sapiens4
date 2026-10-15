const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const {JSDOM}=require('jsdom');
const root=path.join(__dirname,'..');
const settle=()=>new Promise(resolve=>setTimeout(resolve,0));
(async()=>{
 const dom=new JSDOM(fs.readFileSync(path.join(root,'web/shell/remote.html'),'utf8'),{url:'https://relay.example',runScripts:'outside-only'});
 const w=dom.window,$=id=>w.document.getElementById(id);let message='',requests=[],paired=0,stops=0,fail=false;
 const invitation={public_id:'sapi4_abc123qwe',desktop:Buffer.alloc(32,7).toString('base64'),expires:Date.now()/1000+259200};
 w.fetch=async(url,options)=>{requests.push(url);assert.equal(options.redirect,'error');return {ok:!fail,json:async()=>fail?{error:'No active QR.'}:invitation};};
 w.eval(fs.readFileSync(path.join(root,'web/features/remote-code.js'),'utf8'));
 w.eval(fs.readFileSync(path.join(root,'web/features/remote-onboarding.js'),'utf8'));
 const flow=w.RemoteOnboarding.mount(async()=>{paired++;},text=>message=text);
 const submit=async(value)=>{$('corpora-address').value=value;$('corpora-form').dispatchEvent(new w.Event('submit',{cancelable:true}));await settle();};
 await submit('wrong');assert.equal(requests.length,0);assert.match(message,/sapi4_/);
 for(const invalid of ['sapi4_5ioqgcj8q','sapi4_123abc456','sapi4_ab123qw','sapi4_abcd123qw']) {
  await submit(invalid);assert.equal(requests.length,0);assert.equal($('corpora-address').checkValidity(),false);
 }
 fail=true;await submit(invitation.public_id);assert.equal($('qr-step').hidden,true);assert.match(message,/No active/);
 fail=false;await submit(invitation.public_id);assert.equal($('qr-step').hidden,false);assert.equal(paired,0,'ID alone never pairs');
 assert.equal($('selected-address').textContent,invitation.public_id);
 await assert.rejects(flow.validate({...invitation,public_id:'sapi4_other0000'}),/another CORPORA/);
 await assert.rejects(flow.validate({...invitation,desktop:'another-key'}),/QR replaced/);
 await flow.validate(invitation);
 $('scan-qr').click();await settle();assert.match(message,/Camera unavailable/);assert.equal($('scan-qr').disabled,false);
 let resolveCamera;
 Object.defineProperty(w.navigator,'mediaDevices',{value:{getUserMedia:()=>new Promise(resolve=>{resolveCamera=resolve;})}});
 $('scan-qr').click();await settle();flow.stop();resolveCamera({getTracks:()=>[{stop:()=>stops++}]});await settle();
 assert.equal(stops,1,'Cancelling while permission is pending must release the resulting stream');
 const video=$('qr-camera');
 Object.defineProperties(video,{readyState:{value:2},videoWidth:{value:800},videoHeight:{value:600}});
 video.play=async()=>{};
 w.HTMLCanvasElement.prototype.getContext=()=>({drawImage(){},getImageData(){return {data:new Uint8ClampedArray(4)};}});
 let qr=JSON.stringify(invitation);
 w.RemoteVendor={jsQR:()=>({data:qr})};
 const scan=async()=>{
  $('scan-qr').click();resolveCamera({getTracks:()=>[{stop:()=>stops++}]});await settle();await settle();
 };
 await scan();assert.equal(paired,1);assert.equal(stops,2);assert.equal(video.srcObject,null);
 assert.equal($('scanner').hidden,true,'Successful decoding releases and hides the camera');
 qr='{'+' '.repeat(4096)+'}';await scan();assert.equal(paired,1);assert.equal(stops,3);
 assert.match(message,/Use the QR/,'Camera and image uploads enforce the same invitation size limit');
 $('change-corpora').click();assert.equal($('corpora-form').hidden,false);assert.equal(w.document.activeElement,$('corpora-address'));
 dom.window.close();console.log('ID lookup, QR identity binding, camera fallback and cancellation passed');
})().catch(error=>{console.error(error);process.exitCode=1;});
