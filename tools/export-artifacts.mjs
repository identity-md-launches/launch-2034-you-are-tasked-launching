import { readFileSync, writeFileSync } from 'node:fs';
const artifact = JSON.parse(readFileSync('out/ERC20TLaunch.sol/ERC20TLaunch.json', 'utf8'));
const exported = { contractName: 'ERC20TLaunch', compiler: '0.8.26', abi: artifact.abi,
  deployedBytecode: { object: artifact.deployedBytecode.object,
    immutableReferences: artifact.deployedBytecode.immutableReferences } };
writeFileSync('site/abi/ERC20TLaunch.json', JSON.stringify(exported, null, 2) + '\n');
console.log('Exported the application ABI and runtime for browser verification.');
