// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.17;

import "forge-std/Test.sol";
import "forge-std/console2.sol";

import { ContinuousGDA } from "src/libraries/ContinuousGDA.sol";
import { ContinuousGDAWrapper } from "./wrapper/ContinuousGDAWrapper.sol";
import { SD59x18, convert, wrap, unwrap } from "prb-math/SD59x18.sol";

contract ContinuousGDATest is Test {

  ContinuousGDAWrapper wrapper;

  function setUp() public {
    wrapper = new ContinuousGDAWrapper();
  }

  function testParadigmDocPurchasePrice() public {
    // 1 per 10 seconds
    uint256 purchaseAmount = 1e18;
    SD59x18 emissionRate = convert(1e18); // 1 per second
    SD59x18 initialPrice = convert(10e18);
    SD59x18 decayConstant = wrap(0.5e18);
    SD59x18 elapsedTime = convert(10);

    console2.log("purchaseAmount", purchaseAmount);
    console2.log("emissionRate", unwrap(emissionRate));
    console2.log("initialPrice", unwrap(initialPrice));
    console2.log("decayConstant", unwrap(decayConstant));
    console2.log("elapsedTime", unwrap(elapsedTime));

    uint256 amountIn = wrapper.purchasePrice(
      purchaseAmount,
      emissionRate,
      initialPrice,
      decayConstant,
      elapsedTime
    );

    console2.log((amountIn * 1e18) / purchaseAmount);

    assertEq(amountIn, 87420990783136780);
  }

  function testPurchasePrice_ignoreTime() public {
    SD59x18 emissionRate = convert(1); // 1 per second
    SD59x18 initialPrice = convert(26);
    SD59x18 decayConstant = wrap(0.00000001e18); // time does not affect price
    SD59x18 elapsedTime = convert(0);

    assertEq(
      wrapper.purchasePrice(
        1,
        emissionRate,
        initialPrice,
        decayConstant,
        elapsedTime
      ),
      26
    );
  }

  function testPurchasePrice_cheaperBefore() public {
    SD59x18 emissionRate = convert(1); // 1 per second
    SD59x18 initialPrice = convert(1);
    SD59x18 decayConstant = wrap(0.3e18); // time does not affect price
    SD59x18 elapsedTime = convert(1);

    assertLt(
      wrapper.purchasePrice(
        1,
        emissionRate,
        initialPrice,
        decayConstant,
        elapsedTime
      ),
      uint256(convert(initialPrice))
    );
  }

  function testPurchasePrice_moreExpensiveAfter() public {
    SD59x18 emissionRate = convert(1); // 1 per second
    SD59x18 initialPrice = convert(1);
    SD59x18 decayConstant = wrap(0.3e18); // time does not affect price
    SD59x18 elapsedTime = convert(0);

    assertGe(
      wrapper.purchasePrice(
        1,
        emissionRate,
        initialPrice,
        decayConstant,
        elapsedTime
      ),
      uint256(convert(initialPrice))
    );
  }

  function testPurchasePrice_largeAmounts() public {
    SD59x18 emissionRate = convert(1e18); // 1 full token per second
    SD59x18 auctionStartingPrice = convert(1);
    SD59x18 decayConstant = wrap(0.3e18); // time does not affect price
    SD59x18 elapsedTime = convert(0); // we're ahead of schedule, so it should be expensive

    uint yieldPurchased = 1e18;

    // uint marketCostInPrizeTokens = uint(convert(auctionStartingPrice.mul(convert(int(yieldPurchased)))));

    assertGe(
      wrapper.purchasePrice(
        yieldPurchased,
        emissionRate,
        auctionStartingPrice,
        decayConstant,
        elapsedTime
      ),
      uint(convert(auctionStartingPrice))
    );
  }

  function testPurchasePrice_bestAmount() public {

    uint availableAmount = 1000e6; // 1000 USDC
    uint duration = 1 days;
    SD59x18 emissionRate = convert(int(availableAmount)).div(convert(int(duration)));
    SD59x18 auctionStartingPrice = convert(1000e18);
    SD59x18 decayConstant = wrap(0.0005e18); // time does not affect price

    // 1 USDC = 1 POOL => usdc/pool = 1e6/1e18 = 1e-12
    // say there is a 26 decimal token.  Pool is 18 decimals.
    // exchange rate is billion to one
    SD59x18 exchangeRateAmountOutToAmountIn = wrap(1e19);

    (uint elapsedTime, uint bestAmountOut, uint bestProfit, uint bestAmountIn) = computeArbitrageStart(
      emissionRate,
      auctionStartingPrice,
      decayConstant,
      exchangeRateAmountOutToAmountIn,
      availableAmount,
      duration,
      5 minutes
    );

    console2.log("arbitrageStart", elapsedTime);
    console2.log("bestAmountOut", bestAmountOut);
    console2.log("bestAmountIn", bestAmountIn);
    // console2.log("bestProfit", bestProfit / 1e18);
    if (bestAmountIn > 0) {
      console2.log("trade price", uint(convert(convert(int(bestAmountOut)).div(convert(int(bestAmountIn))))));
    }
  }

  function computeArbitrageStart(
    SD59x18 emissionRate,
    SD59x18 auctionStartingPrice,
    SD59x18 decayConstant,
    SD59x18 exchangeRateAmountOutToAmountIn,
    uint availableAmount,
    uint maxElapsedTime,
    uint timePeriod
  ) public view returns (uint elapsedTime, uint bestAmountOut, uint bestProfit, uint bestAmountIn) {
    for (elapsedTime = 0; elapsedTime < maxElapsedTime; elapsedTime += timePeriod) {
      (bestAmountOut, bestProfit, bestAmountIn) = computeBestAmountOut(
        emissionRate,
        auctionStartingPrice,
        decayConstant,
        exchangeRateAmountOutToAmountIn,
        availableAmount,
        int(elapsedTime)
      );

      if (bestProfit > 0) {
        break;
      }
    }
  }

  function computeBestAmountOut(
    SD59x18 emissionRate,
    SD59x18 auctionStartingPrice,
    SD59x18 decayConstant,
    SD59x18 marketRateAmountOutToAmountIn,
    uint availableAmount,
    int elapsedTime
  ) public view returns (uint bestAmountOut, uint bestProfit, uint bestAmountIn) {
    int chunk = int(availableAmount / 100);
    for (int amountOut = chunk; amountOut <= int(availableAmount); amountOut += chunk) {
      uint cost = ContinuousGDA.purchasePrice(
        uint(amountOut),
        emissionRate,
        auctionStartingPrice,
        decayConstant,
        convert(elapsedTime)
      );
      // console2.log("cost", cost);
      // console2.log("\tamountOut", uint(amountOut));
      uint revenue = uint(convert(convert(amountOut).div(marketRateAmountOutToAmountIn)));
      // console2.log("\t\trevenue", revenue);
      if (revenue > cost) {
        uint profit = revenue - cost;
        if (profit > bestProfit) {
          bestProfit = profit;
          bestAmountIn = cost;
          bestAmountOut = uint(amountOut);
        }
      }
    }
  }

}
