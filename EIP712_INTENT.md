# EIP-712 Order Intent — Integration Notes

Wave 2 (audit 5.1.2) requires an EIP-712 signature from `params.sender` whenever the
relayer calls `createOrder` on behalf of a user. The intent is authorisation only: the
EIP-2612 permit or the existing ERC-20 allowance still moves the tokens.

The self path (`msg.sender == params.sender`, LP on-ramp) needs no intent.

---

## 1. Domain

| Field | Value |
|---|---|
| `name` | `CentiivLiquidityProvider` |
| `version` | `1` |
| `chainId` | Arc chain id (`5042` mainnet, `5042002` testnet) |
| `verifyingContract` | the `LiquidityProvider` **proxy** address |

The name and version are compile-time constants. There is no `__EIP712_init` call and no
nonce/domain storage beyond `intentNonce`.

## 2. Types

```solidity
struct OrderIntent {
    bytes32 orderId;
    address token;
    int256  amount;
    address temporaryWalletAddress;
    address refundAddress;
    uint8   protocolFee;       // enum ProtocolFees: Basic=0, Alpha=1, Ultimate=2
    uint256 deadline;
    uint256 nonce;
}
```

Type hash:

```
OrderIntent(bytes32 orderId,address token,int256 amount,address temporaryWalletAddress,address refundAddress,uint8 protocolFee,uint256 deadline,uint256 nonce)
```

Every field is taken from the same `OrderParams` object passed to `createOrder`, with
`deadline` and `nonce` from the new `OrderIntentSig` argument. A mismatch in any field
reverts `InvalidSignature`.

## 3. Nonce and deadline

- `nonce` must be **greater than or equal to** `intentNonce(sender)` on the contract.
  The accepted value sets the cursor to `nonce + 1`; a consumed nonce can never be
  reused. Gaps are allowed, so retries and abandoned orders cannot wedge the relayer.
- Normal integration: read `intentNonce(sender)` immediately before signing. If the
  call fails before submission with `InvalidNonce`, read it again.
- `deadline` is a Unix timestamp; `block.timestamp > deadline` reverts
  `SignatureExpired`. Signatures are bound to the chain id and the proxy address, so
  they cannot be replayed on a fork or another deployment.
- A zero `r` (an omitted signature) reverts `InvalidSignature`; there is no
  "unsigned relayer path".

## 4. viem example

```ts
import { keccak256, encodeAbiParameters, parseAbiParameters } from 'viem';

const domain = {
  name: 'CentiivLiquidityProvider',
  version: '1',
  chainId,
  verifyingContract: lpProxy,
} as const;

const types = {
  OrderIntent: [
    { name: 'orderId', type: 'bytes32' },
    { name: 'token', type: 'address' },
    { name: 'amount', type: 'int256' },
    { name: 'temporaryWalletAddress', type: 'address' },
    { name: 'refundAddress', type: 'address' },
    { name: 'protocolFee', type: 'uint8' },
    { name: 'deadline', type: 'uint256' },
    { name: 'nonce', type: 'uint256' },
  ],
} as const;

async function signOrderIntent(walletClient, sender, order, intentNonce) {
  const deadline = BigInt(Math.floor(Date.now() / 1000) + 15 * 60);
  const nonce = await publicClient.readContract({
    address: lpProxy,
    abi: liquidityProviderAbi,
    functionName: 'intentNonce',
    args: [sender],
  });

  const signature = await walletClient.signTypedData({
    account: sender,
    domain,
    types,
    primaryType: 'OrderIntent',
    message: {
      orderId: order.orderId,
      token: order.token,
      amount: order.amount,
      temporaryWalletAddress: order.temporaryWalletAddress,
      refundAddress: order.refundAddress,
      protocolFee: order.protocolFee,
      deadline,
      nonce,
    },
  });

  const { v, r, s } = parseSignature(signature);
  return { deadline, nonce, v, r, s };
}
```

## 5. Deployment ordering

Appending `intentSig` to `OrderParams` changes the `createOrder` selector. The old
backend cannot call the new implementation and the new backend cannot call the old one.
Deploy the contract and the backend in one coordinated window; relayer-created off-ramp
orders are unavailable until both are live. On-ramp orders, settlement, refunds and
emergency refunds are unaffected.

`test/Migration.t.sol` pins the selector change and the calldata-layout behaviour.

## 6. Failure codes

| Revert | Cause |
|---|---|
| `InvalidSignature()` | Missing/zero signature, wrong signer, or any signed field differs from the call |
| `SignatureExpired()` | `block.timestamp > deadline` |
| `InvalidNonce()` | `nonce < intentNonce(sender)` (already consumed) |
| `Unauthorized()` | Caller is neither `sender` nor the relayer |
| `TransferFailed()` / ERC-20 error | Permit/allowance did not authorise the transfer; the intent alone never moves funds |
