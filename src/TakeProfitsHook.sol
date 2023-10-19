// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {BaseHook} from "periphery-next/BaseHook.sol";
import {ERC1155} from "openzeppelin-contracts/contracts/token/ERC1155/ERC1155.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";

contract TakeProfitsHook is BaseHook, ERC1155 {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using FixedPointMathLib for uint256;

    mapping(PoolId poolId => int24 tickLower) public tickLowerLasts;

    /**
     * @notice zeroForOne: Determine which direction the swap is going
     * (true: token 0 for token 1, false: token 1 for token 0)
     */
    mapping(PoolId poolId => mapping(int24 tick => mapping(bool zeroForOne => int256 amount))) public
        takeProfitPositions;

    // ERC-1155 State
    // tokenIdExists is a mapping to store whether a given tokenId (i.e. a take-profit order) exists
    mapping(uint256 tokenId => bool exists) public tokenIdExists;
    // tokenIdClaimable is a mapping that stores how many swapped tokens are claimable for a given tokenId
    mapping(uint256 tokenId => uint256 claimable) public tokenIdClaimable;
    // tokenIdTotalSupply is a mapping that stores how many tokens need to be sold to execute the take-profit order
    mapping(uint256 tokenId => uint256 supply) public tokenIdTotalSupply;
    // tokenIdData is a mapping that stores the PoolKey, tickLower, and zeroForOne values for a given tokenId
    mapping(uint256 tokenId => TokenData) public tokenIdData;

    struct TokenData {
        PoolKey poolKey;
        int24 tick;
        bool zeroForOne;
    }

    // Initialize BaseHook and ERC1155 parent contrafts in the constructor
    constructor(IPoolManager _poolManager, string memory _uri) BaseHook(_poolManager) ERC1155(_uri) {}

    // Required override function for BaseHook to let the PoolManager know which hooks are implemented
    function getHooksCalls() public pure override returns (Hooks.Calls memory) {
        return Hooks.Calls({
            beforeInitialize: false,
            afterInitialize: true,
            beforeModifyPosition: false,
            afterModifyPosition: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false
        });
    }

    // Hooks
    function afterInitialize(address, PoolKey calldata key, uint160, int24 tick, bytes calldata)
        external
        override
        poolManagerOnly
        returns (bytes4)
    {
        _setTickLowerLast(key.toId(), _getTickLower(tick, key.tickSpacing));

        return TakeProfitsHook.afterInitialize.selector;
    }

    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta,
        bytes calldata
    ) external override poolManagerOnly returns (bytes4) {
        int24 lastTickLower = tickLowerLasts[key.toId()];

        (, int24 currentTick,,) = poolManager.getSlot0(key.toId());
        int24 currentTickLower = _getTickLower(currentTick, key.tickSpacing);

        bool swapZeroForOne = !params.zeroForOne;
        int256 swapAmountIn;

        // Tick has incresased i.e. price of Token 0 has increased
        if (lastTickLower < currentTickLower) {
            for (int24 tick = lastTickLower; tick < currentTickLower;) {
                swapAmountIn = takeProfitPositions[key.toId()][tick][swapZeroForOne];

                if (swapAmountIn > 0) {
                    fillOrder(key, tick, swapZeroForOne, swapAmountIn);
                }

                tick += key.tickSpacing;
            }
        } else {
            for (int24 tick = lastTickLower; currentTickLower < tick;) {
                swapAmountIn = takeProfitPositions[key.toId()][tick][swapZeroForOne];

                if (swapAmountIn > 0) {
                    fillOrder(key, tick, swapZeroForOne, swapAmountIn);
                }

                tick -= key.tickSpacing;
            }
        }

        tickLowerLasts[key.toId()] = currentTickLower;

        return TakeProfitsHook.afterSwap.selector;
    }

    // Core Utilities
    function placeOrder(PoolKey calldata key, int24 tick, uint256 amountIn, bool zeroForOne) external returns (int24) {
        int24 tickLower = _getTickLower(tick, key.tickSpacing);

        takeProfitPositions[key.toId()][tickLower][zeroForOne] += int256(amountIn);

        uint256 tokenId = getTokenId(key, tickLower, zeroForOne);
        if (!tokenIdExists[tokenId]) {
            tokenIdExists[tokenId] = true;
            tokenIdData[tokenId] = TokenData(key, tickLower, zeroForOne);
        }

        _mint(msg.sender, tokenId, amountIn, "");
        tokenIdTotalSupply[tokenId] += amountIn;

        address tokenToBeSoldContract = zeroForOne ? Currency.unwrap(key.currency0) : Currency.unwrap(key.currency1);

        IERC20(tokenToBeSoldContract).transferFrom(msg.sender, address(this), amountIn);

        return tickLower;
    }

    function cancelOrder(PoolKey calldata key, int24 tick, bool zeroForOne) external {
        int24 tickLower = _getTickLower(tick, key.tickSpacing);
        uint256 tokenId = getTokenId(key, tickLower, zeroForOne);

        // balanceOf is coming from ERC-1155
        uint256 amountIn = balanceOf(msg.sender, tokenId);
        require(amountIn > 0, "TakeProfitsHook: No orders to cancel");

        takeProfitPositions[key.toId()][tickLower][zeroForOne] -= int256(amountIn);
        tokenIdTotalSupply[tokenId] -= amountIn;
        _burn(msg.sender, tokenId, amountIn);

        address tokenToBeSoldContract = zeroForOne ? Currency.unwrap(key.currency0) : Currency.unwrap(key.currency1);

        IERC20(tokenToBeSoldContract).transfer(msg.sender, amountIn);
    }

    function fillOrder(PoolKey calldata key, int24 tick, bool zeroForOne, int256 amountIn) internal {
        IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amountIn,
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1
        });

        BalanceDelta delta =
            abi.decode(poolManager.lock(abi.encodeCall(this._handleSwap, (key, swapParams))), (BalanceDelta));

        takeProfitPositions[key.toId()][tick][zeroForOne] -= amountIn;

        uint256 tokenId = getTokenId(key, tick, zeroForOne);

        uint256 amountOfTokensReceivedFromSwap =
            zeroForOne ? uint256(int256(-delta.amount1())) : uint256(int256(-delta.amount0()));

        tokenIdClaimable[tokenId] += amountOfTokensReceivedFromSwap;
    }

    function redeem(uint256 tokenId, uint256 amountIn, address destination) external {
        require(tokenIdClaimable[tokenId] > 0, "TakeProfitsHook: No tokens to redeem");

        uint256 balance = balanceOf(msg.sender, tokenId);
        require(balance >= amountIn, "TakeProfitsHook: Not enough ERC1155 tokens to redeem requested amount");

        TokenData memory data = tokenIdData[tokenId];
        address tokenToSendContract =
            data.zeroForOne ? Currency.unwrap(data.poolKey.currency1) : Currency.unwrap(data.poolKey.currency0);

        // multiple people could have added tokens to the same order, so we need to calculate the amount to send
        // total supply = total amount of tokens that were part of the order to be sold
        // therefore, user's share = (amountIn / total supply)
        // therefore, amount to send to user = (user's share * total claimable)

        // amountToSend = amountIn * (total claimable / total supply)
        // We use FixedPointMathLib.mulDivDown to avoid rounding errors
        uint256 amountToSend = amountIn.mulDivDown(tokenIdClaimable[tokenId], tokenIdTotalSupply[tokenId]);

        tokenIdClaimable[tokenId] -= amountToSend;
        tokenIdTotalSupply[tokenId] -= amountIn;
        _burn(msg.sender, tokenId, amountIn);

        IERC20(tokenToSendContract).transfer(destination, amountToSend);
    }

    function _handleSwap(PoolKey calldata key, IPoolManager.SwapParams calldata params)
        external
        returns (BalanceDelta)
    {
        BalanceDelta delta = poolManager.swap(key, params, "");

        if (params.zeroForOne) {
            if (delta.amount0() > 0) {
                IERC20(Currency.unwrap(key.currency0)).transfer(address(poolManager), uint128(delta.amount0()));
                poolManager.settle(key.currency0);
            }

            if (delta.amount1() < 0) {
                poolManager.take(key.currency1, address(this), uint128(-delta.amount1()));
            }
        } else {
            if (delta.amount1() > 0) {
                IERC20(Currency.unwrap(key.currency1)).transfer(address(poolManager), uint128(delta.amount1()));
                poolManager.settle(key.currency1);
            }
            if (delta.amount0() < 0) {
                poolManager.take(key.currency0, address(this), uint128(-delta.amount0()));
            }
        }

        return delta;
    }

    // ERC-1155 Helpers
    function getTokenId(PoolKey calldata key, int24 tickLower, bool zeroForOne) public pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(key.toId(), tickLower, zeroForOne)));
    }

    // Helper Functions
    function _setTickLowerLast(PoolId poolId, int24 tickLower) private {
        tickLowerLasts[poolId] = tickLower;
    }

    function _getTickLower(int24 actualTick, int24 tickSpacing) private pure returns (int24) {
        int24 intervals = actualTick / tickSpacing;
        // actualTick can be negative, and if it is, it's neccesary to substract one for the interval to be rounded correctly
        if (actualTick < 0 && (actualTick % tickSpacing) != 0) {
            intervals--;
        }
        return intervals * tickSpacing;
    }
}
