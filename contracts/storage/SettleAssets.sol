// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "./PortfolioHandler.sol";
import "./BalanceHandler.sol";
import "./BitmapAssetsHandler.sol";
import "../common/AssetHandler.sol";
import "../common/AssetRate.sol";
import "../math/SafeInt256.sol";

struct SettleAmount {
    uint currencyId;
    int netCashChange;
}

library SettleAssets {
    using SafeInt256 for int;
    using AssetRate for AssetRateParameters;
    using Bitmap for bytes;
    using PortfolioHandler for PortfolioState;
    using AssetHandler for PortfolioAsset;

    bytes32 internal constant ZERO = 0x0;
    bytes32 internal constant MSB_BIG_ENDIAN = 0x8000000000000000000000000000000000000000000000000000000000000000;

    function getSettleAmountArray(
        PortfolioState memory portfolioState,
        uint blockTime
    ) internal pure returns (SettleAmount[] memory) {
        uint currenciesSettled;
        uint lastCurrencyId;
        // This is required for iteration
        portfolioState.calculateSortedIndex();

        for (uint i = portfolioState.sortedIndex.length; i > 0; --i) {
            PortfolioAsset memory asset = portfolioState.storedAssets[portfolioState.sortedIndex[i]];
            if (asset.getSettlementDate() > blockTime) continue;
            // Assume that this is sorted by cash group and maturity, currencyId = 0 is unused so this
            // will work for the first asset
            if (lastCurrencyId != asset.currencyId) {
                lastCurrencyId = asset.currencyId;
                currenciesSettled++;
            }
        }
        
        // Actual currency ids will be set in the loop
        SettleAmount[] memory settleAmounts = new SettleAmount[](currenciesSettled);
        if (currenciesSettled > 0) settleAmounts[0].currencyId = lastCurrencyId;
        return settleAmounts;
    }

    /**
     * @notice Shared calculation for liquidity token settlement
     */
    function calculateMarketStorage(
        PortfolioAsset memory asset
    ) internal view returns (int, int, SettlementMarket memory) {
        // 2x Storage Read
        SettlementMarket memory market = Market.getSettlementMarket(
            asset.currencyId,
            asset.maturity,
            asset.getSettlementDate()
        );

        int fCash = int(market.totalfCash).mul(asset.notional).div(market.totalLiquidity);
        int cashClaim = int(market.totalCurrentCash).mul(asset.notional).div(market.totalLiquidity);

        require(fCash <= market.totalfCash); // dev: settle liquidity token totalfCash overflow
        require(cashClaim <= market.totalCurrentCash); // dev: settle liquidity token totalCurrentCash overflow
        require(asset.notional <= market.totalLiquidity); // dev: settle liquidity token total liquidity overflow
        market.totalfCash = market.totalfCash - fCash;
        market.totalCurrentCash = market.totalCurrentCash - cashClaim;
        market.totalLiquidity = market.totalLiquidity - asset.notional;

        return (cashClaim, fCash, market);
    }

    /**
     * @notice Settles a liquidity token which requires getting the claims on both cash and fCash,
     * converting the fCash portion to cash at the settlement rate.
     */
    function settleLiquidityToken(
        PortfolioAsset memory asset,
        AssetRateParameters memory settlementRate
    ) internal view returns (int, SettlementMarket memory) {
        (int cashClaim, int fCash, SettlementMarket memory market) =
            calculateMarketStorage(asset);

        int assetCash = cashClaim.add(settlementRate.convertInternalFromUnderlying(fCash));

        return (assetCash, market);
    }

    /**
     * @notice Settles a liquidity token to idiosyncratic fCash
     */
    function settleLiquidityTokenTofCash(
        PortfolioState memory portfolioState,
        uint index
    ) internal view returns (int, SettlementMarket memory) {
        PortfolioAsset memory asset = portfolioState.storedAssets[index];
        (int cashClaim, int fCash, SettlementMarket memory market) =
            calculateMarketStorage(asset);

        if (fCash == 0) {
            // Skip some calculations
            portfolioState.deleteAsset(index);
        } else {
            // If the liquidity token's maturity is still in the future then we change the entry to be
            // an idiosyncratic fCash entry with the net fCash amount.
            // TODO: this might not work because there may be another fcash asset that nets this out
            portfolioState.storedAssets[index].assetType = AssetHandler.FCASH_ASSET_TYPE;
            portfolioState.storedAssets[index].notional = fCash;
            portfolioState.storedAssets[index].storageState = AssetStorageState.Update;
        }

        return (cashClaim, market);
    }

    /**
     * @notice View version of settle asset with a call to getSettlementRateView, the reason here is that
     * in the stateful version we will set the settlement rate if it is not set.
     */
    function getSettleAssetContextView(
        PortfolioState memory portfolioState,
        uint blockTime
    ) internal view returns (SettleAmount[] memory) {
        AssetRateParameters memory settlementRate;
        SettleAmount[] memory settleAmounts = getSettleAmountArray(portfolioState, blockTime);
        uint settleAmountIndex;
        uint lastMaturity;

        for (uint i; i < portfolioState.sortedIndex.length; i++) {
            PortfolioAsset memory asset = portfolioState.storedAssets[portfolioState.sortedIndex[i]];
            if (asset.getSettlementDate() > blockTime) continue;

            if (settleAmounts[settleAmountIndex].currencyId != asset.currencyId) {
                lastMaturity = 0;
                settleAmountIndex += 1;
                settleAmounts[settleAmountIndex].currencyId = asset.currencyId;
            }

            // Settlement rates are used to convert fCash and fCash claims back into assetCash values. This means
            // that settlement rates are required whenever fCash matures and when liquidity tokens' **fCash claims**
            // mature. fCash claims on liquidity tokens settle at asset.maturity, not the settlement date
            if (lastMaturity != asset.maturity && asset.maturity < blockTime) {
                // Storage Read inside getSettlementRateView
                settlementRate = AssetRate.buildSettlementRateView(
                    asset.currencyId,
                    asset.maturity
                );
                lastMaturity = asset.maturity;
            }

            int assetCash;
            if (asset.assetType == AssetHandler.FCASH_ASSET_TYPE) {
                assetCash = settlementRate.convertInternalFromUnderlying(asset.notional);
                portfolioState.deleteAsset(portfolioState.sortedIndex[i]);
            } else if (AssetHandler.isLiquidityToken(asset.assetType)) {
                if (asset.maturity > blockTime) {
                    (assetCash, /* */) = settleLiquidityTokenTofCash(
                        portfolioState,
                        portfolioState.sortedIndex[i]
                    );
                } else {
                    (assetCash, /* */) = settleLiquidityToken(
                        asset,
                        settlementRate
                    );
                    portfolioState.deleteAsset(portfolioState.sortedIndex[i]);
                }
            }

            settleAmounts[settleAmountIndex].netCashChange = settleAmounts[settleAmountIndex].netCashChange
                .add(assetCash);
        }

        return settleAmounts;
    }

    /**
     * @notice Stateful version of settle asset, the only difference is the call to getSettlementRateStateful
     */
    function getSettleAssetContextStateful(
        PortfolioState memory portfolioState,
        uint blockTime
    ) internal returns (SettleAmount[] memory) {
        AssetRateParameters memory settlementRate;
        SettleAmount[] memory settleAmounts = getSettleAmountArray(portfolioState, blockTime);
        uint settleAmountIndex;
        uint lastMaturity;

        for (uint i; i < portfolioState.storedAssets.length; i++) {
            PortfolioAsset memory asset = portfolioState.storedAssets[portfolioState.sortedIndex[i]];
            if (asset.getSettlementDate() > blockTime) continue;

            if (settleAmounts[settleAmountIndex].currencyId != asset.currencyId) {
                lastMaturity = 0;
                settleAmountIndex += 1;
                settleAmounts[settleAmountIndex].currencyId = asset.currencyId;
            }

            if (lastMaturity != asset.maturity && asset.maturity < blockTime) {
                // Storage Read / Write inside getSettlementRateStateful
                settlementRate = AssetRate.buildSettlementRateStateful(
                    asset.currencyId,
                    asset.maturity,
                    blockTime
                );
                lastMaturity = asset.maturity;
            }

            int assetCash;
            if (asset.assetType == AssetHandler.FCASH_ASSET_TYPE) {
                assetCash = settlementRate.convertInternalFromUnderlying(asset.notional);
                portfolioState.deleteAsset(portfolioState.sortedIndex[i]);
            } else if (AssetHandler.isLiquidityToken(asset.assetType)) {
                SettlementMarket memory market;
                if (asset.maturity > blockTime) {
                    (assetCash, market) = settleLiquidityTokenTofCash(
                        portfolioState,
                        portfolioState.sortedIndex[i]
                    );
                } else {
                    (assetCash, market) = settleLiquidityToken(
                        asset,
                        settlementRate
                    );
                    portfolioState.deleteAsset(portfolioState.sortedIndex[i]);
                }

                // 2x storage write
                Market.setSettlementMarket(market);
            }

            settleAmounts[settleAmountIndex].netCashChange = settleAmounts[settleAmountIndex].netCashChange
                .add(assetCash);
        }

        return settleAmounts;
    }

    /**
     * @notice Stateful settlement function to settle a bitmapped asset. Deletes the
     * asset from storage after calculating it.
     */
    function settleBitmappedAsset(
        address account,
        uint currencyId,
        uint nextMaturingAsset,
        uint blockTime,
        uint bitNum,
        bytes32 bits
    ) internal returns (bytes32, int) {
        int assetCash;

        if ((bits & MSB_BIG_ENDIAN) == MSB_BIG_ENDIAN) {
            uint maturity = CashGroup.getMaturityFromBitNum(nextMaturingAsset, bitNum);
            // Storage Read
            bytes32 ifCashSlot = BitmapAssetsHandler.getifCashSlot(account, currencyId, maturity);
            int ifCash;
            assembly { ifCash := sload(ifCashSlot) }

            // Storage Read / Write
            AssetRateParameters memory rate = AssetRate.buildSettlementRateStateful(
                currencyId,
                maturity,
                blockTime
            );
            assetCash = rate.convertInternalFromUnderlying(ifCash);
            // Storage Delete
            assembly { sstore(ifCashSlot, 0) }
        }

        bits = bits << 1;

        return (bits, assetCash);
    }

    /**
     * @notice Given a bitmap for a cash group and timestamps, will settle all assets
     * that have matured and remap the bitmap to correspond to the current time.
     */
    function settleBitmappedCashGroup(
        address account,
        uint currencyId,
        uint nextMaturingAsset,
        uint blockTime
    ) internal returns (bytes memory, int) {
        bytes memory bitmap = BitmapAssetsHandler.getAssetsBitmap(account, currencyId);

        int totalAssetCash;
        SplitBitmap memory splitBitmap = bitmap.splitfCashBitmap();
        uint blockTimeUTC0 = CashGroup.getTimeUTC0(blockTime);
        // This blockTimeUTC0 will be set to the new "nextMaturingAsset", this will refer to the
        // new next bit
        (uint lastSettleBit, /* isValid */) = CashGroup.getBitNumFromMaturity(nextMaturingAsset, blockTimeUTC0);
        if (lastSettleBit == 0) return (bitmap, totalAssetCash);

        // NOTE: bitNum is 1-indexed
        for (uint bitNum = 1; bitNum <= lastSettleBit; bitNum++) {
            if (bitNum <= CashGroup.WEEK_BIT_OFFSET) {
                if (splitBitmap.dayBits == ZERO) {
                    // No more bits set in day bits, continue to the next set of bits
                    bitNum = CashGroup.WEEK_BIT_OFFSET;
                    continue;
                }

                int assetCash;
                (splitBitmap.dayBits, assetCash) = settleBitmappedAsset(
                    account,
                    currencyId,
                    nextMaturingAsset,
                    blockTime,
                    bitNum,
                    splitBitmap.dayBits
                );
                totalAssetCash = totalAssetCash.add(assetCash);
                continue;
            }

            if (bitNum <= CashGroup.MONTH_BIT_OFFSET) {
                if (splitBitmap.weekBits == ZERO) {
                    bitNum = CashGroup.MONTH_BIT_OFFSET;
                    continue;
                }

                int assetCash;
                (splitBitmap.weekBits, assetCash) = settleBitmappedAsset(
                    account,
                    currencyId,
                    nextMaturingAsset,
                    blockTime,
                    bitNum,
                    splitBitmap.weekBits
                );
                totalAssetCash = totalAssetCash.add(assetCash);
                continue;
            }

            if (bitNum <= CashGroup.QUARTER_BIT_OFFSET) {
                if (splitBitmap.monthBits == ZERO) {
                    bitNum = CashGroup.QUARTER_BIT_OFFSET;
                    continue;
                }

                int assetCash;
                (splitBitmap.monthBits, assetCash) = settleBitmappedAsset(
                    account,
                    currencyId,
                    nextMaturingAsset,
                    blockTime,
                    bitNum,
                    splitBitmap.monthBits
                );
                totalAssetCash = totalAssetCash.add(assetCash);
                continue;
            }

            // Check 1-indexing here
            if (bitNum <= 256) {
                if (splitBitmap.quarterBits == ZERO) {
                    break;
                }

                int assetCash;
                (splitBitmap.quarterBits, assetCash) = settleBitmappedAsset(
                    account,
                    currencyId,
                    nextMaturingAsset,
                    blockTime,
                    bitNum,
                    splitBitmap.quarterBits
                );
                totalAssetCash = totalAssetCash.add(assetCash);
                continue;
            }
        }

        remapBitmap(
            splitBitmap,
            nextMaturingAsset,
            blockTimeUTC0,
            lastSettleBit
        );
        bitmap = Bitmap.combinefCashBitmap(splitBitmap);

        return (bitmap, totalAssetCash);
    }

    function remapBitmap(
        SplitBitmap memory splitBitmap,
        uint nextMaturingAsset,
        uint blockTimeUTC0,
        uint lastSettleBit
    ) internal pure {
        if (splitBitmap.weekBits != ZERO && lastSettleBit < CashGroup.MONTH_BIT_OFFSET) {
            // Ensures that if part of the week portion is settled we still remap the remaining part
            // starting from the lastSettleBit. Skips if the lastSettleBit is past the offset
            uint bitOffset = lastSettleBit > CashGroup.WEEK_BIT_OFFSET ? lastSettleBit : CashGroup.WEEK_BIT_OFFSET;
            splitBitmap.weekBits = remapBitSection(
                nextMaturingAsset,
                blockTimeUTC0,
                bitOffset,
                CashGroup.WEEK,
                splitBitmap,
                splitBitmap.weekBits
            );
        }

        if (splitBitmap.monthBits != ZERO  && lastSettleBit < CashGroup.QUARTER_BIT_OFFSET) {
            uint bitOffset = lastSettleBit > CashGroup.MONTH_BIT_OFFSET ? lastSettleBit : CashGroup.MONTH_BIT_OFFSET;
            splitBitmap.monthBits = remapBitSection(
                nextMaturingAsset,
                blockTimeUTC0, bitOffset,
                CashGroup.MONTH,
                splitBitmap,
                splitBitmap.monthBits
            );
        }

        if (splitBitmap.quarterBits != ZERO && lastSettleBit < 256) {
            uint bitOffset = lastSettleBit > CashGroup.QUARTER_BIT_OFFSET ? lastSettleBit : CashGroup.QUARTER_BIT_OFFSET;
            splitBitmap.quarterBits = remapBitSection(
                nextMaturingAsset,
                blockTimeUTC0,
                bitOffset,
                CashGroup.QUARTER,
                splitBitmap,
                splitBitmap.quarterBits
            );
        }
    }

    /**
     * @dev Given a section of the bitmap, will remap active bits to a lower part of the bitmap.
     */
    function remapBitSection(
        uint nextMaturingAsset,
        uint blockTimeUTC0,
        uint bitOffset,
        uint bitTimeLength,
        SplitBitmap memory splitBitmap,
        bytes32 bits
    ) internal pure returns (bytes32) {
        // The first bit of the section is just above the bitOffset
        uint firstBitRef = CashGroup.getMaturityFromBitNum(nextMaturingAsset, bitOffset + 1);
        uint newFirstBitRef = CashGroup.getMaturityFromBitNum(blockTimeUTC0, bitOffset + 1);
        // NOTE: this will truncate the decimals
        uint bitsToShift = (newFirstBitRef - firstBitRef) / bitTimeLength;

        for (uint i; i < bitsToShift; i++) {
            if (bits == ZERO) break;

            if ((bits & MSB_BIG_ENDIAN) == MSB_BIG_ENDIAN) {
                // Map this into the lower section of the bitmap
                uint maturity = firstBitRef + i * bitTimeLength;
                (uint newBitNum, bool isValid) = CashGroup.getBitNumFromMaturity(blockTimeUTC0, maturity);
                require(isValid); // dev: remap bit section invalid maturity

                if (newBitNum <= CashGroup.WEEK_BIT_OFFSET) {
                    // Shifting down into the day bits
                    bytes32 bitMask = MSB_BIG_ENDIAN >> (newBitNum - 1);
                    splitBitmap.dayBits = splitBitmap.dayBits | bitMask;
                } else if (newBitNum <= CashGroup.MONTH_BIT_OFFSET) {
                    // Shifting down into the week bits
                    bytes32 bitMask = MSB_BIG_ENDIAN >> (newBitNum - CashGroup.WEEK_BIT_OFFSET - 1);
                    splitBitmap.weekBits = splitBitmap.weekBits | bitMask;
                } else if (newBitNum <= CashGroup.QUARTER_BIT_OFFSET) {
                    // Shifting down into the month bits
                    bytes32 bitMask = MSB_BIG_ENDIAN >> (newBitNum - CashGroup.MONTH_BIT_OFFSET - 1);
                    splitBitmap.monthBits = splitBitmap.monthBits | bitMask;
                } else {
                    revert(); // dev: remap bit section error in bit shift
                }
            }

            bits = bits << 1;
        }

        return bits;
    }

}
