import { BrowserProvider, Contract, JsonRpcProvider, FetchRequest, formatUnits } from './vendor/ethers.min.js';
import { CONFIG, TOKEN_ABI } from './config.mjs';
import { assertMainnet, factoryHistory, launchOrdinal, parseLaunchReceipt, priceFromInput,
  marketCapIMD, scheduledTax, sameAddress, verifyController, explorerAddress, explorerTransaction } from './core.mjs';

const $ = id => document.getElementById(id);
const state = { artifact: null, deployment: null, controller: null, account: null,
  browser: null, pending: null, epoch: 0, sending: false, evidence: null, switchNeeded: false };
const rpcRequest = new FetchRequest(CONFIG.rpcUrl);
rpcRequest.timeout = 20_000;
const publicProvider = new JsonRpcProvider(rpcRequest, undefined, { cacheTimeout: -1 });
const short = value => `${value.slice(0, 6)}…${value.slice(-4)}`;
const cleanError = error => error.code === 'ACTION_REJECTED' || error.code === 4001
  ? 'Wallet request declined. No new transaction was submitted.'
  : error.shortMessage || error.reason || error.message || 'The request failed. Please retry.';
let toastTimer;
function toast(message) {
  $('toast').textContent = message; $('toast').hidden = false;
  clearTimeout(toastTimer); toastTimer = setTimeout(() => { $('toast').hidden = true; }, 4500);
}
function feedback(id, message, error = false) {
  $(id).textContent = message; $(id).classList.toggle('error', error);
}
function link(text, href) {
  const a = document.createElement('a'); a.textContent = text; a.href = href;
  a.target = '_blank'; a.rel = 'noopener noreferrer'; return a;
}
function evidenceRow(label, value) {
  const row = document.createElement('div'), dt = document.createElement('dt'), dd = document.createElement('dd');
  dt.textContent = label; dd.textContent = value; row.append(dt, dd); return row;
}
function invalidateReview() {
  state.epoch++; state.pending = null;
  if ($('review-dialog').open && !state.sending) $('review-dialog').close();
}

function suspendProofActions() {
  state.evidence = null;
  $('trade').removeAttribute('href'); $('trade').classList.add('disabled'); $('trade').setAttribute('aria-disabled','true');
  $('watch-token').disabled = true; $('download-proof').disabled = true;
  $('proof-status').textContent = 'UNVERIFIED SNAPSHOT'; $('proof-status').classList.remove('live');
  $('hero-status').textContent = 'VERIFICATION NEEDED'; $('hero-status').classList.remove('live');
  $('hero-status-note').textContent = 'Refresh successfully to verify the current chain state.';
}

function resetApplicationDisplay() {
  state.controller = null; state.evidence = null;
  $('hero-status').textContent = 'AWAITING VERIFICATION'; $('hero-status').classList.remove('live');
  $('hero-status-note').textContent = 'Verify the selected application to load its confirmed details.';
  $('proof-status').textContent = 'PENDING'; $('proof-status').classList.remove('live');
  $('launch-headline').textContent = 'The next record is unwritten.';
  $('launch-description').textContent = 'Verify the deployed application address to load a confirmed launch receipt.';
  for (const id of ['token-address','launch-transaction','pool-id','position-id','current-tax','launch-order']) $(id).textContent = 'Not verified';
  for (const id of ['live-owner','live-fee','live-decay','live-resting','live-protocol']) $(id)?.remove();
  $('trade').removeAttribute('href'); $('trade').classList.add('disabled'); $('trade').setAttribute('aria-disabled','true');
  $('watch-token').disabled = true; $('download-proof').disabled = true; $('review').disabled = !state.artifact;
}

$('owner-display').append(link(CONFIG.owner, explorerAddress(CONFIG.owner)));
for (const [label, address] of [['Factory', CONFIG.factory], ['Tax hook', CONFIG.hook], ['IMD quote token', CONFIG.quoteToken],
  ['Position manager', CONFIG.positionManager], ['Permit2', CONFIG.permit2], ['Pool manager', CONFIG.poolManager]]) {
  const row = document.createElement('div'); row.className = 'contract-row';
  const name = document.createElement('span'); name.textContent = label;
  const actions = document.createElement('div');
  const a = link(short(address), explorerAddress(address)); a.title = address; a.setAttribute('aria-label', `${label}: ${address}`);
  const copy = document.createElement('button'); copy.type = 'button'; copy.className = 'copy'; copy.textContent = '⧉';
  copy.setAttribute('aria-label', `Copy ${label} address`);
  copy.addEventListener('click', async () => {
    try { await navigator.clipboard.writeText(address); toast(`${label} address copied`); }
    catch { toast(`Copy unavailable. The explorer link contains the full address.`); }
  });
  actions.append(a, copy); row.append(name, actions); $('contracts').append(row);
}

$('tax-slider').addEventListener('input', event => {
  const minute = Number(event.target.value), tax = scheduledTax(minute * 60) / 100;
  const span = document.createElement('span'); span.textContent = '%';
  $('preview-tax').replaceChildren(document.createTextNode(String(tax)), span);
  $('preview-minute').textContent = String(minute);
  $('chart-cursor').setAttribute('cx', String(25 + minute / 98 * 470));
  $('chart-cursor').setAttribute('cy', String(17 + minute / 98 * 137));
});
$('price').addEventListener('input', () => {
  invalidateReview();
  try { $('fdv').textContent = `${Number(marketCapIMD(priceFromInput($('price').value))).toLocaleString(undefined, { maximumFractionDigits: 6 })} IMD`; }
  catch { $('fdv').textContent = 'Enter a valid price'; }
});
$('allow-prior').addEventListener('change', invalidateReview);
$('controller').addEventListener('input', () => { invalidateReview(); resetApplicationDisplay();
  feedback('controller-help', 'Verify this deployed application address before launching.'); });

async function connectWallet() {
  try {
    if (!window.ethereum?.request) throw new Error('No Ethereum wallet detected. Open this site in a wallet browser or install an EIP-1193 wallet.');
    if (state.switchNeeded) await window.ethereum.request({ method: 'wallet_switchEthereumChain', params: [{ chainId: '0x1' }] });
    const accounts = await window.ethereum.request({ method: 'eth_requestAccounts' });
    if (!accounts.length) throw new Error('No wallet account selected.');
    state.account = accounts[0]; state.browser = new BrowserProvider(window.ethereum);
    const chain = await window.ethereum.request({ method: 'eth_chainId' });
    state.switchNeeded = BigInt(chain) !== 1n;
    $('connect').textContent = state.switchNeeded ? 'Switch to mainnet ↗' : `${short(state.account)} ↗`;
    if (state.switchNeeded) throw new Error('Your wallet is on another network. Use “Switch to mainnet” to continue.');
    feedback('launch-feedback', sameAddress(state.account, CONFIG.owner)
      ? 'Owner wallet connected. Verify the application and review the opening price.'
      : 'Wallet connected for viewing. Only the designated owner can launch.');
  } catch (error) { feedback('launch-feedback', cleanError(error), true); toast(cleanError(error)); }
}
$('connect').addEventListener('click', connectWallet);
if (window.ethereum?.on) {
  window.ethereum.on('accountsChanged', accounts => {
    invalidateReview(); state.account = accounts[0] || null;
    $('connect').textContent = state.account ? `${short(state.account)} ↗` : 'Connect wallet ↗';
    feedback('launch-feedback', 'Wallet account changed. Review and simulate again before signing.');
  });
  window.ethereum.on('chainChanged', chain => {
    invalidateReview(); state.browser = null; state.switchNeeded = BigInt(chain) !== 1n;
    $('connect').textContent = state.switchNeeded ? 'Switch to mainnet ↗' : 'Reconnect wallet ↗';
    feedback('launch-feedback', 'Wallet network changed. Reconnect and simulate again before signing.');
  });
}

async function loadApplication(provider = publicProvider) {
  if (!state.artifact) throw new Error('Application ABI is unavailable. Reload the site.');
  const entered = $('controller').value.trim(), epoch = state.epoch;
  const address = await verifyController(provider, entered, state.artifact);
  const app = new Contract(address, state.artifact.abi, provider);
  const owner = await app.owner();
  if (!sameAddress(owner, CONFIG.owner)) throw new Error('The application has a different owner.');
  if (epoch !== state.epoch || entered !== $('controller').value.trim()) throw new Error('Application changed during verification. Retry.');
  state.controller = address;
  feedback('controller-help', `Verified bytecode and designated owner · ${short(address)}`);
  return app;
}
$('load-controller').addEventListener('click', async () => {
  $('load-controller').disabled = true;
  try { const app = await loadApplication(); await readLaunch(app); toast('Application verified'); }
  catch (error) { state.controller = null; suspendProofActions(); feedback('controller-help', cleanError(error), true); }
  finally { $('load-controller').disabled = false; }
});

function renderHistory(history) {
  $('factory-count').textContent = String(history.count);
  $('factory-count').nextElementSibling.textContent = 'CREATION EVENTS VERIFIED\nIN THE COMPLETE SCANNED RANGE';
  feedback('history-status', `${history.count} token${history.count === 1 ? '' : 's'} created through block ${history.blockNumber.toLocaleString()}. Scanned from factory deployment at block ${CONFIG.factoryDeploymentBlock.toLocaleString()}. ${history.count ? 'The first slot is occupied.' : 'No creation events observed at this block.'}`);
}

async function readLaunch(app) {
  const epoch = state.epoch, controller = state.controller;
  const provider = app.runner;
  const latest = await provider.getBlock('latest');
  const launchStatus = await app.status({ blockTag: latest.number });
  if (launchStatus !== 2n) {
    if (epoch !== state.epoch || controller !== state.controller) return;
    resetApplicationDisplay(); state.controller = controller;
    feedback('data-status', `Application verified on mainnet at block ${latest.number.toLocaleString()}. Token launch is pending.`);
    return;
  }
  const launchBlock = Number(await app.launchBlock());
  const event = app.interface.getEvent('Launched');
  const logs = await provider.getLogs({ address: controller, topics: [event.topicHash], fromBlock: launchBlock, toBlock: launchBlock });
  if (logs.length !== 1) throw new Error('A unique application launch event could not be verified.');
  const receipt = await provider.getTransactionReceipt(logs[0].transactionHash);
  const evidence = parseLaunchReceipt(receipt, controller);
  const canonicalBlock = await provider.getBlock(receipt.blockNumber);
  if (canonicalBlock?.hash !== receipt.blockHash) throw new Error('Receipt is not in the canonical chain. Refresh.');
  if (!sameAddress(await app.token(), evidence.token) || await app.poolId() !== evidence.poolId
    || await app.positionId() !== evidence.positionId) throw new Error('Receipt does not match application state.');
  const history = await factoryHistory(provider, latest.number);
  const ordinal = launchOrdinal(history, evidence);
  const token = new Contract(evidence.token, TOKEN_ABI, provider);
  const hook = new Contract(CONFIG.hook, ['function protocolFeeRecipient() view returns(address)'], provider);
  const [supply, symbol, name, tax, currentOwner, resting, recipient, decayRecipient, protocolRecipient] = await Promise.all([
    token.totalSupply({blockTag:latest.number}), token.symbol({blockTag:latest.number}), token.name({blockTag:latest.number}),
    token.taxBps({blockTag:latest.number}), token.owner({blockTag:latest.number}), token.restingTaxBps({blockTag:latest.number}),
    token.feeRecipient({blockTag:latest.number}), token.feeDecayRecipient({blockTag:latest.number}),
    hook.protocolFeeRecipient({blockTag:latest.number})
  ]);
  // Supply can decline through token burns after launch; original supply was checked atomically.
  if (symbol !== 'ERC20T' || name !== 'erc20t' || supply > CONFIG.supply) throw new Error('Token metadata does not match this project.');
  const confirmations = Math.max(0, latest.number - receipt.blockNumber + 1);
  if (epoch !== state.epoch || controller !== state.controller) return;
  state.evidence = { ...evidence, ordinal, confirmations, controller, blockHash: receipt.blockHash,
    checkedBlock: latest.number, historyBlockHash: history.blockHash, currentTokenTaxBps:tax,
    protocolFeeBps:15, protocolRecipient, currentOwner, recipient, decayRecipient };
  renderHistory(history);
  $('hero-status').textContent = confirmations >= 12 ? 'LAUNCH CONFIRMED' : 'LAUNCH MINED';
  $('hero-status').classList.add('live');
  $('hero-status-note').textContent = `Factory token #${ordinal} · ${confirmations} confirmations`;
  $('proof-status').textContent = confirmations >= 12 ? 'CONFIRMED' : `${confirmations}/12 CONFIRMATIONS`;
  $('proof-status').classList.add('live');
  $('launch-headline').textContent = 'The record is onchain.';
  $('launch-description').textContent = `The erc20t / IMD pool launched in block ${receipt.blockNumber.toLocaleString()}. Its initial position was verified as locked by the application. ${confirmations < 12 ? 'Trading links unlock after 12 confirmations.' : 'Inspect the receipt and current token settings below.'}`;
  $('token-address').replaceChildren(link(evidence.token, explorerAddress(evidence.token)));
  $('launch-transaction').replaceChildren(link(evidence.transactionHash, explorerTransaction(evidence.transactionHash)));
  $('pool-id').textContent = evidence.poolId;
  $('position-id').replaceChildren(link(`#${evidence.positionId}`, `https://etherscan.io/nft/${CONFIG.positionManager}/${evidence.positionId}`));
  $('current-tax').textContent = `${Number(tax) / 100}% · block ${latest.number}`;
  $('launch-order').textContent = `#${ordinal} · verified factory history`;
  for (const id of ['live-owner','live-fee','live-decay','live-resting','live-protocol']) $(id)?.remove();
  for (const [id, label, value] of [['live-owner','Current token owner',currentOwner],['live-fee','Current fee recipient',recipient],
    ['live-decay','Current decay recipient',decayRecipient],['live-resting','Current resting tax',`${Number(resting) / 100}%`],
    ['live-protocol','Protocol fee recipient',protocolRecipient]]) {
    const row = evidenceRow(label, value); row.id = id; $('current-tax').parentElement.parentElement.append(row);
  }
  $('download-proof').disabled = false;
  if (confirmations >= 12) {
    $('trade').href = `https://app.uniswap.org/swap?chain=mainnet&inputCurrency=${CONFIG.quoteToken}&outputCurrency=${evidence.token}`;
    $('trade').target = '_blank'; $('trade').rel = 'noopener noreferrer';
    $('trade').classList.remove('disabled'); $('trade').removeAttribute('aria-disabled');
    $('watch-token').disabled = false;
  } else {
    $('trade').removeAttribute('href'); $('trade').classList.add('disabled'); $('trade').setAttribute('aria-disabled','true');
    $('watch-token').disabled = true;
  }
  $('review').disabled = true;
  feedback('launch-feedback', 'This application has already launched. A second launch is prohibited.');
  feedback('data-status', `Receipt, pool identity and factory order verified through block ${latest.number.toLocaleString()}. Current tax and recipients are sampled at that block; refresh before trading.`);
}

$('refresh').addEventListener('click', async () => {
  $('refresh').disabled = true;
  try {
    feedback('data-status', 'Checking mainnet and scanning factory creation events…');
    if ($('controller').value.trim()) await readLaunch(await loadApplication());
    const head = await publicProvider.getBlockNumber();
    renderHistory(await factoryHistory(publicProvider, head, { onProgress: end => feedback('data-status', `Scanned factory events through block ${end.toLocaleString()}…`) }));
    feedback('data-status', `Factory history checked at block ${head.toLocaleString()}.${state.controller ? ' Application data checked above.' : ' Add the deployed application address to verify this project’s launch.'}`);
  } catch (error) { suspendProofActions(); feedback('data-status', `Chain data unavailable: ${cleanError(error)} Previously displayed data is a snapshot.`, true); }
  finally { $('refresh').disabled = false; }
});

$('watch-token').addEventListener('click', async () => {
  try {
    if (!window.ethereum?.request) throw new Error('Connect an Ethereum wallet first.');
    if (!state.evidence || state.evidence.confirmations < 12) throw new Error('Wait for a confirmed launch.');
    const chain = await window.ethereum.request({ method: 'eth_chainId' });
    if (BigInt(chain) !== 1n) throw new Error('Switch your wallet to Ethereum mainnet first.');
    const added = await window.ethereum.request({ method: 'wallet_watchAsset', params: {
      type: 'ERC20', options: { address: state.evidence.token, symbol: 'ERC20T', decimals: 18 }
    } });
    toast(added ? 'Token added to your wallet' : 'Token was not added');
  } catch (error) { toast(cleanError(error)); }
});

$('launch-form').addEventListener('submit', async event => {
  event.preventDefault();
  if (state.sending) return;
  $('review').disabled = true;
  try {
    invalidateReview();
    if (!state.browser || !sameAddress(state.account, CONFIG.owner)) throw new Error('Connect the designated owner wallet on Ethereum mainnet.');
    await assertMainnet(state.browser);
    const accounts = await state.browser.send('eth_accounts', []);
    if (!sameAddress(accounts[0], CONFIG.owner)) throw new Error('The selected wallet is not the designated owner.');
    const app = await loadApplication(state.browser);
    const epoch = state.epoch;
    if (await app.status() !== 0n) throw new Error('This application is no longer ready to launch. Refresh its status.');
    const price = priceFromInput($('price').value);
    const block = await state.browser.getBlock('latest');
    feedback('launch-feedback', 'Scanning the full factory history and simulating the launch…');
    const history = await factoryHistory(state.browser, block.number);
    const requireFirst = !$('allow-prior').checked;
    if (requireFirst && history.count > 0) throw new Error(`${history.count} factory token(s) already exist. Review and explicitly accept an early launch to proceed.`);
    const deadline = BigInt(block.timestamp + 600);
    const signer = await state.browser.getSigner(CONFIG.owner);
    const writer = app.connect(signer);
    const predicted = await writer.launch.staticCall(price, deadline, requireFirst);
    const gas = await writer.launch.estimateGas(price, deadline, requireFirst);
    if (epoch !== state.epoch) throw new Error('Wallet or launch parameters changed. Simulate again.');
    state.pending = { controller: state.controller, price, deadline, requireFirst, epoch, gas };
    $('review-details').replaceChildren(
      evidenceRow('Network', 'Ethereum mainnet (1)'), evidenceRow('Owner & recipients', CONFIG.owner),
      evidenceRow('Application', state.controller), evidenceRow('Price / ERC20T', `${formatUnits(price,18)} IMD`),
      evidenceRow('Initial FDV', `${marketCapIMD(price)} IMD`), evidenceRow('Protocol share','15 bps included in token tax; ETH payouts'),
      evidenceRow('Factory tokens before', String(history.count)),
      evidenceRow('First-only guard', requireFirst ? 'Enabled' : 'Early launch accepted'),
      evidenceRow('Predicted token', `${predicted} (simulation only; may change)`),
      evidenceRow('Estimated gas units', gas.toLocaleString()),
      evidenceRow('Expires', new Date(Number(deadline) * 1000).toISOString())
    );
    $('send-launch').disabled = false;
    feedback('send-status', 'Simulation succeeded. Your wallet will show the transaction and gas cost.');
    feedback('launch-feedback', 'Simulation succeeded. Review all terms in the confirmation panel.');
    $('review-dialog').showModal();
  } catch (error) { feedback('launch-feedback', cleanError(error), true); }
  finally { if (!state.evidence) $('review').disabled = false; }
});
$('close-dialog').addEventListener('click', () => { if (!state.sending) { invalidateReview(); $('review-dialog').close(); } });
$('review-dialog').addEventListener('cancel', event => { if (state.sending) event.preventDefault(); else invalidateReview(); });

$('send-launch').addEventListener('click', async () => {
  if (state.sending) return;
  const pending = state.pending;
  state.sending = true; $('send-launch').disabled = true; $('close-dialog').disabled = true; $('review').disabled = true;
  let tx;
  try {
    if (!pending || pending.epoch !== state.epoch || pending.controller !== state.controller) throw new Error('The review is stale. Simulate again.');
    await assertMainnet(state.browser);
    const accounts = await state.browser.send('eth_accounts', []);
    if (!sameAddress(accounts[0], CONFIG.owner)) throw new Error('Wallet account changed. Simulate again.');
    const app = await loadApplication(state.browser);
    const block = await state.browser.getBlock('latest');
    if (BigInt(block.timestamp) >= pending.deadline) throw new Error('The review expired. Simulate again.');
    const writer = app.connect(await state.browser.getSigner(CONFIG.owner));
    await writer.launch.staticCall(pending.price, pending.deadline, pending.requireFirst);
    if (pending.epoch !== state.epoch) throw new Error('Wallet or parameters changed. Simulate again.');
    feedback('send-status', 'Confirm the launch in your wallet.');
    tx = await writer.launch(pending.price, pending.deadline, pending.requireFirst, { chainId: 1 });
    $('send-status').replaceChildren(document.createTextNode('Submitted. Waiting for confirmation: '), link(tx.hash, explorerTransaction(tx.hash)));
    const receipt = await tx.wait(1);
    parseLaunchReceipt(receipt, pending.controller);
    state.pending = null;
    feedback('send-status', 'Launch mined. Verifying the receipt and factory order…');
    await readLaunch(new Contract(pending.controller, state.artifact.abi, publicProvider));
    $('review-dialog').close();
    toast('Launch mined. Refresh to track confirmations.');
  } catch (error) {
    const message = tx ? `Transaction ${tx.hash} was submitted. ${cleanError(error)} Refresh chain data before taking further action.` : cleanError(error);
    feedback('send-status', message, true); feedback('launch-feedback', message, true);
    state.pending = null;
  } finally {
    state.sending = false; $('close-dialog').disabled = false;
    if (!state.evidence) $('review').disabled = false;
  }
});

$('download-proof').addEventListener('click', () => {
  if (!state.evidence) return;
  const data = JSON.stringify({ chainId:1, ...state.evidence }, (_,value) => typeof value === 'bigint' ? value.toString() : value, 2);
  const url = URL.createObjectURL(new Blob([data+'\n'],{type:'application/json'}));
  const a = document.createElement('a'); a.href = url; a.download = 'erc20t-launch-evidence.json';
  document.body.append(a); a.click(); a.remove(); setTimeout(()=>URL.revokeObjectURL(url),1000);
});

try {
  const [artifactResponse, deploymentResponse] = await Promise.all([fetch('./abi/ERC20TLaunch.json'), fetch('./deployment.json')]);
  if (!artifactResponse.ok || !deploymentResponse.ok) throw new Error('Local application artifacts are missing.');
  state.artifact = await artifactResponse.json(); state.deployment = await deploymentResponse.json();
  if (state.deployment.chainId !== 1) throw new Error('Deployment configuration must name Ethereum mainnet.');
  if (state.deployment.controller) {
    $('controller').value = state.deployment.controller;
    try { await readLaunch(await loadApplication()); } catch (error) { suspendProofActions(); feedback('data-status', cleanError(error), true); }
  }
} catch (error) { feedback('launch-feedback', `Application unavailable: ${cleanError(error)}`, true); $('review').disabled = true; }
