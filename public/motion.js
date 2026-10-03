export const reducedMotion=()=>matchMedia('(prefers-reduced-motion: reduce)').matches;
const runningMotion=new WeakMap();
let revealObserver;
const lowResource=(navigator.deviceMemory!==undefined&&navigator.deviceMemory<=2)||(navigator.deviceMemory===undefined&&navigator.hardwareConcurrency<=4);
document.documentElement.classList.toggle('low-resource',lowResource);
export function animateElement(el,frames,options={}) {
  if(!el||!el.animate)return;
  runningMotion.get(el)?.cancel();
  const animation=el.animate(reducedMotion()? [{opacity:.85},{opacity:1}]:frames,{duration:reducedMotion()?70:240,easing:'cubic-bezier(.22,1,.36,1)',...options,...(reducedMotion()?{duration:70,delay:0}:{})});
  runningMotion.set(el,animation);return animation;
}
export function revealWithin(root,direction=1){
  revealObserver?.disconnect();
  const elements=[...root.querySelectorAll('[data-reveal]')];
  const frames=[{opacity:0,transform:`translateY(${8*direction}px)`},{opacity:1,transform:'translateY(0)'}];
  elements.filter(el=>el.getBoundingClientRect().top<innerHeight+100).slice(0,lowResource?4:12).forEach((el,i)=>animateElement(el,frames,{duration:lowResource?180:400,delay:Math.min(i,6)*35}));
  if(!reducedMotion()&&'IntersectionObserver' in window){
    revealObserver=new IntersectionObserver(entries=>{for(const entry of entries)if(entry.isIntersecting){animateElement(entry.target,frames,{duration:lowResource?180:350});revealObserver.unobserve(entry.target);}},{rootMargin:'0px 0px -30px 0px'});
    elements.filter(el=>el.getBoundingClientRect().top>=innerHeight+100).slice(0,24).forEach(el=>revealObserver.observe(el));
  }
}
export function feedbackMotion(el){animateElement(el,[{transform:'scale(1)'},{transform:'scale(.94)',offset:.3},{transform:'scale(1.035)',offset:.7},{transform:'scale(1)'}],{duration:260});}
export function rememberPositions(root){return new Map([...root.querySelectorAll('[data-motion-id]')].slice(0,24).map(el=>[el.dataset.motionId,el.getBoundingClientRect()]));}
export function reorderMotion(root,before){if(reducedMotion())return;const changes=[...root.querySelectorAll('[data-motion-id]')].slice(0,24).map(el=>({el,old:before.get(el.dataset.motionId),rect:el.getBoundingClientRect()}));for(const {el,old,rect}of changes){if(old&&Math.abs(old.top-rect.top)<500)animateElement(el,[{transform:`translate(${old.left-rect.left}px,${old.top-rect.top}px)`},{transform:'translate(0,0)'}]);}}
export function stopMotion(root=document){root.getAnimations?.().forEach(a=>a.cancel());}
document.addEventListener('visibilitychange',()=>{if(document.hidden)stopMotion();});
