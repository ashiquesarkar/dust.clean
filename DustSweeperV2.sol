// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    // Added transfer for rescueToken
    function transfer(address to, uint256 amount) external returns (bool);
}

interface IPancakeRouter {
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

contract DustSweeperV2 {
    address public owner;
    uint256 public feeBps = 50;
    uint256 public accumulatedFees;

    address constant PANCAKE_V2 = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;

    event Swept(address indexed user, uint256 count, uint256 bnbOut);
    event FeeSet(uint256 feeBps);

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    function batchSweep(
        address[] calldata tokens,
        uint256[] calldata amounts,
        uint256 minBNBOut
    ) external {
        require(tokens.length > 0 && tokens.length <= 25, "Invalid length");
        require(tokens.length == amounts.length, "Length mismatch");

        uint256 bnbBefore = address(this).balance - accumulatedFees;

        for (uint256 i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            uint256 amount = amounts[i];

            // 1. transferFrom msg.sender to this contract
            try IERC20(token).transferFrom(msg.sender, address(this), amount) returns (bool success) {
                if (!success) continue;
            } catch {
                continue;
            }

            // 2. approve PancakeSwap router
            try IERC20(token).approve(PANCAKE_V2, amount) returns (bool success) {
                if (!success) continue;
            } catch {
                continue;
            }

            // 3. try swap
            address[] memory path = new address[](2);
            path[0] = token;
            path[1] = WBNB;

            try IPancakeRouter(PANCAKE_V2).swapExactTokensForETHSupportingFeeOnTransferTokens(
                amount,
                0, // amountOutMin
                path,
                address(this),
                block.timestamp + 300
            ) {
                // Swap successful
            } catch {
                // Swap failed, continue to next token
            }
        }

        uint256 totalBNB = address(this).balance - accumulatedFees - bnbBefore;
        require(totalBNB > 0, "No BNB received");
        
        uint256 fee = (totalBNB * feeBps) / 10000;
        uint256 userAmount = totalBNB - fee;
        require(userAmount >= minBNBOut, "Slippage");
        
        accumulatedFees += fee;
        
        (bool ok, ) = payable(msg.sender).call{value: userAmount}("");
        require(ok, "BNB send failed");
        
        emit Swept(msg.sender, tokens.length, userAmount);
    }

    function withdrawFees() external onlyOwner {
        uint256 amount = accumulatedFees;
        accumulatedFees = 0;
        (bool ok, ) = payable(owner).call{value: amount}("");
        require(ok, "Withdraw failed");
    }

    function setFee(uint256 _feeBps) external onlyOwner {
        require(_feeBps <= 200, "Max 2%");
        feeBps = _feeBps;
        emit FeeSet(_feeBps);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Zero address");
        owner = newOwner;
    }

    function rescueToken(address token, address to) external onlyOwner {
        if (token == address(0)) {
            uint256 balance = address(this).balance - accumulatedFees;
            (bool ok, ) = payable(to).call{value: balance}("");
            require(ok, "Rescue failed");
        } else {
            uint256 balance = IERC20(token).balanceOf(address(this));
            IERC20(token).transfer(to, balance);
        }
    }

    receive() external payable {}
}
