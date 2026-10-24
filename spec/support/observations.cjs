// Serialization only: the Ruby runner evaluates every expected value and pattern.
const {createHash}=require('node:crypto');
const observations=[],identities=new WeakMap();let nextIdentity=0;
function normalize(value){
  if(value===undefined)return {type:'undefined'};
  if(typeof value==='string'&&value.length>4096)return {type:'text',length:value.length,sha256:createHash('sha256').update(value).digest('hex')};
  if(value?.nodeType){if(!identities.has(value))identities.set(value,++nextIdentity);return {type:'node',identity:identities.get(value)};}
  if(value===null||typeof value!=='object')return value;
  if(Array.isArray(value))return value.map(normalize);
  return Object.fromEntries(Object.entries(value).map(([key,item])=>[key,normalize(item)]));
}
function observe(id,value){observations.push({id,value:normalize(value)});}
function observeText(id,value){observations.push({id,value});}
function observeIdentity(id,node,reference){observations.push({id,value:{node:normalize(node),reference:normalize(reference)}});}
function attempt(fn){try{fn();return null;}catch(error){return error.message;}}
process.once('beforeExit',()=>{if(observations.length)console.log(JSON.stringify(observations));});
module.exports={observe,observeText,observeIdentity,attempt,normalize};
