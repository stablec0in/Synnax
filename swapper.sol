// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// INTERFACE
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IAsset {
    // solhint-disable-previous-line no-empty-blocks
}
// il faut un truc pour 
interface Ivault {
    enum SwapKind { GIVEN_IN, GIVEN_OUT }

    struct FundManagement {
        address sender;
        bool fromInternalBalance;
        address payable recipient;
        bool toInternalBalance;
    }

    struct BatchSwapStep {
        bytes32 poolId;
        uint256 assetInIndex;
        uint256 assetOutIndex;
        uint256 amount;
        bytes userData;
    }
    function batchSwap(
        SwapKind kind,
        BatchSwapStep[] memory swaps,
        IAsset[] memory assets,
        FundManagement memory funds,
        int256[] memory limits,
        uint256 deadline
    ) external payable returns (int256[] memory);
}

contract Swapper {
    using SafeERC20 for IERC20;

    address public owner;
    Ivault public vault;
    bytes32 public poolId;

    constructor(address _vault, bytes32 _poolId) {
        owner = msg.sender;
        vault = Ivault(_vault);
        poolId = _poolId;
    }

    // importer la logique ici ? 

    function swap(address asset_in, address asset_out, uint256 amount_in, uint256 min_amount_out) external returns (uint256 amountOut) {
        // Approve vault to pull tokens
        IERC20(asset_in).safeTransferFrom(msg.sender, address(this), amount_in);
        IERC20(asset_in).safeIncreaseAllowance(address(vault), amount_in);

        Ivault.BatchSwapStep[] memory swaps = (new Ivault.BatchSwapStep[](1));
        swaps[0] = Ivault.BatchSwapStep({
            poolId: poolId,
            assetInIndex: 0,
            assetOutIndex: 1,
            amount: amount_in,
            userData: ""
        });

        IAsset[] memory assets = (new IAsset[])(2);
        assets[0] = IAsset(asset_in);
        assets[1] = IAsset(asset_out);

        Ivault.FundManagement memory funds = Ivault.FundManagement({
            sender: address(this),
            fromInternalBalance: false,
            recipient: payable(msg.sender),
            toInternalBalance: false
        });

        int256[] memory limits = (new int256[])(2);
        limits[0] =  int256(amount_in);         // Max amount in
        limits[1] =  -int256(min_amount_out);   // Min amount out (negative because it's an outflow)

        int256[] memory result = vault.batchSwap(
            Ivault.SwapKind.GIVEN_IN,
            swaps,
            assets,
            funds,
            limits,
            block.timestamp
        );
        amountOut = uint256(-result[1]); // Because it's an outflow
        require(amountOut >= min_amount_out, "Slippage too high");
        return amountOut;
    }
}
