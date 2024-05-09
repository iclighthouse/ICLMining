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

- Version: 0.1.0
- Module hash: 12cfc5f0179d4cab61770a3d51eca2b521a35a9488e5905f2e58d9d321cfd587

## Guide

https://medium.com/@ICLighthouse/icdex-mining-guide-f242a49f2dc9

