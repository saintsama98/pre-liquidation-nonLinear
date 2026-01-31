// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../lib/forge-std/src/Test.sol";
import "./BaseTest.sol";

import {IPreLiquidation, PreLiquidationParams} from "../src/interfaces/IPreLiquidation.sol";
import {IPreLiquidationCallback} from "../src/interfaces/IPreLiquidationCallback.sol";

import {Math} from "../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import {IOracle} from "../lib/morpho-blue/src/interfaces/IOracle.sol";
import "../lib/morpho-blue/src/interfaces/IMorpho.sol";
import {ErrorsLib} from "../src/libraries/ErrorsLib.sol";
import {MarketParamsLib} from "../lib/morpho-blue/src/libraries/MarketParamsLib.sol";
import {MathLib, WAD} from "../lib/morpho-blue/src/libraries/MathLib.sol";
import {SharesMathLib} from "../lib/morpho-blue/src/libraries/SharesMathLib.sol";

contract PreLiquidationTest is BaseTest, IPreLiquidationCallback {
    using MarketParamsLib for MarketParams;
    using SharesMathLib for uint256;
    using MathLib for uint256;

    event CallbackReached();

    /*//////////////////////////////////////////////////////////////
                        PARAM NORMALIZATION
    //////////////////////////////////////////////////////////////*/

    function _canonicalizeCurve(
        PreLiquidationParams memory p
    ) internal pure returns (PreLiquidationParams memory) {
        // Ensure monotonic LCF
        if (p.preLCF2 < p.preLCF1) {
            (p.preLCF1, p.preLCF2) = (p.preLCF2, p.preLCF1);
        }

        // Ensure monotonic LIF
        if (p.preLIF2 < p.preLIF1) {
            (p.preLIF1, p.preLIF2) = (p.preLIF2, p.preLIF1);
        }

        //  CRITICAL: preLltv must live in WAD LTV domain
        if (p.preLltv > WAD) {
            p.preLltv = WAD;
        }

        return p;
    }

    /*//////////////////////////////////////////////////////////////
                               SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() public override {
        super.setUp();
        factory = new PreLiquidationFactory(address(MORPHO));
    }

    /*//////////////////////////////////////////////////////////////
                   testPreLiquidationLiquidatable
    //////////////////////////////////////////////////////////////*/

    function testPreLiquidationLiquidatable(
        PreLiquidationParams memory p,
        uint256 collateralAmount,
        uint256 borrowAmount,
        uint256 newPrice
    ) public {
        p = _canonicalizeCurve(
            boundPreLiquidationParameters({
                preLiquidationParams: p,
                minPreLltv: WAD / 2,
                maxPreLltv: marketParams.lltv - 1,
                minPreLCF: WAD / 100,
                maxPreLCF: WAD,
                minPreLIF: WAD,
                maxPreLIF: WAD.wDivDown(lltv),
                preLiqOracle: marketParams.oracle
            })
        );

        collateralAmount = bound(collateralAmount, minCollateral, maxCollateral);

        (uint256 collateralQuoted, uint256 minBorrow, uint256 maxBorrow) =
            _getBorrowBounds(p, marketParams, collateralAmount);

        borrowAmount = bound(borrowAmount, minBorrow + 1, maxBorrow);
        _preparePreLiquidation(p, collateralAmount, borrowAmount, LIQUIDATOR);

        uint256 ltv = borrowAmount.wDivUp(collateralQuoted);

        uint256 prevPrice = oracle.price();
        newPrice = bound(
            newPrice,
            prevPrice / 10,
            prevPrice.wDivDown(marketParams.lltv).wMulDown(ltv)
        );
        oracle.setPrice(newPrice);

        uint256 newLtv =
            borrowAmount.wDivUp(collateralAmount.mulDivDown(newPrice, ORACLE_PRICE_SCALE));

        // liquidation curve domain
        vm.assume(newLtv >= p.preLltv);
        vm.assume(newLtv > marketParams.lltv);

        vm.startPrank(LIQUIDATOR);
        Position memory pos = MORPHO.position(id, BORROWER);

        uint256 preLCF = _preLCF(p, newLtv);

        uint256 repayableShares = Math.min(
            uint256(pos.borrowShares),
            uint256(pos.borrowShares).wMulDown(preLCF)
        );

        vm.expectRevert(ErrorsLib.LiquidatablePosition.selector);
        preLiquidation.preLiquidate(BORROWER, 0, repayableShares, hex"");
    }

    /*//////////////////////////////////////////////////////////////
                     testPreLiquidationCallback
    //////////////////////////////////////////////////////////////*/

    function testPreLiquidationCallback(
        PreLiquidationParams memory p,
        uint256 collateralAmount,
        uint256 borrowAmount
    ) public {
        p = _canonicalizeCurve(
            boundPreLiquidationParameters({
                preLiquidationParams: p,
                minPreLltv: WAD / 100,
                maxPreLltv: marketParams.lltv - 1,
                minPreLCF: WAD / 100,
                maxPreLCF: WAD,
                minPreLIF: WAD,
                maxPreLIF: WAD.wDivDown(lltv),
                preLiqOracle: marketParams.oracle
            })
        );

        collateralAmount = bound(collateralAmount, minCollateral, maxCollateral);

        (uint256 collateralQuoted, uint256 minBorrow, uint256 maxBorrow) =
            _getBorrowBounds(p, marketParams, collateralAmount);

        borrowAmount = bound(borrowAmount, minBorrow + 1, maxBorrow);
        _preparePreLiquidation(p, collateralAmount, borrowAmount, address(this));

        uint256 ltv = borrowAmount.wDivUp(collateralQuoted);

        vm.assume(ltv >= p.preLltv);
        vm.assume(ltv <= marketParams.lltv);

        vm.startPrank(address(this));
        Position memory pos = MORPHO.position(id, BORROWER);

        uint256 preLCF = _preLCF(p, ltv);

        uint256 repayableShares = Math.min(
            uint256(pos.borrowShares),
            uint256(pos.borrowShares).wMulDown(preLCF)
        );

        vm.recordLogs();
        preLiquidation.preLiquidate(
            BORROWER,
            0,
            repayableShares,
            abi.encode(this.testPreLiquidationCallback.selector, "")
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assert(logs.length > 0);
    }

    /*//////////////////////////////////////////////////////////////
                          CALLBACK HANDLER
    //////////////////////////////////////////////////////////////*/

    function onPreLiquidate(uint256, bytes calldata data) external {
        (bytes4 selector,) = abi.decode(data, (bytes4, bytes));
        require(selector == this.testPreLiquidationCallback.selector);
        emit CallbackReached();
    }
}
