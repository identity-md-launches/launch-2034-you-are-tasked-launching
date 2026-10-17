// Optional, read-only research tool. Never signs or sends a transaction.
// Run from the repository root with a public Ethereum RPC URL argument.
import { execFileSync } from 'node:child_process';
import { writeFileSync, readFileSync, mkdirSync } from 'node:fs';
import { Interface, getAddress, keccak256, getCreateAddress, toBeHex, zeroPadValue } from '../site/vendor/ethers.min.js';

const rpcUrl = process.argv[2] || 'https://ethereum-rpc.publicnode.com';
function rpc(method, params) {
  const result = JSON.parse(execFileSync('curl', ['--fail', '-sS', '--max-time', '30',
    '-H', 'Content-Type: application/json', '--data-binary',
    JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }), rpcUrl], { encoding: 'utf8' }));
  if (result.error) throw new Error(JSON.stringify(result.error));
  return result.result;
}
const owner = '0x3d6a89c8751a45dd577a4c1f3b34e71c58236193';
const factory = '0x801411c6acec4fa80c75c5d3c0eae13c84f8a173';
const hook = '0xed9a04fa6693e754661a22502524df9b1857e544';
const quote = '0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7';
const positionManager = '0xbd216513d74c8cf14cf4747e6aaa6420ff64ee9e';
const permit2 = '0x000000000022d473030f116ddee9f6b43ac78ba3';
const abi = new Interface(['function createAndLaunchAtPrice((string,string,uint256,uint256,address,address,address,address,address,uint16,address,uint16,uint32,address),uint16,uint256) payable returns(address)']);
const data = abi.encodeFunctionData('createAndLaunchAtPrice', [
  ['erc20t', 'ERC20T', 10n ** 27n, 95n * 10n ** 25n, owner, hook, quote,
    positionManager, permit2, 100, owner, 9900, 60, owner], 500, 540_540_540_540n
]);
if (rpc('eth_chainId', []) !== '0x1') throw new Error('Ethereum mainnet required');
const blockNumber = rpc('eth_blockNumber', []);
const block = rpc('eth_getBlockByNumber', [blockNumber, false]);
const call = { from: owner, to: factory, data, gas: '0xf00000' };
const simulation = rpc('eth_call', [call, blockNumber]);
const access = rpc('eth_createAccessList', [call, blockNumber]);
if (access.error) throw new Error(access.error);
// Launch does not read the hook's mutable protocol-fee recipient, but swaps do.
// Capture this real mainnet slot as well, instead of substituting a recipient in tests.
function includeAccess(transaction, overrides) {
  const extra = rpc('eth_createAccessList', [transaction, blockNumber, ...(overrides ? [overrides] : [])]);
  if (extra.error) throw new Error(extra.error);
  for (const entry of extra.accessList) {
    const existing = access.accessList.find(x => x.address.toLowerCase() === entry.address.toLowerCase());
    if (existing) existing.storageKeys = [...new Set([...existing.storageKeys, ...entry.storageKeys])];
    else access.accessList.push(entry);
  }
}
includeAccess({from:owner,to:hook,data:'0x64df049e'});
// Fee-taking during swap borrows from the singleton's existing quote inventory,
// which the caller settles before unlock returns. Capture the actual inventory
// and transfer-path state; never seed a fictional pool reserve in the fixture.
const protocolRecipient = '0x'+rpc('eth_call', [{to:hook,data:'0x64df049e'},blockNumber]).slice(-40);
const poolManager = '0x000000000004444c5dc75cb358380d2e3de08a90';
const erc20 = new Interface(['function balanceOf(address) view returns(uint256)','function transfer(address,uint256) returns(bool)']);
includeAccess({from:owner,to:quote,data:erc20.encodeFunctionData('balanceOf',[poolManager])});
for (const recipient of [owner,protocolRecipient]) {
  includeAccess({from:poolManager,to:quote,data:erc20.encodeFunctionData('transfer',[recipient,1])});
}
// Read-only state overrides install a test probe and give it 100 simulated IMD.
// This discovers all fee-conversion dependencies (including the existing IMD/ETH
// pool and its hook) by performing a real launch, buy, and sell under eth_call.
// The fixture below still reads ORIGINAL mainnet state, never the overrides.
// Foundry may rewrite test contract creation to cheatcodes by default. The RPC
// probe must use ordinary EVM CREATE bytecode, so compile it without that rewrite.
execFileSync('forge',['build','test/helpers/LaunchAndTradeProbe.sol','--no-dynamic-test-linking',
  '--out','test/scratch/probe-out','--cache-path','test/scratch/probe-cache'],{stdio:'pipe'});
const probe = JSON.parse(readFileSync('test/scratch/probe-out/LaunchAndTradeProbe.sol/LaunchAndTradeProbe.json','utf8'));
if (Object.keys(probe.deployedBytecode.immutableReferences || {}).length) throw new Error('Probe cannot have immutables');
const balanceAccess = rpc('eth_createAccessList', [{from:owner,to:quote,data:erc20.encodeFunctionData('balanceOf',[owner])},blockNumber]);
const balanceSlots = balanceAccess.accessList.find(x=>x.address.toLowerCase()===quote).storageKeys;
if (balanceSlots.length !== 1) throw new Error('Ambiguous IMD balance storage slot');
const overrides = {[owner]:{code:probe.deployedBytecode.object},[quote]:{stateDiff:{[balanceSlots[0]]:zeroPadValue(toBeHex(100n*10n**18n),32)}}};
const probeAbi = new Interface(['function probe() returns(address token,uint256 bought,uint256 soldFor)']);
const probeCall={from:owner,to:owner,data:probeAbi.encodeFunctionData('probe'),gas:'0xf00000'};
const tradeSimulation=probeAbi.decodeFunctionResult('probe',rpc('eth_call',[probeCall,blockNumber,overrides]));
includeAccess(probeCall,overrides);
const firstToken = getCreateAddress({ from: factory, nonce: 2 });
const entries = [...access.accessList];
if (!entries.some(x => x.address.toLowerCase() === firstToken.toLowerCase())) {
  entries.push({ address: firstToken, storageKeys: [] });
}
const accounts = entries.map(entry => {
  const address = getAddress(entry.address);
  return { address, code: rpc('eth_getCode', [address, blockNumber]),
    nonce: Number(BigInt(rpc('eth_getTransactionCount', [address, blockNumber]))),
    balance: rpc('eth_getBalance', [address, blockNumber]),
    storage: entry.storageKeys.map(key => [key, rpc('eth_getStorageAt', [address, key, blockNumber])]) };
});
const lines = ['// SPDX-License-Identifier: UNLICENSED', 'pragma solidity 0.8.26;',
  'import {Test} from "forge-std/Test.sol";',
  '// Mainnet runtime bytecode and access-list state, NOT replacement implementations.',
  `// Block ${Number(BigInt(blockNumber))}, hash ${block.hash}. See docs/EVIDENCE.md.`,
  'abstract contract MainnetState is Test {', '    function loadMainnetState() internal {',
  `        vm.chainId(1); vm.roll(${Number(BigInt(blockNumber))}); vm.warp(${Number(BigInt(block.timestamp))});`];
for (const a of accounts) {
  if (a.code !== '0x') lines.push(`        vm.etch(${a.address}, hex"${a.code.slice(2)}");`);
  if (a.nonce) lines.push(`        vm.setNonce(${a.address}, ${a.nonce});`);
  if (BigInt(a.balance)) lines.push(`        vm.deal(${a.address}, ${BigInt(a.balance)});`);
  for (const [key, value] of a.storage) {
    if (BigInt(value)) lines.push(`        vm.store(${a.address}, ${key}, ${value});`);
  }
}
lines.push('    }', '}');
mkdirSync('test/fixtures', { recursive: true });
writeFileSync('test/fixtures/MainnetState.sol', lines.join('\n') + '\n');
const summary = { chainId: 1, blockNumber: Number(BigInt(blockNumber)), blockHash: block.hash,
  timestamp: Number(BigInt(block.timestamp)), source: 'Ethereum JSON-RPC (read-only)', simulation, firstToken,
  tradeSimulation:{token:tradeSimulation.token,bought:tradeSimulation.bought.toString(),soldFor:tradeSimulation.soldFor.toString(),
    note:'eth_call only; probe code and IMD funding were temporary state overrides, not chain writes'},
  accounts: accounts.map(({address,code,nonce,storage}) => ({address,codeHash:keccak256(code),
    codeBytes:(code.length-2)/2,nonce,storageKeys:storage.length})) };
writeFileSync('test/fixtures/provenance.json', JSON.stringify(summary, null, 2) + '\n');
console.log(JSON.stringify(summary, null, 2));
