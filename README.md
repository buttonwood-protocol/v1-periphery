## V1-Periphery

**Periphery contracts for the Buttonwood-V1 Protocol**

Periphery consists of:

- **Router**: A router that auto-wraps USD stablecoins into USDX/Consol before interacting with Core Contracts
- **RolloverVault**: A vault that auto-deposits USDX into the next available OriginationPool
- **FulfillmentVault**: A vault used by the fulfiller for increasing liquidity to fill orders

## Documentation

### Design Consideratiosn:

**LiquidityVault:**
- General Functions:
  - Deposit [USD token] -> USDX
  - Withdraw
- Admin Functions:
  - Enable/Disable Whitelist
  - Add/Remove Whitelist addresses
  - Pause/Unpause the contract
- Special Considerations:
  - Keepers need to collect a fee to perform operations

**FulfillmentVault:**
- Keeper Functions:
  - Buy hype via usdc
  - Transfer Hype to evm
  - Wrap hype into whype
  - Approve whype to order pool (maybe we infinite approve this)
  - Fill order
  - Unwrap USDX (burn it into usd-tokens)
  - Transfer usd-tokens to core
  - Trade usd tokens to usdc
- Special Considerations:
  - Need to temporarily pause withdrawals while processing orders. So need a withdrawal queue.
  - Not just withdrawing usdx + hype, but balances from hypercore...
  - Protocol fee in here?

**RolloverVault:**
- Keeper Functions:
  - Enter origination pool
  - Exit origination pool [Permissionless]
- Special Considerations:
  - Not just withdrawing usdx + consol, but also all of the OGPool receipt tokens
  - Need to configure a % usable in each epoch (this way there is always an ogpool available)
