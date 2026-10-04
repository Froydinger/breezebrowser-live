'use strict';
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');

const INTERNAL_PAGES = new Set(['newtab','settings','history','bookmarks','downloads','passwords','onboarding','updates']);
const DEFAULTS = Object.freeze({theme:'system',accent:'#3aa6b9',pinSize:'large',searchEngine:'spectra',urlBarPosition:'top',newTabInputMode:'ask',clock24:false,showGreeting:true,newTabSuggestions:true,userName:'',adblockEnabled:true,adblockMode:'on',adblockSiteExceptions:[],restoreTabs:'ask',webNotifications:true,tabSleepHours:1,maxLiveTabs:12,keepPinnedAppsAwake:true,aiInstructions:'',aiIncludeHistory:false,aiIncludeBookmarks:false,aiIncludeOpenTabs:false,aiUseChatHistory:true,hasOnboarded:false,permissions:{},reminders:[]});
const BOOLEAN_SETTINGS = new Set(['clock24','showGreeting','newTabSuggestions','adblockEnabled','webNotifications','keepPinnedAppsAwake','aiIncludeHistory','aiIncludeBookmarks','aiIncludeOpenTabs','aiUseChatHistory','hasOnboarded','hideNavTips','pluginCreatorTools']);
const ENUM_SETTINGS = {theme:['system','dark','light'],searchEngine:['spectra','duckduckgo','bing','brave','google'],urlBarPosition:['top','sidebar'],pinSize:['small','medium','large'],restoreTabs:['ask','always','never'],adblockMode:['off','on','advanced'],newTabInputMode:['ask','search']};
function id(){ return crypto.randomUUID(); }
function clone(value){ return value === undefined ? undefined : JSON.parse(JSON.stringify(value)); }
function safeString(value,max=4096){ return typeof value === 'string' ? value.slice(0,max) : ''; }
function searchURL(query, engine='spectra'){
  const bases={spectra:'https://spectrasearch.info/search?q=',duckduckgo:'https://duckduckgo.com/?q=',bing:'https://www.bing.com/search?q=',brave:'https://search.brave.com/search?q=',google:'https://www.google.com/search?q='};
  return (bases[engine]||bases.spectra)+encodeURIComponent(safeString(query,4000).trim());
}
function webURL(value){ try { const u=new URL(value);return (u.protocol==='https:'||u.protocol==='http:')&&!u.username&&!u.password ? u.href : null; } catch { return null; } }
function originOf(value){ try{return new URL(value).origin;}catch{return '';} }
function navigateInput(value,engine='spectra'){
  const input=safeString(value,8192).trim();
  if(!input) return {page:'newtab',url:'breeze://newtab'};
  if(input.startsWith('breeze://')){const page=input.slice(9).split(/[/?#]/)[0];if(!INTERNAL_PAGES.has(page))throw new Error('Unknown Breeze page.');return {page,url:'breeze://'+page};}
  // Explicit schemes are never converted into executable URLs or searched back to the network.
  if(/^[a-z][a-z0-9+.-]*:/i.test(input)&&!/^[^\s/:]+:\d+(?:\/|$)/.test(input)){
    const url=webURL(input);if(!url) throw new Error('Only HTTP and HTTPS web addresses are supported.');return {url,page:null};
  }
  if(!/\s/.test(input)&&(/^(localhost|(?:\d{1,3}\.){3}\d{1,3})(:\d+)?(?:[/?#]|$)/i.test(input)||/^(?:[^\s./]+\.)+[^\s./]{2,}(?::\d+)?(?:[/?#]|$)/.test(input))){
    const local=/^(localhost|127\.0\.0\.1)(:\d+)?(?:[/?#]|$)/i.test(input);
    const url=webURL((local?'http://':'https://')+input);if(url)return {url,page:null};
  }
  return {url:searchURL(input,engine),page:null};
}
function sanitizeSettings(patch){
  if(!patch||typeof patch!=='object'||Array.isArray(patch))throw new Error('Invalid settings.');
  const result={};
  for(const [key,value] of Object.entries(patch)){
    if(BOOLEAN_SETTINGS.has(key)){if(typeof value!=='boolean')throw new Error('Invalid setting: '+key);result[key]=value;}
    else if(ENUM_SETTINGS[key]){if(!ENUM_SETTINGS[key].includes(value))throw new Error('Invalid setting: '+key);result[key]=value;}
    else if(key==='userName'||key==='aiInstructions')result[key]=safeString(value,key==='userName'?120:6000);
    else if(key==='maxLiveTabs'||key==='tabSleepHours'){const n=Number(value);if(!Number.isFinite(n)||n<0||n>168)throw new Error('Invalid setting: '+key);result[key]=n;}
    else if(key==='adblockSiteExceptions'){if(!Array.isArray(value))throw new Error('Invalid sites.');result[key]=value.map(v=>safeString(v,253).trim().toLowerCase()).filter(v=>/^[a-z0-9.-]+$/.test(v)).slice(0,500);}
    else throw new Error('Unsupported setting: '+key);
  }
  return result;
}
class Store {
  constructor(directory){
    this.directory=directory;this.file=path.join(directory,'profile.json');this.listeners=new Set();
    fs.mkdirSync(directory,{recursive:true,mode:0o700});let saved={};
    try{saved=JSON.parse(fs.readFileSync(this.file,'utf8'));if(!saved||Array.isArray(saved)||typeof saved!=='object')saved={};}catch(e){if(e.code!=='ENOENT'){try{fs.copyFileSync(this.file,this.file+'.unreadable-'+Date.now());}catch{}}}
    this.data={...saved,settings:{...DEFAULTS,...saved.settings}};
    for(const key of ['pins','groups','history','bookmarks','chats','reminders','downloads','openTabs'])if(!Array.isArray(this.data[key]))this.data[key]=[];
    if(!this.data.installId)this.data.installId=id();
  }
  get(key,fallback){return clone(Object.prototype.hasOwnProperty.call(this.data,key)?this.data[key]:fallback);}
  set(key,value){if(typeof key!=='string'||['__proto__','prototype','constructor'].includes(key))throw new Error('Invalid storage key.');this.data[key]=clone(value);this.save();for(const fn of this.listeners)fn(key);}
  updateSettings(patch){const next={...this.data.settings,...sanitizeSettings(patch)};this.set('settings',next);return clone(next);}
  save(){const tmp=this.file+'.tmp';fs.writeFileSync(tmp,JSON.stringify(this.data),{mode:0o600});fs.renameSync(tmp,this.file);}
  subscribe(fn){this.listeners.add(fn);return()=>this.listeners.delete(fn);}
}
function boundedRect(input,windowBounds){
  const number=(v,d=0)=>Number.isFinite(Number(v))?Math.round(Number(v)):d;
  const x=Math.max(0,Math.min(windowBounds.width,number(input?.x)));
  const y=Math.max(42,Math.min(windowBounds.height,number(input?.y,60)));
  return {x,y,width:Math.max(0,Math.min(windowBounds.width-x,number(input?.width))),height:Math.max(0,Math.min(windowBounds.height-y,number(input?.height)))};
}
function metadataTab(tab){const {view,sleepTimer,...data}=tab;return clone(data);}
module.exports={DEFAULTS,INTERNAL_PAGES,Store,id,clone,safeString,searchURL,webURL,originOf,navigateInput,sanitizeSettings,boundedRect,metadataTab};
