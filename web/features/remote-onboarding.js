/* Public address discovery, QR verification, and an app-local camera scanner. */
'use strict';
window.RemoteOnboarding = (() => {
  const pattern = /^sapi4_[a-z0-9]{9}$/;
  function mount(pair, status) {
    const $ = id => document.getElementById(id);
    let selected = null, stream = null, timer = null, generation = 0, looking = false;
    async function lookup(address) {
      if(!pattern.test(address)) throw new Error('Use an ID like sapi4_abc123qwe.');
      const response = await fetch('/api/corpora/'+encodeURIComponent(address), {cache:'no-store',redirect:'error'});
      const data = await response.json();
      if(!response.ok) throw new Error(data.error || 'CORPORA unavailable. Try again.');
      if(data.public_id!==address || typeof data.desktop!=='string' || !Number.isFinite(data.expires) || data.expires<=Date.now()/1000)
        throw new Error('QR expired. Show a new QR on desktop.');
      return data;
    }
    function stop() {
      generation++; clearTimeout(timer); timer=null;
      stream?.getTracks().forEach(track=>track.stop());stream=null;
      const video=$('qr-camera');if(video) video.srcObject=null;
      if($('scanner')) $('scanner').hidden=true;
      if($('scan-qr')) $('scan-qr').disabled=false;
    }
    async function validate(data) {
      if(!data.public_id && !selected) return; // Existing one-hour invitations remain usable.
      if(selected && data.public_id!==selected.public_id) throw new Error('This QR belongs to another CORPORA.');
      const found=await lookup(data.public_id);
      if(found.desktop!==data.desktop || (selected && selected.desktop!==data.desktop))
        throw new Error('QR replaced. Use the latest QR on desktop.');
      selected=found;
    }
    $('corpora-form').addEventListener('submit',async event=>{
      event.preventDefault();if(looking)return;looking=true;$('find-corpora').disabled=true;status('Finding CORPORA…');
      try {
        const address=$('corpora-address').value.trim().toLowerCase();
        selected=await lookup(address);$('corpora-address').value=address;
        $('selected-address').textContent=address;$('corpora-form').hidden=true;$('qr-step').hidden=false;status('');
      } catch(error){status(error.message);}
      finally{looking=false;$('find-corpora').disabled=false;}
    });
    $('change-corpora').addEventListener('click',()=>{
      stop();selected=null;$('qr-step').hidden=true;$('corpora-form').hidden=false;$('corpora-address').focus();status('');
    });
    $('stop-scan').addEventListener('click',stop);
    $('scan-qr').addEventListener('click',async()=>{
      stop();const current=generation;$('scan-qr').disabled=true;status('');
      try {
        if(!navigator.mediaDevices?.getUserMedia) throw new Error('Camera unavailable. Upload a QR image.');
        const camera=await navigator.mediaDevices.getUserMedia({video:{facingMode:{ideal:'environment'}},audio:false});
        if(current!==generation){camera.getTracks().forEach(track=>track.stop());return;}
        stream=camera;const video=$('qr-camera');video.srcObject=stream;$('scanner').hidden=false;await video.play();
        const canvas=document.createElement('canvas'),context=canvas.getContext('2d',{willReadFrequently:true});
        async function scan() {
          if(current!==generation)return;
          try {
            if(video.readyState>=2 && video.videoWidth) {
              const scale=Math.min(1,1000/video.videoWidth);canvas.width=Math.round(video.videoWidth*scale);canvas.height=Math.round(video.videoHeight*scale);
              context.drawImage(video,0,0,canvas.width,canvas.height);const pixels=context.getImageData(0,0,canvas.width,canvas.height);
              const qr=RemoteVendor.jsQR(pixels.data,canvas.width,canvas.height);
              if(qr){stop();await pair(qr.data.trim().startsWith('{')?JSON.parse(qr.data):RemoteCode.decode(qr.data));return;}
            }
            timer=setTimeout(scan,200);
          } catch(error){stop();status(error.message);}
        }
        scan();
      } catch(error){stop();status(error.name==='NotAllowedError'?'Camera access is off. Upload a QR image.':error.message);}
    });
    document.addEventListener('visibilitychange',()=>{if(document.hidden)stop();});
    window.addEventListener('pagehide',stop);
    return {validate,stop};
  }
  return {mount};
})();
