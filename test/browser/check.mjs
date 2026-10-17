// Optional browser integration check. Supply a Chromium executable as argv[2].
// Uses CDP over pipes; all page and RPC requests are fulfilled locally. No network,
// real wallet, account credentials, mainnet writes, npm packages or signing keys.
import assert from 'node:assert/strict';
import path from 'node:path';
import {spawn} from 'node:child_process';
import {readFile,writeFile,mkdir} from 'node:fs/promises';
import {Interface,getCreateAddress,zeroPadValue} from '../../site/vendor/ethers.min.js';
import {CONFIG,TOKEN_ABI} from '../../site/config.mjs';
import {CREATED_TOPIC} from '../../site/core.mjs';

if(!process.argv[2]) throw new Error('Usage: node test/browser/check.mjs /path/to/chromium');
const root=path.resolve('site'), scratch=path.resolve('test/scratch/browser-check');
await mkdir(scratch,{recursive:true});
const artifact=JSON.parse(await readFile('site/abi/ERC20TLaunch.json','utf8'));
const appInterface=new Interface(artifact.abi);
let runtime=artifact.deployedBytecode.object.replace(/^0x/,'');
for(const refs of Object.values(artifact.deployedBytecode.immutableReferences)) for(const ref of refs) {
  runtime=runtime.slice(0,ref.start*2)+zeroPadValue(CONFIG.owner,32).slice(2)+runtime.slice((ref.start+ref.length)*2);
}
const fixture=await readFile('test/fixtures/MainnetState.sol','utf8');
const factoryRuntime='0x'+fixture.match(new RegExp(`vm\\.etch\\(\\s*${CONFIG.factory}\\s*,\\s*hex"([a-f0-9]+)"\\s*\\)`))[1];
const controller=getCreateAddress({from:CONFIG.owner,nonce:9});
const simulatedToken=getCreateAddress({from:CONFIG.factory,nonce:99});
const poolId='0x'+'56'.repeat(32);
const event=appInterface.encodeEventLog(appInterface.getEvent('Launched'),[simulatedToken,poolId,CONFIG.owner,123,CONFIG.suggestedPriceX18,false]);
const responses={};
const tokenInterface=new Interface(TOKEN_ABI);
for(const [name,value] of Object.entries({name:'erc20t',symbol:'ERC20T',totalSupply:CONFIG.supply,taxBps:100,restingTaxBps:100,owner:CONFIG.owner,feeRecipient:CONFIG.owner,feeDecayRecipient:CONFIG.owner}))
  responses[tokenInterface.getFunction(name).selector]=tokenInterface.encodeFunctionResult(name,[value]);
for(const [name,value] of Object.entries({token:simulatedToken,poolId,positionId:123,launchBlock:CONFIG.factoryDeploymentBlock+36}))
  responses[appInterface.getFunction(name).selector]=appInterface.encodeFunctionResult(name,[value]);
const hookInterface=new Interface(['function protocolFeeRecipient() view returns(address)']);
responses[hookInterface.getFunction('protocolFeeRecipient').selector]=hookInterface.encodeFunctionResult('protocolFeeRecipient',[CONFIG.owner]);
const mockData={simulatedToken,poolId,event,responses,launchBlock:CONFIG.factoryDeploymentBlock+36,owner:CONFIG.owner,controller,factory:CONFIG.factory,first:CONFIG.firstToken,
  firstBlock:CONFIG.factoryDeploymentBlock+1,head:CONFIG.factoryDeploymentBlock+40,
  code:'0x'+runtime,factoryCode:factoryRuntime,createdTopic:CREATED_TOPIC,
  ownerResult:appInterface.encodeFunctionResult('owner',[CONFIG.owner]),
  statusResult:appInterface.encodeFunctionResult('status',[0]),
  launchResult:appInterface.encodeFunctionResult('launch',[getCreateAddress({from:CONFIG.factory,nonce:99})]),
  ownerSelector:appInterface.getFunction('owner').selector,statusSelector:appInterface.getFunction('status').selector,
  launchSelector:appInterface.getFunction('launch').selector};
const mockSource=`{
const d=${JSON.stringify(mockData)};
const pad=a=>'0x'+a.slice(2).toLowerCase().padStart(64,'0');
const hex=n=>'0x'+Number(n).toString(16);
const blockHash='0x'+'12'.repeat(32),txHash='0x'+'34'.repeat(32);
window.__wallet={chain:'0xa',account:d.owner,requests:[],badCode:false,listeners:{},launched:false,head:d.head};
const log=(address,number,topics,data,index)=>({address,blockNumber:hex(number),blockHash,transactionHash:txHash,transactionIndex:'0x0',logIndex:hex(index),removed:false,data,topics});
const creation=(token,number,index)=>log(d.factory,number,[d.createdTopic,pad(token),pad(d.factory),pad(d.owner)],pad(d.owner),index);
const launchLog=()=>log(d.controller,d.launchBlock,d.event.topics,d.event.data,2);
window.__mockRpc=async(method,params=[])=>{
 const w=window.__wallet;w.requests.push({method,params});
 switch(method){
 case 'eth_chainId':return w.chain;
 case 'eth_requestAccounts':case 'eth_accounts':return [w.account];
 case 'wallet_switchEthereumChain':w.chain=params[0].chainId;(w.listeners.chainChanged||[]).forEach(f=>f(w.chain));return null;
 case 'eth_getCode':return params[0].toLowerCase()===d.factory.toLowerCase()?d.factoryCode:(w.badCode?'0x00':d.code);
 case 'eth_blockNumber':return hex(w.head);
 case 'eth_getBlockByNumber':{const number=params[0]==='latest'?w.head:Number(BigInt(params[0]));return {hash:blockHash,parentHash:txHash,number:hex(number),timestamp:'0x6ad10000',nonce:'0x0000000000000000',difficulty:'0x0',gasLimit:'0x1c9c380',gasUsed:'0x100000',miner:d.owner,extraData:'0x',baseFeePerGas:'0x1',transactions:[]};}
 case 'eth_getLogs':{const f=params[0],logs=[creation(d.first,d.firstBlock,0),...(w.launched?[creation(d.simulatedToken,d.launchBlock,1),launchLog()]:[])];return logs.filter(l=>l.address.toLowerCase()===f.address.toLowerCase()&&l.topics[0]===f.topics[0]&&Number(BigInt(l.blockNumber))>=Number(BigInt(f.fromBlock))&&Number(BigInt(l.blockNumber))<=Number(BigInt(f.toBlock)));}
 case 'eth_getTransactionReceipt':return {to:d.controller,from:d.owner,contractAddress:null,transactionIndex:'0x0',gasUsed:'0x100000',cumulativeGasUsed:'0x100000',logsBloom:'0x'+'00'.repeat(256),blockHash:w.reorg?txHash:blockHash,transactionHash:txHash,logs:[launchLog()],blockNumber:hex(d.launchBlock),effectiveGasPrice:'0x1',type:'0x2',status:'0x1'};
 case 'wallet_watchAsset':return true;
 case 'eth_call':{const selector=params[0].data.slice(0,10);if(selector===d.ownerSelector)return d.ownerResult;if(selector===d.statusSelector)return w.launched?pad('0x2'):d.statusResult;if(selector===d.launchSelector)return d.launchResult;if(d.responses[selector])return d.responses[selector];throw Error('Unexpected call '+selector);}
 case 'eth_estimateGas':return '0x120000';
 case 'eth_getTransactionCount':return '0x0';
 case 'eth_gasPrice':case 'eth_maxPriorityFeePerGas':return '0x1';
 case 'eth_sendTransaction':w.lastSend=params[0];throw Object.assign(Error('Test wallet declined'),{code:4001});
 default:throw Error('Unexpected wallet method '+method);
 }
};
window.ethereum={request:({method,params})=>window.__mockRpc(method,params),on:(name,fn)=>(window.__wallet.listeners[name]||=[]).push(fn)};
}`;

const browser=spawn(path.resolve(process.argv[2]),['--headless','--no-sandbox','--disable-gpu','--disable-dev-shm-usage',
  '--disable-background-networking','--disable-crash-reporter','--no-first-run',
  '--user-data-dir='+path.join(scratch,'profile'),'--remote-debugging-pipe','about:blank'],
  {env:{TMPDIR:scratch},stdio:['ignore','ignore','pipe','pipe','pipe']});
const waiting=new Map(),errors=[];let sequence=0,buffer='';
const send=(method,params={},sessionId)=>new Promise((resolve,reject)=>{
  const id=++sequence;waiting.set(id,{resolve,reject});
  browser.stdio[3].write(JSON.stringify({id,method,params,...(sessionId?{sessionId}:{})})+'\0');
});
browser.stdio[4].on('data',chunk=>{
  buffer+=chunk.toString();let i;
  while((i=buffer.indexOf('\0'))>=0){const raw=buffer.slice(0,i);buffer=buffer.slice(i+1);if(!raw)continue;
    const message=JSON.parse(raw);
    if(message.id){const p=waiting.get(message.id);waiting.delete(message.id);message.error?p?.reject(Error(JSON.stringify(message.error))):p?.resolve(message.result);}
    else if(message.method==='Fetch.requestPaused') fulfill(message.sessionId,message.params).catch(e=>errors.push(e.message));
    else if(message.method==='Runtime.exceptionThrown')errors.push(message.params.exceptionDetails.exception?.description||message.params.exceptionDetails.text);
  }
});
browser.on('exit',code=>{for(const p of waiting.values())p.reject(Error('Browser exited '+code));waiting.clear();});
const mime={'.html':'text/html','.mjs':'text/javascript','.js':'text/javascript','.css':'text/css','.json':'application/json','.ttf':'font/ttf','.svg':'image/svg+xml'};
async function fulfill(sessionId,event){
  const url=new URL(event.request.url);let body,type='application/json';
  if(event.request.method==='OPTIONS'){
    await send('Fetch.fulfillRequest',{requestId:event.requestId,responseCode:204,responseHeaders:[
      {name:'Access-Control-Allow-Origin',value:'*'},{name:'Access-Control-Allow-Methods',value:'POST, GET, OPTIONS'},
      {name:'Access-Control-Allow-Headers',value:'content-type'}]},sessionId);return;
  }
  if(url.hostname==='erc20t.test'){
    const file=path.resolve(root,'.'+url.pathname+(url.pathname.endsWith('/')?'index.html':''));
    if(!file.startsWith(root+path.sep))throw Error('Invalid asset path');
    body=await readFile(file);type=mime[path.extname(file)]||'application/octet-stream';
  }else if(url.href.startsWith(CONFIG.rpcUrl)){
    const requests=JSON.parse(event.request.postData),batch=Array.isArray(requests)?requests:[requests];
    const answers=[];
    for(const request of batch){const result=await send('Runtime.evaluate',{expression:`window.__mockRpc(${JSON.stringify(request.method)},${JSON.stringify(request.params)})`,awaitPromise:true,returnByValue:true},sessionId);
      if(result.exceptionDetails)throw Error(JSON.stringify(result.exceptionDetails));
      answers.push({jsonrpc:'2.0',id:request.id,result:result.result.value});}
    body=Buffer.from(JSON.stringify(Array.isArray(requests)?answers:answers[0]));
  }else throw Error('Unexpected external request '+url.origin);
  await send('Fetch.fulfillRequest',{requestId:event.requestId,responseCode:200,
    responseHeaders:[{name:'Content-Type',value:type},{name:'Access-Control-Allow-Origin',value:'*'}],body:body.toString('base64')},sessionId);
}
try{
  const {targetId}=await send('Target.createTarget',{url:'about:blank'});
  const {sessionId}=await send('Target.attachToTarget',{targetId,flatten:true});
  const call=(method,params)=>send(method,params,sessionId);
  const evaluate=async expression=>{const result=await call('Runtime.evaluate',{expression,awaitPromise:true,returnByValue:true});
    if(result.exceptionDetails)throw Error(JSON.stringify(result.exceptionDetails));return result.result.value;};
  const until=expression=>evaluate(`new Promise((resolve,reject)=>{let n=0;const check=()=>{if(${expression})resolve(true);else if(++n>200)reject(Error('Timed out: '+${JSON.stringify(expression)}));else setTimeout(check,25)};check()})`).catch(async error=>{
    console.error('Page diagnostics',await evaluate(`({controller:document.querySelector('#controller-help')?.textContent,launch:document.querySelector('#launch-feedback')?.textContent,requests:window.__wallet.requests.map(r=>r.method).slice(-12)})`),errors);throw error;
  });
  const click=id=>evaluate(`document.getElementById(${JSON.stringify(id)}).click()`);
  await call('Page.enable');await call('Runtime.enable');await call('Fetch.enable',{patterns:[{urlPattern:'*'}]});
  await call('Emulation.setEmulatedMedia',{features:[{name:'prefers-reduced-motion',value:'reduce'}]});
  await call('Emulation.setDeviceMetricsOverride',{width:1440,height:1000,deviceScaleFactor:1,mobile:false});
  await call('Page.addScriptToEvaluateOnNewDocument',{source:mockSource});
  await call('Page.navigate',{url:'http://erc20t.test/'});
  await until(`document.readyState==='complete' && document.querySelector('#contracts')?.children.length===6`);
  await evaluate('document.fonts.ready');
  await writeFile(path.join(scratch,'desktop.png'),Buffer.from((await call('Page.captureScreenshot',{format:'png',captureBeyondViewport:false})).data,'base64'));
  await click('connect');await until(`document.querySelector('#connect').textContent.includes('Switch to mainnet')`);
  await click('connect');await until(`document.querySelector('#launch-feedback').textContent.includes('Owner wallet connected')`);
  await evaluate(`document.querySelector('#controller').value=${JSON.stringify(controller)};document.querySelector('#controller').dispatchEvent(new Event('input',{bubbles:true}));`);
  await click('load-controller');await until(`document.querySelector('#controller-help').textContent.includes('Verified bytecode')`);
  await until(`!document.querySelector('#load-controller').disabled`);
  await evaluate('window.__wallet.badCode=true');await click('load-controller');
  await until(`document.querySelector('#controller-help').textContent.includes('does not match')`);
  await evaluate('window.__wallet.badCode=false');
  await click('review');await until(`document.querySelector('#launch-feedback').textContent.includes('already exist')`);
  assert.equal(await evaluate(`window.__wallet.requests.filter(r=>r.method==='eth_sendTransaction').length`),0);
  await click('allow-prior');await click('review');await until(`document.querySelector('#review-dialog').open`);
  assert.equal(await evaluate(`window.__wallet.requests.filter(r=>r.method==='eth_sendTransaction').length`),0);
  await writeFile(path.join(scratch,'review.png'),Buffer.from((await call('Page.captureScreenshot',{format:'png',captureBeyondViewport:false})).data,'base64'));
  // Changing a reviewed parameter invalidates the review without submitting anything.
  await evaluate(`document.querySelector('#price').value='0.0000006';document.querySelector('#price').dispatchEvent(new Event('input',{bubbles:true}))`);
  assert.equal(await evaluate(`document.querySelector('#review-dialog').open`),false);
  await click('review');await until(`document.querySelector('#review-dialog').open`);
  // An account change while reviewing also invalidates the pending transaction.
  await evaluate(`window.__wallet.account=${JSON.stringify(CONFIG.firstToken)};window.__wallet.listeners.accountsChanged.forEach(f=>f([window.__wallet.account]));`);
  assert.equal(await evaluate(`document.querySelector('#review-dialog').open`),false);
  await click('review');await until(`document.querySelector('#launch-feedback').textContent.includes('designated owner wallet')`);
  await evaluate(`window.__wallet.account=${JSON.stringify(CONFIG.owner)}`);await click('connect');
  await until(`document.querySelector('#launch-feedback').textContent.includes('Owner wallet connected')`);
  await click('review');await until(`document.querySelector('#review-dialog').open`);
  await click('send-launch');await until(`document.querySelector('#send-status').textContent.includes('declined')`);
  const tx=await evaluate('window.__wallet.lastSend');
  assert.equal(tx.to.toLowerCase(),controller.toLowerCase());assert.equal(tx.chainId,'0x1');
  assert.equal(tx.from.toLowerCase(),CONFIG.owner.toLowerCase());assert.equal(tx.data.slice(0,10),mockData.launchSelector);
  assert.equal(await evaluate(`window.__wallet.requests.filter(r=>r.method==='eth_sendTransaction').length`),1);
  assert.equal(await evaluate(`document.querySelector('#trade').hasAttribute('href')`),false);
  await click('close-dialog');
  await evaluate(`document.querySelector('#toast').hidden=true;document.querySelector('#proof').scrollIntoView({behavior:'instant'})`);
  await writeFile(path.join(scratch,'proof.png'),Buffer.from((await call('Page.captureScreenshot',{format:'png',captureBeyondViewport:false})).data,'base64'));
  await evaluate(`document.querySelector('#launch').scrollIntoView({behavior:'instant'})`);
  await writeFile(path.join(scratch,'launch.png'),Buffer.from((await call('Page.captureScreenshot',{format:'png',captureBeyondViewport:false})).data,'base64'));
  for(const width of [390,768,1440]){
    await call('Emulation.setDeviceMetricsOverride',{width,height:844,deviceScaleFactor:1,mobile:width<600});
    await evaluate(`window.scrollTo({top:0,behavior:'instant'});document.fonts.ready`);
    assert.ok(await evaluate('document.documentElement.scrollWidth<=innerWidth'),`Horizontal overflow at ${width}`);
    if(width===390)await writeFile(path.join(scratch,'mobile.png'),Buffer.from((await call('Page.captureScreenshot',{format:'png',captureBeyondViewport:false})).data,'base64'));
  }
  // Recover a launch made elsewhere; five confirmations must not enable trading.
  await evaluate('window.__wallet.launched=true');await click('refresh');
  await until(`document.querySelector('#proof-status').textContent==='5/12 CONFIRMATIONS'`);
  await until(`!document.querySelector('#refresh').disabled`);
  assert.equal(await evaluate(`document.querySelector('#trade').hasAttribute('href')`),false);
  assert.equal(await evaluate(`document.querySelector('#token-address').textContent`),simulatedToken);
  assert.equal(await evaluate(`document.querySelector('#launch-order').textContent`),'#2 · verified factory history');
  await evaluate('window.__wallet.head+=10');await click('refresh');
  await until(`document.querySelector('#proof-status').textContent==='CONFIRMED'`);
  await until(`!document.querySelector('#refresh').disabled`);
  assert.ok((await evaluate(`document.querySelector('#trade').href`)).includes(simulatedToken));
  assert.equal(await evaluate(`document.querySelector('#download-proof').disabled`),false);
  await click('watch-token');await until(`document.querySelector('#toast').textContent==='Token added to your wallet'`);
  await evaluate(`document.querySelector('#toast').hidden=true;document.querySelector('#proof').scrollIntoView({behavior:'instant'})`);
  await writeFile(path.join(scratch,'confirmed.png'),Buffer.from((await call('Page.captureScreenshot',{format:'png',captureBeyondViewport:false})).data,'base64'));
  // A changed canonical receipt must suspend all proof-based actions.
  await evaluate('window.__wallet.reorg=true');await click('refresh');
  await until(`document.querySelector('#proof-status').textContent==='UNVERIFIED SNAPSHOT'`);
  assert.equal(await evaluate(`document.querySelector('#trade').hasAttribute('href')`),false);
  assert.equal(await evaluate(`document.querySelector('#watch-token').disabled`),true);
  assert.equal(await evaluate(`document.querySelector('#download-proof').disabled`),true);
  assert.deepEqual(errors,[]);
  console.log('Browser checks passed: network switch, runtime verification, first-only rejection, owner check, simulation, stale review invalidation, explicit chain-1 signing request, rejection recovery, responsive layout, mined/confirmed receipt recovery, factory ordinal, token import, reorg fail-closed handling.');
  await send('Browser.close');
}finally{browser.kill();}
