'use strict';
window.RemoteOnboarding = (() => {
  function mount(pair, status) {
    const $ = id => document.getElementById(id);
    const canvas = document.createElement('canvas');
    let stream = null, timer = null, generation = 0;
    function stop() {
      generation++; clearTimeout(timer); timer=null;
      stream?.getTracks().forEach(track=>track.stop());stream=null;
      const video=$('qr-camera');if(video) video.srcObject=null;
      if($('scanner')) $('scanner').hidden=true;
      if($('scan-qr')) $('scan-qr').disabled=false;
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
    const hidden=()=>{if(document.hidden)stop();};
    document.addEventListener('visibilitychange',hidden);
    window.addEventListener('pagehide',stop);
    return {stop,dispose(){stop();document.removeEventListener('visibilitychange',hidden);window.removeEventListener('pagehide',stop);}};
  }
  return {mount};
})();
