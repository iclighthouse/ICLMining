# ICLMining

ICDex’s mining activities constitute a significant aspect of the ICL ecosystem’s incentive program, comprising Trading Mining and Liquidity Mining. These activities are structured into regular rounds, governed by rules embedded within Canister smart contracts, which autonomously calculate Mining Points for traders and liquidity providers. The fixed number of mining rewards (ICL) available per round is distributed among participants based on their Mining Points.

## Trading Mining

During a mining round, traders’ trading volumes (in terms of the quote token amount) on designated trading pairs are calculated in USD value at current prices to determine their Trading Mining Points.

    Trader Trading Mining Points = ∑(TraderVolToken1 * Token1PriceUSD)

(`Token1` is means quote token).

At the end of the mining round, the smart contract automatically calculates each trader’s mining rewards.

    Trader Rewards = TotalSupplyForTradingMining * TraderTradingMiningPoints / TotalTradingMiningPoints

Note: The trading volume of VIP-maker accounts is only counted as 15%.

## Liquidity Mining

In a mining round, Liquidity Providers (LPs) provide liquidity in quote tokens on designated trading pairs in Public OAMMs. This liquidity is time-weighted and converted into USD value, also known as Time Weighted USD (TWUSD), to calculate their Liquidity Mining Points.

    LP Liquidity Mining Points = ∑(DurationSeconds * LPLiquidityToken1USD)

When the mining round concludes, the smart contract automatically calculates the mining rewards for all LPs.

    LP Rewards = TotalSupplyForLiquidityMining * LPLiquidityMiningPoints / TotalLiquidityMiningPoints

## NFT Acceleration

Traders and liquidity providers can boost their mining speed by 15% to 25% by binding an ICLighthouse Planet NFT. Different NFTs provide different acceleration rates:

* MERCURY (index 1515–2021) : 15%
* VENUS (index 1015–1514): 17%
* EARTH (index 615–1014): 19%
* MARS (index 315–614) : 21%
* JUPITER (index 115–314): 23%
* SATURN (index 15–114): 25%
* URANUS (index 5–14): 25%
* NEPTUNE (index 0–4): 25%

## Claiming Rewards
Rewards (ICL) distributed from mining activities are stored in the balance of the Mining Canister. Traders and liquidity providers must execute a “Claim” operation to transfer ICL to their accounts.

## Canisters

- ICLMining:  odhfn-cqaaa-aaaar-qaana-cai
- ICLMining (Test): o7d74-vqaaa-aaaar-qaapa-cai

- Version: 0.2.0
- Module hash: 450c53e899844c40890d8b08f8fb80ad98f8a6c5b8d659c811fd99cbbba0a063

## Guide

https://medium.com/@ICLighthouse/icdex-mining-guide-f242a49f2dc9

## Additional token rewards (e.g., from the project side of the token of trading pair)

You (project side of the token of trading pair) need to `clone` the repository from Github, then compile and deploy a standalone canister, with the token cansiter-id and token fee provided as parameters when deploying.

## Dependent toolkits

### dfx
- https://github.com/dfinity/sdk/
- version: 0.15.3 (https://github.com/dfinity/sdk/releases/tag/0.15.3)
- moc version: 0.10.3

### vessel
- https://github.com/dfinity/vessel
- version: 0.7.0 (https://github.com/dfinity/vessel/releases/tag/v0.7.0)


### Deploying

```
dfx canister --network ic create ICLMining --controller __your-principal__
dfx build --network ic ICLMining
dfx canister --network ic install ICLMining --argument '(principal "__your-token-canister-id__", __your-token-fee-per-txn__ : nat)'
```

### Launching a round of mining

It is recommended to run a round of mining every week or month.

```
dfx canister --network ic call ICLMining newRound 'record{ \
    pairs = variant {whitelist = vec{ principal "__your-trading-pair-canister-id-1__"; principal "__your-trading-pair-canister-id-2__" }}; \
    pairFilter = record{minPairScore = 0 : nat; blackList = vec{}}; \
    content = "__your-description__"; \
    startTime = 0 : nat; \
    endTime = __End-time-of-the-round (ts, seconds)__ : nat; \
    supplyForTM = __Total-supply-for-trading-mining-rewards__ : nat; \
    supplyForLM = __Total-supply-for-liquidity-mining-rewards__ : nat; \
    preMiningDataFactorPercent = 0 : nat; \
}'
```

