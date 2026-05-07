// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

// Uniswap V2-compatible router interface (works with BaseSwap / Aerodrome V2-compat routers)
interface IUniswapV2Router {
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

/// @title  DustSweeperBase
/// @notice Sweeps ERC-20 "dust" tokens → ETH on Base Mainnet via a Uniswap V2-fork router.
///         Deployed at: 0xf74f78750bBc2Ee7761D14f3200a2b1213bc5eB7
/// @dev    v2 — adds emergency pause, approve-reset pattern, richer events, per-token tracking.
contract DustSweeperBase {

    // ─────────────────────────────────────────────────────────────────────────
    // State
    // ─────────────────────────────────────────────────────────────────────────
    address public owner;
    uint256 public feeBps = 50;          // 0.5% default fee
    uint256 public accumulatedFees;
    bool    public paused;               // emergency circuit-breaker

    /// @notice Base Mainnet — Uniswap V2 fork (same address as on Ethereum)
    address public constant UNISWAP_V2_ROUTER = 0x4752ba5DBc23f44D87826276BF6Fd6b1C372aD24;
    /// @notice WETH on Base Mainnet
    address public constant WETH             = 0x4200000000000000000000000000000000000006;

    string  public constant VERSION = "2.0.0";

    // ─────────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────────
    event Swept(
        address indexed user,
        uint256 tokenCount,      // how many tokens were submitted
        uint256 soldCount,       // how many actually sold successfully
        uint256 ethOut,          // net ETH sent to user (after fee)
        uint256 fee              // protocol fee collected
    );
    event FeeSet(uint256 oldFeeBps, uint256 newFeeBps);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event Paused(address by);
    event Unpaused(address by);
    event FeesWithdrawn(address indexed to, uint256 amount);
    event TokenRescued(address indexed token, address indexed to, uint256 amount);

    // ─────────────────────────────────────────────────────────────────────────
    // Modifiers
    // ─────────────────────────────────────────────────────────────────────────
    modifier onlyOwner() {
        require(msg.sender == owner, "DS: not owner");
        _;
    }

    modifier whenNotPaused() {
        require(!paused, "DS: paused");
        _;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────────────────────
    constructor() {
        owner = msg.sender;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Core: batchSweep
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Convert up to 25 ERC-20 dust tokens to ETH in one transaction.
     * @param tokens     Array of token contract addresses.
     * @param amounts    Corresponding raw (wei-denominated) amounts to sweep.
     * @param minETHOut  Minimum net ETH the caller must receive (slippage guard).
     *
     * Flow per token:
     *   1. Pull tokens from caller.
     *   2. Reset allowance to 0, then approve router for exact amount (USDT-safe).
     *   3. Swap token → ETH via the Uniswap V2-fork router.
     *   Any individual failure is skipped gracefully — the batch continues.
     */
    function batchSweep(
        address[] calldata tokens,
        uint256[] calldata amounts,
        uint256 minETHOut
    ) external whenNotPaused {
        require(tokens.length > 0 && tokens.length <= 25, "DS: invalid length");
        require(tokens.length == amounts.length,          "DS: length mismatch");

        uint256 ethBefore  = address(this).balance - accumulatedFees;
        uint256 soldCount  = 0;

        for (uint256 i = 0; i < tokens.length; i++) {
            address token  = tokens[i];
            uint256 amount = amounts[i];
            if (amount == 0 || token == address(0)) continue;

            // ── 1. Pull tokens ───────────────────────────────────────────────
            bool pulled;
            try IERC20(token).transferFrom(msg.sender, address(this), amount) returns (bool ok) {
                pulled = ok;
            } catch {
                pulled = false;
            }
            if (!pulled) continue;

            // ── 2. Approve router (reset first for USDT-style tokens) ────────
            //    Some tokens revert if you approve a non-zero → non-zero amount.
            try IERC20(token).approve(UNISWAP_V2_ROUTER, 0)   {} catch {}
            bool approved;
            try IERC20(token).approve(UNISWAP_V2_ROUTER, amount) returns (bool ok) {
                approved = ok;
            } catch {
                approved = false;
            }
            if (!approved) {
                // Return tokens to sender rather than locking them
                try IERC20(token).transfer(msg.sender, amount) {} catch {}
                continue;
            }

            // ── 3. Swap token → ETH ──────────────────────────────────────────
            address[] memory path = new address[](2);
            path[0] = token;
            path[1] = WETH;

            try IUniswapV2Router(UNISWAP_V2_ROUTER)
                .swapExactTokensForETHSupportingFeeOnTransferTokens(
                    amount,
                    0,                        // no per-token slippage (checked globally below)
                    path,
                    address(this),
                    block.timestamp + 300
                )
            {
                soldCount++;
            } catch {
                // No liquidity — reset approval and continue
                try IERC20(token).approve(UNISWAP_V2_ROUTER, 0) {} catch {}
            }
        }

        uint256 totalETH = address(this).balance - accumulatedFees - ethBefore;
        require(totalETH > 0, "DS: no ETH received (tokens lack liquidity on Base)");

        uint256 fee        = (totalETH * feeBps) / 10000;
        uint256 userAmount = totalETH - fee;
        require(userAmount >= minETHOut, "DS: slippage too high");

        accumulatedFees += fee;

        (bool sent, ) = payable(msg.sender).call{value: userAmount}("");
        require(sent, "DS: ETH transfer failed");

        emit Swept(msg.sender, tokens.length, soldCount, userAmount, fee);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Owner functions
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Withdraw accumulated protocol fees to the owner.
    function withdrawFees() external onlyOwner {
        uint256 amount = accumulatedFees;
        require(amount > 0, "DS: nothing to withdraw");
        accumulatedFees = 0;
        (bool ok, ) = payable(owner).call{value: amount}("");
        require(ok, "DS: withdraw failed");
        emit FeesWithdrawn(owner, amount);
    }

    /// @notice Update the protocol fee (max 2 %).
    function setFee(uint256 _feeBps) external onlyOwner {
        require(_feeBps <= 200, "DS: max 2%");
        emit FeeSet(feeBps, _feeBps);
        feeBps = _feeBps;
    }

    /// @notice Transfer contract ownership.
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "DS: zero address");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    /// @notice Emergency pause — halts all sweeps.
    function pause() external onlyOwner {
        paused = true;
        emit Paused(msg.sender);
    }

    /// @notice Resume sweeps after a pause.
    function unpause() external onlyOwner {
        paused = false;
        emit Unpaused(msg.sender);
    }

    /**
     * @notice Rescue ETH or ERC-20 tokens that are stuck in this contract
     *         (e.g. from a failed swap that left tokens behind).
     * @param token  Token address, or address(0) to rescue raw ETH.
     * @param to     Recipient address.
     */
    function rescueToken(address token, address to) external onlyOwner {
        require(to != address(0), "DS: zero address");
        if (token == address(0)) {
            uint256 bal = address(this).balance - accumulatedFees;
            require(bal > 0, "DS: nothing to rescue");
            (bool ok, ) = payable(to).call{value: bal}("");
            require(ok, "DS: rescue failed");
            emit TokenRescued(address(0), to, bal);
        } else {
            uint256 bal = IERC20(token).balanceOf(address(this));
            require(bal > 0, "DS: nothing to rescue");
            IERC20(token).transfer(to, bal);
            emit TokenRescued(token, to, bal);
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // View helpers
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Returns the contract version string.
    function getVersion() external pure returns (string memory) {
        return VERSION;
    }

    /// @notice Returns the current fee in basis points and as a human-readable percentage.
    function getFeeInfo() external view returns (uint256 bps, string memory pct) {
        bps = feeBps;
        // e.g. feeBps=50 → "0.50%"
        uint256 whole   = bps / 100;
        uint256 decimal = bps % 100;
        pct = string(abi.encodePacked(
            _toString(whole), ".",
            decimal < 10 ? "0" : "", _toString(decimal), "%"
        ));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Internals
    // ─────────────────────────────────────────────────────────────────────────

    function _toString(uint256 v) internal pure returns (string memory) {
        if (v == 0) return "0";
        uint256 tmp = v;
        uint256 digits;
        while (tmp != 0) { digits++; tmp /= 10; }
        bytes memory buf = new bytes(digits);
        while (v != 0) { digits--; buf[digits] = bytes1(uint8(48 + v % 10)); v /= 10; }
        return string(buf);
    }

    receive() external payable {}
}
