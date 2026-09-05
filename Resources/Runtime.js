(() => {
'use strict';
if (globalThis.__stillRuntime) return;
const token=String(Math.random());
let policy=__STILL_POLICY__;
let nativeFrames=0,timerTicks=0,maxTimerGap=0,lastTick=performance.now();
let frameID=null,timerID=null;
function sampleFrame(){frameID=null;if(!policy.diagnose)return;nativeFrames++;frameID=requestAnimationFrame(sampleFrame);}
function sampleTimer(){timerID=null;if(!policy.diagnose)return;const now=performance.now();maxTimerGap=Math.max(maxTimerGap,now-lastTick);lastTick=now;timerTicks++;timerID=setTimeout(sampleTimer,100);}
function status(){return{token,policy,nativeHidden:document.hidden,effectiveHidden:document.hidden,nativeFrames,deliveredFrames:nativeFrames,fallbackFrames:0,timerTicks,maxTimerGap,elapsed:performance.now(),wrapperIntact:true};}
function setPolicy(next){policy={...policy,...next};if(policy.diagnose){if(frameID===null)frameID=requestAnimationFrame(sampleFrame);if(timerID===null){lastTick=performance.now();timerID=setTimeout(sampleTimer,100);}}else{if(frameID!==null)cancelAnimationFrame(frameID);if(timerID!==null)clearTimeout(timerID);frameID=timerID=null;}return status();}
function resetDiagnostics(){nativeFrames=timerTicks=maxTimerGap=0;lastTick=performance.now();return status();}
Object.defineProperty(globalThis,'__stillRuntime',{value:{setPolicy,status,resetDiagnostics}});
setPolicy(policy);
try{window.webkit.messageHandlers.stillRuntime.postMessage({type:'ready',token});}catch(_){}
})();
