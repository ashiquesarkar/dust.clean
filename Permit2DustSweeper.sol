// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

// ============================================================
//  Permit2 Dust Sweeper — BSC Mainnet
//  Batch-sell dust tokens via Permit2 signature + PancakeSwap V2
// ============================================================

// ----- Interfaces -------------------------------------------

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

// Interface matches the real canonical Permit2 deployment ABI exactly.
// Source verified: github.com/Uniswap/permit2 → src/interfaces/ISignatureTransfer.sol
// Both `permit` (memory) and `transferDetails` (calldata) match the deployed selector.
interface IPermit2 {
    struct TokenPermissions {
        address token;
        uint256 amount;
    }

    struct PermitBatchTransferFrom {
        TokenPermissions[] permitted;
        uint256 nonce;
        uint256 deadline;
    }

    struct SignatureTransferDetails {
        address to;
        uint256 requestedAmount;
    }

    function permitTransferFrom(
        PermitBatchTransferFrom memory permit,
        SignatureTransferDetails[] calldata transferDetails,
        address owner,
        bytes calldata signature
    ) external;
}

// Interface matches the real PancakeSwap V2 router ABI exactly.
// `path` is `calldata` in the deployed router — must match here.
interface IPancakeRouter {
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

// ----- Contract ---------------------------------------------

contract Permit2DustSweeper {
    // ── Constants ──────────────────────────────────────────────
    address public constant PERMIT2    = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address public constant PANCAKE_V2 = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address public constant WBNB       = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;

    // ── State ─────────────────────────────────────────────────
    address public owner;
    uint256 public feeBps = 50; // 0.5%

    // Tracks protocol fees banked inside the contract so that bnbBefore
    // snapshots in _swapAndDeliver are never inflated by prior fee balances.
    uint256 public accumulatedFees;

    // ── Events ────────────────────────────────────────────────
    event Swept(address indexed user, uint256 tokenCount, uint256 bnbOut);
    event FeeSet(uint256 newFeeBps);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event TokenRescued(address indexed token, address indexed to, uint256 amount);

    // ── Modifiers ─────────────────────────────────────────────
    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    // ── Constructor ───────────────────────────────────────────
    constructor() {
        owner = msg.sender;
    }

    // ── Main: sweepDust ───────────────────────────────────────
    /// @notice Pull dust tokens via Permit2 batch signature, swap each on
    ///         PancakeSwap V2, and send BNB to caller minus a protocol fee.
    ///
    /// @dev    Off-chain prerequisites (caller must complete both):
    ///         1. Call `token.approve(PERMIT2, amount)` for each token.
    ///         2. Sign the EIP-712 PermitBatchTransferFrom message and supply
    ///            the resulting bytes as `signature`.
    ///
    /// @param tokens      ERC-20 addresses to sell (1–25).
    /// @param amounts     Parallel token amounts in their smallest unit.
    /// @param nonce       Random nonce embedded in the Permit2 signature.
    /// @param deadline    Permit2 signature expiry timestamp.
    /// @param signature   EIP-712 batch-permit signature from the token owner.
    /// @param minBNBOut   Minimum BNB expected by the caller AFTER fee deduction.
    function sweepDust(
        address[] calldata tokens,
        uint256[] calldata amounts,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature,
        uint256 minBNBOut
    ) external {
        uint256 len = tokens.length;
        require(len > 0 && len <= 25, "1-25 tokens");
        require(len == amounts.length, "Length mismatch");

        // Copy calldata arrays to memory so internal helpers can accept them.
        // `calldata` is only valid in external functions; passing calldata
        // slices into internal functions requires converting to memory first.
        address[] memory tokensMem  = new address[](len);
        uint256[] memory amountsMem = new uint256[](len);
        for (uint256 i = 0; i < len; i++) {
            tokensMem[i]  = tokens[i];
            amountsMem[i] = amounts[i];
        }

        _pullTokens(tokensMem, amountsMem, nonce, deadline, signature);

        uint256 bnbToUser = _swapAndDeliver(tokensMem, minBNBOut);

        emit Swept(msg.sender, len, bnbToUser);
    }

    // ── Internal: _pullTokens ─────────────────────────────────
    /// @dev Atomically pulls all tokens from the caller via a single
    ///      Permit2 batch-transfer call.
    ///
    ///      Parameters are `memory` because this is an internal function.
    ///      Solidity only allows `calldata` on `external` functions.
    function _pullTokens(
        address[] memory tokens,
        uint256[] memory amounts,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) internal {
        uint256 len = tokens.length;

        IPermit2.TokenPermissions[]        memory permitted = new IPermit2.TokenPermissions[](len);
        IPermit2.SignatureTransferDetails[] memory details   = new IPermit2.SignatureTransferDetails[](len);

        for (uint256 i = 0; i < len; i++) {
            permitted[i] = IPermit2.TokenPermissions({
                token:  tokens[i],
                amount: amounts[i]
            });
            details[i] = IPermit2.SignatureTransferDetails({
                to:              address(this),
                requestedAmount: amounts[i]
            });
        }

        // The interface declares `transferDetails` as calldata to match the
        // real Permit2 ABI selector. The compiler will ABI-encode `details`
        // (a memory array) into the call's calldata automatically.
        IPermit2(PERMIT2).permitTransferFrom(
            IPermit2.PermitBatchTransferFrom({
                permitted: permitted,
                nonce:     nonce,
                deadline:  deadline
            }),
            details,
            msg.sender,
            signature
        );
    }

    // ── Internal: _swapAndDeliver ─────────────────────────────
    /// @dev Swaps each held token to BNB on PancakeSwap V2, deducts the
    ///      protocol fee, and forwards the remainder to the caller.
    ///
    ///      `tokens` is `memory` — required for internal functions.
    function _swapAndDeliver(
        address[] memory tokens,
        uint256 minBNBOut
    ) internal returns (uint256 bnbToUser) {
        // Snapshot excludes accumulated fees so they do not inflate bnbBefore
        // and under-count BNB produced by this sweep.
        uint256 bnbBefore = address(this).balance - accumulatedFees;
        uint256 len       = tokens.length;

        for (uint256 i = 0; i < len; i++) {
            address token = tokens[i];
            uint256 bal   = IERC20(token).balanceOf(address(this));
            if (bal == 0) continue;

            // Reset allowance to 0 first — required by USDT-style tokens
            // that revert on a non-zero → non-zero approve transition.
            try IERC20(token).approve(PANCAKE_V2, 0)   {} catch {}
            try IERC20(token).approve(PANCAKE_V2, bal) {} catch { continue; }

            // Fresh path array per iteration — avoids shared-reference bugs
            // that would persist a stale token address across loop iterations.
            address[] memory path = new address[](2);
            path[0] = token;
            path[1] = WBNB;

            try IPancakeRouter(PANCAKE_V2)
                .swapExactTokensForETHSupportingFeeOnTransferTokens(
                    bal,
                    0,               // per-token floor is 0 (dust);
                    path,            // aggregate floor enforced by minBNBOut below
                    address(this),
                    block.timestamp + 300
                )
            {
                // Clear any residual allowance after a successful swap.
                try IERC20(token).approve(PANCAKE_V2, 0) {} catch {}
            } catch {
                // Swap failed — token remains in contract.
                // Owner can recover it via rescueToken().
                try IERC20(token).approve(PANCAKE_V2, 0) {} catch {}
            }
        }

        uint256 totalBNB = address(this).balance - accumulatedFees - bnbBefore;

        uint256 fee = (totalBNB * feeBps) / 10_000;
        bnbToUser   = totalBNB - fee;

        // minBNBOut is checked against the POST-FEE amount the caller receives,
        // not the pre-fee gross — prevents the fee from eating into the user's floor.
        require(bnbToUser >= minBNBOut, "Slippage: insufficient BNB after fee");

        // Book the fee before sending so future snapshots stay accurate.
        accumulatedFees += fee;

        if (bnbToUser > 0) {
            (bool ok, ) = payable(msg.sender).call{value: bnbToUser}("");
            require(ok, "BNB transfer failed");
        }
    }

    // ── Admin ─────────────────────────────────────────────────

    /// @notice Withdraw accumulated protocol fees only.
    ///         Does NOT drain the full contract balance, which would risk
    ///         pulling BNB from failed-swap residuals.
    function withdrawFees() external onlyOwner {
        uint256 amount = accumulatedFees;
        require(amount > 0, "No fees");
        accumulatedFees = 0;                          // zero before transfer (re-entrancy safe)
        (bool ok, ) = payable(owner).call{value: amount}("");
        require(ok, "Withdraw failed");
    }

    /// @notice Recover ERC-20 tokens stranded by a failed swap.
    /// @param token  Token contract address.
    /// @param to     Recipient (non-zero).
    function rescueToken(address token, address to) external onlyOwner {
        require(to != address(0), "Zero address");
        uint256 bal = IERC20(token).balanceOf(address(this));
        require(bal > 0, "Nothing to rescue");
        (bool ok, ) = token.call(
            abi.encodeWithSignature("transfer(address,uint256)", to, bal)
        );
        require(ok, "Token rescue failed");
        emit TokenRescued(token, to, bal);
    }

    /// @notice Update protocol fee. Maximum 2%.
    function setFee(uint256 newFeeBps) external onlyOwner {
        require(newFeeBps <= 200, "Max 2%");
        feeBps = newFeeBps;
        emit FeeSet(newFeeBps);
    }

    /// @notice Transfer contract ownership.
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Zero address");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    // ── Receive BNB from PancakeSwap callbacks ────────────────
    receive() external payable {}
}
