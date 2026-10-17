import { getAddress, id, keccak256, parseUnits, formatUnits, Interface, ZeroAddress } from './vendor/ethers.min.js';
import { CONFIG } from './config.mjs';

export const CREATED_TOPIC = id('TokenCreated(address,address,address,address)');
export const LAUNCHED_EVENT = 'event Launched(address indexed token,bytes32 indexed poolId,address indexed owner,uint256 positionId,uint256 requestedPriceX18,bool firstFactoryToken)';
const eventInterface = new Interface([LAUNCHED_EVENT]);
export const sameAddress = (a, b) => typeof a === 'string' && typeof b === 'string' && a.toLowerCase() === b.toLowerCase();

export function validAddress(value) {
  const address = getAddress(value.trim());
  if (address === ZeroAddress) throw new Error('Enter a deployed application address.');
  return address;
}

export function priceFromInput(value) {
  if (!/^(0|[1-9]\d*)(\.\d{1,18})?$/.test(value)) throw new Error('Use a decimal price with at most 18 decimal places.');
  const price = parseUnits(value, 18);
  if (price <= 0n || price > 10n ** 18n) throw new Error('Price must be greater than zero and at most 1 IMD per ERC20T.');
  return price;
}

export function marketCapIMD(priceX18) {
  return formatUnits(priceX18 * 1_000_000_000n, 18);
}

/// The launch cannot be retried, so a slipped decimal point must not reach the wallet.
export function checkPriceBand(priceX18) {
  if (typeof priceX18 !== 'bigint') throw new Error('Price must be an integer X18 value.');
  if (priceX18 < CONFIG.minPriceX18 || priceX18 > CONFIG.maxPriceX18) {
    throw new Error(`Price ${formatUnits(priceX18, 18)} IMD gives an FDV of ${marketCapIMD(priceX18)} IMD, outside the ${marketCapIMD(CONFIG.minPriceX18)} to ${marketCapIMD(CONFIG.maxPriceX18)} IMD band. Check the decimal places; the launch cannot be retried.`);
  }
  return priceX18;
}

export function scheduledTax(elapsedSeconds) {
  const elapsed = Math.max(0, Math.floor(Number(elapsedSeconds)));
  if (!Number.isFinite(elapsed)) throw new Error('Elapsed time must be finite.');
  return Math.max(100, 9900 - Math.floor(elapsed / 60) * 100);
}

export function controllerRuntimeHash(artifact, owner = CONFIG.owner) {
  let runtime = artifact.deployedBytecode.object.replace(/^0x/, '');
  const word = getAddress(owner).slice(2).toLowerCase().padStart(64, '0');
  const groups = Object.values(artifact.deployedBytecode.immutableReferences);
  if (groups.length !== 1 || !groups[0].length) throw new Error('Unexpected controller immutable layout.');
  for (const ref of groups[0]) {
    if (ref.length !== 32) throw new Error('Unexpected owner encoding.');
    runtime = runtime.slice(0, ref.start * 2) + word + runtime.slice((ref.start + 32) * 2);
  }
  return keccak256('0x' + runtime);
}

export async function assertMainnet(provider) {
  if (BigInt(await provider.send('eth_chainId', [])) !== 1n) throw new Error('Switch your wallet to Ethereum mainnet.');
}

export async function verifyController(provider, address, artifact) {
  await assertMainnet(provider);
  const canonical = validAddress(address);
  const code = await provider.getCode(canonical);
  if (code === '0x' || keccak256(code) !== controllerRuntimeHash(artifact)) {
    throw new Error('This address does not match the reviewed ERC20TLaunch application and owner.');
  }
  return canonical;
}

/// Scan the complete range, fail closed on errors, and sort by chain order.
export async function factoryHistory(provider, toBlock, { signal, onProgress = () => {} } = {}) {
  await assertMainnet(provider);
  if (!Number.isSafeInteger(toBlock) || toBlock < CONFIG.factoryDeploymentBlock) throw new Error('Invalid history block.');
  if (keccak256(await provider.getCode(CONFIG.factory, toBlock)) !== CONFIG.factoryCodeHash) {
    throw new Error('Factory bytecode differs from the tested deployment.');
  }
  const before = await provider.getBlock(toBlock);
  if (!before?.hash) throw new Error('History anchor block unavailable.');
  const logs = [];
  for (let fromBlock = CONFIG.factoryDeploymentBlock; fromBlock <= toBlock; fromBlock += 2000) {
    if (signal?.aborted) throw new Error('History scan cancelled.');
    const end = Math.min(fromBlock + 1999, toBlock);
    logs.push(...await provider.getLogs({ address: CONFIG.factory, topics: [CREATED_TOPIC], fromBlock, toBlock: end }));
    onProgress(end);
  }
  const after = await provider.getBlock(toBlock);
  if (before.hash !== after?.hash) throw new Error('Chain reorganized during the scan. Refresh and try again.');
  const unique = new Map();
  for (const log of logs) {
    if (log.removed || !sameAddress(log.address, CONFIG.factory) || log.topics[0] !== CREATED_TOPIC
      || log.topics.length !== 4 || log.blockNumber < CONFIG.factoryDeploymentBlock || log.blockNumber > toBlock) {
      throw new Error('Inconsistent factory log returned by RPC.');
    }
    unique.set(`${log.transactionHash}:${log.index}`, log);
  }
  const sorted = [...unique.values()].sort((a, b) => a.blockNumber - b.blockNumber || a.index - b.index);
  // Runtime and observed receipts establish topic[1] is token; explorer labels are not used.
  return { blockNumber: toBlock, blockHash: before.hash, count: sorted.length,
    tokens: sorted.map(log => ({ token: getAddress('0x' + log.topics[1].slice(-40)),
      transactionHash: log.transactionHash, blockNumber: log.blockNumber, index: log.index })) };
}

export function parseLaunchReceipt(receipt, controller) {
  if (!receipt || Number(receipt.status) !== 1 || !sameAddress(receipt.to, controller)) throw new Error('No successful application launch receipt.');
  const events = receipt.logs.filter(log => sameAddress(log.address, controller)).flatMap(log => {
    try { const parsed = eventInterface.parseLog(log); return parsed?.name === 'Launched' ? [parsed] : []; } catch { return []; }
  });
  if (events.length !== 1) throw new Error('Receipt must contain exactly one application launch event.');
  const args = events[0].args;
  if (!sameAddress(args.owner, CONFIG.owner) || args.token === ZeroAddress || args.positionId === 0n) throw new Error('Launch receipt parameters do not match this project.');
  return { token: args.token, owner: args.owner, poolId: args.poolId, positionId: args.positionId,
    requestedPriceX18: args.requestedPriceX18, wasFirst: args.firstFactoryToken,
    transactionHash: receipt.hash, blockNumber: receipt.blockNumber };
}

export function launchOrdinal(history, evidence) {
  const matches = history.tokens.filter(x => sameAddress(x.token, evidence.token) && x.transactionHash === evidence.transactionHash);
  if (matches.length !== 1 || history.blockNumber < evidence.blockNumber) throw new Error('Launch is absent from complete factory history.');
  return history.tokens.indexOf(matches[0]) + 1;
}

export function explorerAddress(address) { return `https://etherscan.io/address/${validAddress(address)}`; }
export function explorerTransaction(hash) {
  if (!/^0x[0-9a-fA-F]{64}$/.test(hash)) throw new Error('Invalid transaction hash.');
  return `https://etherscan.io/tx/${hash}`;
}
