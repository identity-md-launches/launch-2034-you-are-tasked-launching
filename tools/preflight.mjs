// Read-only mainnet observation. No account, key, signature, or send method is used.
import { execFileSync } from 'node:child_process';
import { readFileSync, writeFileSync } from 'node:fs';
import { Interface, keccak256 } from '../site/vendor/ethers.min.js';
import { CONFIG } from '../site/config.mjs';
import { factoryHistory, marketCapIMD } from '../site/core.mjs';

const rpcUrl = process.argv[2] || CONFIG.rpcUrl;
let nextId = 1;
function send(method, params) {
  if (!['eth_chainId','eth_blockNumber','eth_getBlockByNumber','eth_getCode','eth_getLogs','eth_call'].includes(method)) {
    throw new Error('This tool only permits read methods.');
  }
  const response = JSON.parse(execFileSync('curl', ['--fail','--silent','--show-error','--max-time','30',
    '-H','Content-Type: application/json','--data-binary',JSON.stringify({jsonrpc:'2.0',id:nextId++,method,params}),rpcUrl], {encoding:'utf8'}));
  if (response.error) throw new Error(JSON.stringify(response.error));
  return response.result;
}
const hexBlock = block => typeof block === 'number' ? '0x'+block.toString(16) : block;
const provider = {
  send: async(method,params)=>send(method,params),
  getCode:async(address,block='latest')=>send('eth_getCode',[address,hexBlock(block)]),
  getBlock:async(block)=>{const b=send('eth_getBlockByNumber',[hexBlock(block),false]);return b&&{...b,number:Number(BigInt(b.number)),timestamp:Number(BigInt(b.timestamp))};},
  getLogs:async(filter)=>send('eth_getLogs',[{...filter,fromBlock:hexBlock(filter.fromBlock),toBlock:hexBlock(filter.toBlock)}])
    .map(log=>({...log,blockNumber:Number(BigInt(log.blockNumber)),index:Number(BigInt(log.logIndex))}))
};
const head = Number(BigInt(send('eth_blockNumber',[])));
const history = await factoryHistory(provider,head);
const snapshot = JSON.parse(readFileSync('test/fixtures/provenance.json','utf8'));
const dependencies = [CONFIG.factory,CONFIG.hook,CONFIG.quoteToken,CONFIG.positionManager,CONFIG.permit2,CONFIG.poolManager,CONFIG.conversionHook];
const hashes = [];
for (const address of dependencies) {
  const codeHash=keccak256(await provider.getCode(address,head));
  const pinned=snapshot.accounts.find(a=>a.address.toLowerCase()===address.toLowerCase());
  if (!pinned || codeHash !== pinned.codeHash) throw new Error(`Unexpected runtime at ${address}`);
  hashes.push({address,codeHash});
}
const abi=new Interface(['function symbol() view returns(string)','function decimals() view returns(uint8)',
  'function protocolFeeRecipient() view returns(address)','function PROTOCOL_FEE_BPS() view returns(uint16)',
  'function implementation() view returns(address)',
  'function externalBases(address) view returns(bool,bool)',
  'function externalBasePool(address) view returns(address,address,uint24,int24,address)']);
function readAll(address,name,args=[]) {return abi.decodeFunctionResult(name,send('eth_call',[{to:address,data:abi.encodeFunctionData(name,args)},hexBlock(head)]));}
function read(address,name) {return readAll(address,name)[0];}
const implementation=read(CONFIG.factory,'implementation');
const implementationHash=keccak256(await provider.getCode(implementation,head));
if(!snapshot.accounts.some(a=>a.address.toLowerCase()===implementation.toLowerCase()&&a.codeHash===implementationHash)) throw new Error('Unexpected implementation');
const observedBlock=await provider.getBlock(head);
const flags=readAll(CONFIG.hook,'externalBases',[CONFIG.quoteToken]);
const route=readAll(CONFIG.hook,'externalBasePool',[CONFIG.quoteToken]);
const result={kind:'read-only-preflight',chainId:1,blockNumber:head,blockHash:observedBlock.hash,
  blockTimestamp:new Date(observedBlock.timestamp*1000).toISOString(),
  factory:CONFIG.factory,history,firstSlotAvailable:(await provider.getCode(CONFIG.firstToken,head))==='0x',
  quote:{address:CONFIG.quoteToken,symbol:read(CONFIG.quoteToken,'symbol'),decimals:Number(read(CONFIG.quoteToken,'decimals'))},
  protocolFee:{bps:Number(read(CONFIG.hook,'PROTOCOL_FEE_BPS')),recipient:read(CONFIG.hook,'protocolFeeRecipient')},
  feeConversion:{flags:Array.from(flags),currency0:route[0],currency1:route[1],fee:Number(route[2]),tickSpacing:Number(route[3]),hook:route[4],
    payoutAsset:'native ETH',protocolShare:'floor(convertedTaxETH * 15 / currentTaxBps); included in token tax'},
  implementation,implementationHash,dependencies:hashes,
  suggestedPriceX18:CONFIG.suggestedPriceX18.toString(),suggestedFDVinIMD:marketCapIMD(CONFIG.suggestedPriceX18),
  fiatReference:CONFIG.quoteObservation,
  projectLaunch:{status:'not-broadcast-by-this-tool',token:null,transactionHash:null},
  caveat:'This observation is not a reservation. Recheck before signing; derive ordinal from the final launch receipt.'};
const output=JSON.stringify(result,null,2)+'\n';
if (process.argv[3]) writeFileSync(process.argv[3],output);
console.log(output);
