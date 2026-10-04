'use strict';
const test=require('node:test');const assert=require('node:assert/strict');
const {developmentConfig,loadConfig,validateConfig,validatePublicKey,main}=require('../scripts/build-config.cjs');
test('development builds contain no credentials and never read their environment',()=>{
 const env=new Proxy({}, {get(){throw new Error('Development read a credential environment value.');}});
 const config=loadConfig({development:true,env,repoRoot:'/does-not-exist'});
 assert.deepEqual(config,{development:true,aiBaseURL:'',aiClientToken:'',supabaseURL:'',supabaseAnonKey:'',redirectURI:'com.froydinger.breeze.test://auth-callback'});
 assert.deepEqual(config,developmentConfig());
});
test('development configuration cannot pass production validation',()=>{assert.throws(()=>validateConfig(developmentConfig()));});
test('development mode rejects live credential/network verification',async()=>{await assert.rejects(main(['--development','--verify-network']),/cannot be combined/);});
test('production build requires explicit existing configuration',()=>{assert.throws(()=>loadConfig({env:{},repoRoot:'/does-not-exist'}),/BREEZE_CLOUD_CLIENT_TOKEN.*BREEZE_CLOUD_SUPABASE_ANON_KEY/);});
test('privileged Supabase keys cannot enter the app build',()=>{assert.throws(()=>validatePublicKey('sb_secret_never_bundle'));const body=Buffer.from(JSON.stringify({role:'service_role',ref:'sbvjjseitpahdpewsqqc'})).toString('base64url');assert.throws(()=>validatePublicKey('eyJ.test'.replace('test',body)+'.signature'),/anon key/);});
