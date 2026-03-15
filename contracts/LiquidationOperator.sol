//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.7;

import "hardhat/console.sol";

interface ILendingPool {
    function liquidationCall(address collateralAsset, address debtAsset, address user, uint256 debtToCover, bool receiveAToken) external;
    function getUserAccountData(address user) external view returns (uint256 totalCollateralETH, uint256 totalDebtETH, uint256 availableBorrowsETH, uint256 currentLiquidationThreshold, uint256 ltv, uint256 healthFactor);
    function getReservesList() external view returns (address[] memory);
}

interface IAaveProtocolDataProvider {
    function getUserReserveData(address asset, address user) external view returns (
        uint256 currentATokenBalance,
        uint256 currentStableDebt,
        uint256 currentVariableDebt,
        uint256 principalStableDebt,
        uint256 scaledVariableDebt,
        uint256 stableBorrowRate,
        uint256 liquidityRate,
        uint40 stableRateLastUpdated,
        bool usageAsCollateralEnabled
    );
}

interface IERC20 {
    function balanceOf(address owner) external view returns (uint256);
    function approve(address spender, uint256 value) external;
    function transfer(address to, uint256 value) external returns (bool);
}

interface IWETH is IERC20 {
    function withdraw(uint256) external;
}

interface IUniswapV2Callee {
    function uniswapV2Call(address sender, uint256 amount0, uint256 amount1, bytes calldata data) external;
}

interface IUniswapV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

interface IUniswapV2Pair {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function token0() external view returns (address);
    function token1() external view returns (address);
}

contract LiquidationOperator is IUniswapV2Callee {
    // debt token = USDC
    IERC20 constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    // collateral = WETH
    IWETH  constant WETH = IWETH(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    IUniswapV2Factory constant uniswapV2Factory =
        IUniswapV2Factory(0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f);

    ILendingPool constant lendingPool =
        ILendingPool(0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9);

    IAaveProtocolDataProvider constant dataProvider =
        IAaveProtocolDataProvider(0x057835Ad21a177dbdd3090bB1CAE03EaCF78Fc6d);

    address constant liquidationTarget = 0x63f6037d3e9d51ad865056BF7792029803b6eEfD;

    // USDC/WETH pair
    IUniswapV2Pair pair;
    bool usdcIsToken0;

    constructor() {
        pair = IUniswapV2Pair(
            uniswapV2Factory.getPair(address(USDC), address(WETH))
        );
        usdcIsToken0 = (pair.token0() == address(USDC));
    }

    receive() external payable {}

    function getAmountIn(
        uint256 amountOut,
        uint256 reserveIn,
        uint256 reserveOut
    ) internal pure returns (uint256) {
        uint256 numerator = reserveIn * amountOut * 1000;
        uint256 denominator = (reserveOut - amountOut) * 997;
        return (numerator / denominator) + 1;
    }

    function operate() external {
        (, , , , , uint256 healthFactor) =
            lendingPool.getUserAccountData(liquidationTarget);
        require(healthFactor < 1e18, "Health factor safe");

        // ดึงหนี้ USDC จริง
        (, , uint256 variableDebt, , , , , , ) =
            dataProvider.getUserReserveData(address(USDC), liquidationTarget);
        require(variableDebt > 0, "No USDC debt");

        // Aave จำกัด 50% ต่อครั้ง
        uint256 amountToLiquidate = variableDebt / 2;

        // Flash swap: กู้ USDC ออกมา
        bytes memory data = abi.encode(amountToLiquidate);
        if (usdcIsToken0) {
            pair.swap(amountToLiquidate, 0, address(this), data);
        } else {
            pair.swap(0, amountToLiquidate, address(this), data);
        }

        // แปลง WETH → ETH → ส่งกลับ caller
        uint256 wethBal = WETH.balanceOf(address(this));
        if (wethBal > 0) WETH.withdraw(wethBal);
        payable(msg.sender).transfer(address(this).balance);
    }

    function uniswapV2Call(
        address,
        uint256 amount0,
        uint256 amount1,
        bytes calldata
    ) external override {
        require(msg.sender == address(pair), "Unauthorized");

        uint256 usdcReceived = usdcIsToken0 ? amount0 : amount1;

        // 1. Liquidate: จ่ายหนี้ USDC แลก WETH collateral
        USDC.approve(address(lendingPool), usdcReceived);
        lendingPool.liquidationCall(
            address(WETH),  // collateral ที่รับกลับ
            address(USDC),  // debt token
            liquidationTarget,
            usdcReceived,
            false
        );

        // 2. คำนวณ WETH ที่ต้องคืน Uniswap (รวม fee 0.3%)
        (uint112 reserve0, uint112 reserve1, ) = pair.getReserves();
        uint256 repayWETH;
        if (usdcIsToken0) {
            // กู้ USDC (token0) ออก → คืน WETH (token1)
            // reserveIn = reserve1 (WETH), reserveOut = reserve0 (USDC)
            repayWETH = getAmountIn(usdcReceived, uint256(reserve1), uint256(reserve0));
        } else {
            // กู้ USDC (token1) ออก → คืน WETH (token0)
            repayWETH = getAmountIn(usdcReceived, uint256(reserve0), uint256(reserve1));
        }

        // 3. คืน WETH ให้ Uniswap
        require(WETH.balanceOf(address(this)) >= repayWETH, "Insufficient WETH");
        WETH.transfer(address(pair), repayWETH);
    }
}