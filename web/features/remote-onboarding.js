/* Public address discovery, QR verification, and an app-local camera scanner. */
'use strict';
window.RemoteOnboarding = (() => {
  const pattern = /^sapi4_[a-z]{3}[0-9]{3}[a-z]{3}$/;
  function mount(pair, status) {
    const $ = id => document.getElementById(id);
    const canvas = document.createElement('canvas');
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
    function readQR(image, width, height, limit) {
      const scale=Math.min(1,limit/Math.max(width,height));
      canvas.width=Math.round(width*scale);canvas.height=Math.round(height*scale);
      const context=canvas.getContext('2d',{willReadFrequently:true});
      context.drawImage(image,0,0,canvas.width,canvas.height);
      return RemoteVendor.jsQR(context.getImageData(0,0,canvas.width,canvas.height).data,canvas.width,canvas.height);
    }
    async function upload(file) {
      if(!window.isSecureContext) throw new Error('Open this app over HTTPS.');
      if(!file || file.size>10*1024*1024) throw new Error('Choose a QR image smaller than 10 MB.');
      const url=URL.createObjectURL(file), image=new Image();
      try {
        image.src=url;await image.decode();
        if(image.naturalWidth*image.naturalHeight>20000000) throw new Error('Image dimensions are too large.');
        const qr=readQR(image,image.naturalWidth,image.naturalHeight,1600);
        if(!qr) throw new Error('No supported QR found in this image.');
        await pair(RemoteCode.decode(qr.data));
      } finally { URL.revokeObjectURL(url); }
    }
    $('qr-file').addEventListener('change',async event=>{
      try {await upload(event.target.files[0]);}
      catch(error) {status(error.message);}
      finally {event.target.value='';}
    });
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
        async function scan() {
          if(current!==generation)return;
          try {
            if(video.readyState>=2 && video.videoWidth) {
              const qr=readQR(video,video.videoWidth,video.videoHeight,1000);
              if(qr){stop();await pair(RemoteCode.decode(qr.data));return;}
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
