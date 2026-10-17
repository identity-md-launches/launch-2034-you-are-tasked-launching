import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, existsSync } from 'node:fs';
import { Interface, keccak256, zeroPadValue, getCreateAddress } from '../../site/vendor/ethers.min.js';
import { CONFIG } from '../../site/config.mjs';
import { CREATED_TOPIC, LAUNCHED_EVENT, controllerRuntimeHash, explorerTransaction, factoryHistory,
  launchOrdinal, marketCapIMD, parseLaunchReceipt, priceFromInput, scheduledTax, validAddress,
  verifyController } from '../../site/core.mjs';

const artifact = JSON.parse(readFileSync('site/abi/ERC20TLaunch.json', 'utf8'));
const controller = getCreateAddress({from:CONFIG.owner, nonce:9});
const txHash = '0x' + '12'.repeat(32), blockHash = '0x' + '34'.repeat(32), poolId = '0x' + '56'.repeat(32);
const block = CONFIG.factoryDeploymentBlock + 4030;

function runtime() {
  let code = artifact.deployedBytecode.object.replace(/^0x/, '');
  for (const refs of Object.values(artifact.deployedBytecode.immutableReferences)) for (const ref of refs) {
    code = code.slice(0, ref.start*2) + zeroPadValue(CONFIG.owner, 32).slice(2) + code.slice((ref.start+ref.length)*2);
  }
  return '0x'+code;
}
function creation(index, height = block, token = CONFIG.firstToken) {
  return { address:CONFIG.factory, blockNumber:height, index, transactionHash:txHash,
    topics:[CREATED_TOPIC,zeroPadValue(token,32),zeroPadValue(CONFIG.factory,32),zeroPadValue(CONFIG.owner,32)], removed:false };
}
function receipt() {
  const iface = new Interface([LAUNCHED_EVENT]);
  const encoded = iface.encodeEventLog(iface.getEvent('Launched'), [CONFIG.firstToken,poolId,CONFIG.owner,123n,CONFIG.suggestedPriceX18,false]);
  return {status:1,to:controller,hash:txHash,blockNumber:block,blockHash,
    logs:[{address:controller,...encoded}]};
}
function historyProvider(logs = []) {
  // The fixture captures the real runtime. No RPC/network is used in tests.
  const text = readFileSync('test/fixtures/MainnetState.sol', 'utf8');
  const pattern = new RegExp(`vm\\.etch\\(\\s*${CONFIG.factory}\\s*,\\s*hex"([a-f0-9]+)"\\s*\\)`);
  const factoryCode = '0x'+text.match(pattern)[1];
  const requests = [];
  return {requests,
    send:async ()=>'0x1', getCode:async()=>factoryCode, getBlock:async()=>({hash:blockHash}),
    getLogs:async filter=>{requests.push(filter);return logs.filter(x=>x.blockNumber>=filter.fromBlock&&x.blockNumber<=filter.toBlock);}
  };
}

test('decimal pricing keeps all 18 digits and derives the IMD valuation exactly', () => {
  assert.equal(priceFromInput('0.00000054054054054'), 540540540540n);
  assert.equal(marketCapIMD(CONFIG.suggestedPriceX18), '540.54054054');
  assert.equal(priceFromInput('0.000000000000000001'),1n);
  assert.equal(priceFromInput('1'),10n**18n);
});
test('rejects unsafe, ambiguous and out-of-range prices', () => {
  for (const p of ['0','-1','1.01','1e-7','NaN','','Infinity','0.0000000000000000001',' 0.1','00.1','0x123','<script>']) {
    assert.throws(()=>priceFromInput(p),undefined,p);
  }
});
test('tax schedule has exact minute transitions and an unbreakable 1% floor', () => {
  for (const [elapsed,bps] of [[-1,9900],[0,9900],[59,9900],[60,9800],[119,9800],[120,9700],[5879,200],[5880,100],[10**12,100]]) {
    assert.equal(scheduledTax(elapsed),bps);
  }
  assert.throws(()=>scheduledTax(NaN));
  assert.throws(()=>scheduledTax(Infinity));
});
test('links reject zero addresses, malformed addresses and injected transaction URLs', () => {
  assert.equal(validAddress(CONFIG.owner),CONFIG.owner);
  assert.throws(()=>validAddress('0x'+'00'.repeat(20)));
  assert.throws(()=>validAddress('javascript:alert(1)'));
  assert.throws(()=>explorerTransaction('javascript:alert(1)'));
  assert.equal(explorerTransaction(txHash),`https://etherscan.io/tx/${txHash}`);
});
test('application runtime verification binds the bytecode to the designated owner', async () => {
  const code=runtime();
  assert.equal(controllerRuntimeHash(artifact),keccak256(code));
  const provider={send:async()=>'0x1',getCode:async()=>code};
  assert.equal(await verifyController(provider,controller,artifact),controller);
  await assert.rejects(verifyController({...provider,send:async()=>'0x2105'},controller,artifact),/mainnet/);
  await assert.rejects(verifyController({...provider,getCode:async()=>'0x'},controller,artifact),/does not match/);
  await assert.rejects(verifyController({...provider,getCode:async()=>code+'00'},controller,artifact),/does not match/);
  assert.notEqual(controllerRuntimeHash(artifact,CONFIG.factory),keccak256(code));
});
test('factory history covers every block with no gaps, counts tokens, orders and deduplicates logs', async () => {
  const a=creation(1,CONFIG.factoryDeploymentBlock+1);
  const b=creation(9,block,CONFIG.quoteToken);
  const provider=historyProvider([b,a,a]);
  const result=await factoryHistory(provider,block);
  assert.equal(result.count,2);assert.equal(result.tokens[0].token,CONFIG.firstToken);
  assert.deepEqual(provider.requests.map(r=>[r.fromBlock,r.toBlock]),[
    [CONFIG.factoryDeploymentBlock,CONFIG.factoryDeploymentBlock+1999],
    [CONFIG.factoryDeploymentBlock+2000,CONFIG.factoryDeploymentBlock+3999],
    [CONFIG.factoryDeploymentBlock+4000,block]
  ]);
});
test('RPC failure never becomes an empty-factory claim', async () => {
  const p=historyProvider();p.getLogs=async()=>{throw new Error('provider unavailable');};
  await assert.rejects(factoryHistory(p,block),/unavailable/);
});
test('a changed factory, wrong chain, removed log or reorganized anchor aborts the scan', async () => {
  const p=historyProvider([creation(1)]);
  await assert.rejects(factoryHistory({...p,getCode:async()=>'0x6000'},block),/bytecode/);
  await assert.rejects(factoryHistory({...p,send:async()=>'0x2'},block),/mainnet/);
  await assert.rejects(factoryHistory(historyProvider([{...creation(1),removed:true}]),block),/Inconsistent/);
  let reads=0;
  await assert.rejects(factoryHistory({...p,getBlock:async()=>({hash:++reads===1?blockHash:txHash})},block),/reorganized/);
});
test('cancellation and invalid block ranges cannot return partial history', async () => {
  const p=historyProvider();
  await assert.rejects(factoryHistory(p,block,{signal:{aborted:true}}),/cancelled/);
  await assert.rejects(factoryHistory(p,CONFIG.factoryDeploymentBlock-1),/Invalid/);
});
test('receipt validation accepts only a successful launch from the exact application', () => {
  const r=receipt(), evidence=parseLaunchReceipt(r,controller);
  assert.equal(evidence.token,CONFIG.firstToken); assert.equal(evidence.positionId,123n);
  assert.equal(evidence.wasFirst,false);
  assert.throws(()=>parseLaunchReceipt({...r,status:0},controller),/successful/);
  assert.throws(()=>parseLaunchReceipt({...r,to:CONFIG.factory},controller),/successful/);
  assert.throws(()=>parseLaunchReceipt({...r,logs:[{...r.logs[0],address:CONFIG.factory}]},controller),/exactly one/);
  assert.throws(()=>parseLaunchReceipt({...r,logs:[...r.logs,...r.logs]},controller),/exactly one/);
});
test('ordinal is derived from matched token and transaction, never from a proposed number', () => {
  const evidence=parseLaunchReceipt(receipt(),controller);
  const history={blockNumber:block,tokens:[{token:CONFIG.quoteToken,transactionHash:txHash},{token:CONFIG.firstToken,transactionHash:txHash}]};
  assert.equal(launchOrdinal(history,evidence),2);
  assert.throws(()=>launchOrdinal({...history,blockNumber:block-1},evidence),/absent/);
  assert.throws(()=>launchOrdinal(history,{...evidence,transactionHash:blockHash}),/absent/);
});
test('shipped deployment configuration contains no fabricated token, controller or receipt', () => {
  const deployment=JSON.parse(readFileSync('site/deployment.json','utf8'));
  assert.equal(deployment.chainId,1);assert.equal(deployment.controller,null);assert.equal(deployment.transactionHash,null);
});
test('all static local links and assets exist without an install or a CDN', () => {
  for (const file of ['site/index.html','site/docs.html']) {
    const html=readFileSync(file,'utf8');
    for (const [,path] of html.matchAll(/(?:src|href)="(\.\/[^"#]+)"/g)) {
      assert.ok(existsSync('site/'+path.slice(2)),`${file} references missing ${path}`);
    }
    assert.ok(html.includes('Content-Security-Policy'));
  }
  const css=readFileSync('site/style.css','utf8');
  for(const [,path] of css.matchAll(/url\('\.\/([^']+)'\)/g)) assert.ok(existsSync('site/'+path));
});
