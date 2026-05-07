const CHAINS = {
  56: {
    name: "BNB Chain",
    symbol: "BNB",
    hex: "0x38",
    rpc: "https://bsc-dataseed.binance.org/",
    explorer: "https://bscscan.com",
    alchemy: "https://bnb-mainnet.g.alchemy.com/v2/",
    dust_sweeper: "0x37bC5d034bD7a4861A67Ff9df8852D7144d1B404",
    router: "0x10ED43C718714eb63d5aA57B78B54704E256024E",
    weth: "0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c",
    logo: "🟡",
    color: "#f0c040",
    dexChain: "bsc"
  },
  8453: {
    name: "Base",
    symbol: "ETH",
    hex: "0x2105",
    rpc: "https://mainnet.base.org",
    explorer: "https://basescan.org",
    alchemy: "https://base-mainnet.g.alchemy.com/v2/",
    dust_sweeper: "0xf74f78750bBc2Ee7761D14f3200a2b1213bc5eB7",
    router: "0x4752ba5DBc23f44D87826276BF6Fd6b1C372aD24",
    weth: "0x4200000000000000000000000000000000000006",
    logo: "🔵",
    color: "#0052ff",
    dexChain: "base"
  }
};

const MULTICALL3 = "0xcA11bde05977b3631167028862bE2a173976CA11";

// Base Builder Code — ERC-8021 attribution suffix (from base.dev > Settings > Builder Codes)
// Per ERC-8021: suffix is appended AFTER the calldata so the EVM/contract ignores it.
// Format: 0x + app-tag (7 bytes) + 0x0080218021802180218021802180218021 (repeating 8021 sentinel)
const BASE_BUILDER_CODE_SUFFIX = "07626173656170700080218021802180218021802180218021";

/**
 * Returns tx data with the ERC-8021 Builder Code suffix appended for Base chain.
 * The suffix is pure calldata padding — Solidity ABI decoder ignores trailing bytes,
 * but Base nodes read it for attribution tracking on base.dev.
 * Safe no-op on any other chain (suffix never added).
 */
function withBuilderCode(encodedData, chainId) {
  if (chainId !== 8453) return encodedData;
  // encodedData starts with 0x — strip it, append suffix, re-add 0x prefix
  const base = encodedData.startsWith("0x") ? encodedData.slice(2) : encodedData;
  return "0x" + base + BASE_BUILDER_CODE_SUFFIX;
}

let activeChain = 56;
let provider, signer, userAddress;
let dustTokens = [];

const SWEEPER_ABI = [
  "function batchSweep(address[] tokens, uint256[] amounts, uint256 minBNBOut)"
];

const ERC20_ABI = [
  "function balanceOf(address) view returns (uint256)",
  "function decimals() view returns (uint8)",
  "function symbol() view returns (string)",
  "function name() view returns (string)",
  "function allowance(address,address) view returns (uint256)",
  "function approve(address,uint256) returns (bool)"
];

const MULTICALL_ABI = [
  "function aggregate3(tuple(address target, bool allowFailure, bytes callData)[] calls) view returns (tuple(bool success, bytes returnData)[] returnData)"
];

// --- UTILS ---
function showToast(msg, type = "info") {
  const container = document.getElementById("toast-container");
  const toast = document.createElement("div");
  toast.className = `toast ${type}`;
  toast.innerHTML = msg;
  container.appendChild(toast);
  setTimeout(() => toast.classList.add("show"), 10);
  setTimeout(() => {
    toast.classList.remove("show");
    setTimeout(() => toast.remove(), 300);
  }, 4000);
}

function formatAddress(addr) {
  return addr.substring(0, 6) + "..." + addr.substring(addr.length - 4);
}

// --- INITIALIZATION ---
document.addEventListener("DOMContentLoaded", () => {
  setChainUI(56);
});

window.switchChain = async function(chainId) {
  if (chainId === activeChain) return;

  if (window.ethereum) {
    try {
      const hex = CHAINS[chainId].hex;
      await window.ethereum.request({
        method: 'wallet_switchEthereumChain',
        params: [{ chainId: hex }],
      });
    } catch (err) {
      if (err.code === 4902) {
        await window.ethereum.request({
          method: 'wallet_addEthereumChain',
          params: [{
            chainId: CHAINS[chainId].hex,
            chainName: CHAINS[chainId].name,
            nativeCurrency: { name: CHAINS[chainId].symbol, symbol: CHAINS[chainId].symbol, decimals: 18 },
            rpcUrls: [CHAINS[chainId].rpc],
            blockExplorerUrls: [CHAINS[chainId].explorer]
          }]
        });
      } else {
        showToast("Failed to switch chain in wallet", "error");
        return;
      }
    }
  }

  setChainUI(chainId);
  
  if (userAddress) {
    window.scanTokens();
  }
};

function setChainUI(chainId) {
  activeChain = chainId;
  const chain = CHAINS[chainId];

  // Update tabs
  document.querySelectorAll(".chain-tab").forEach(tab => {
    tab.classList.remove("active");
    if (parseInt(tab.getAttribute("data-chain")) === chainId) {
      tab.classList.add("active");
    }
  });

  // Slider
  const slider = document.getElementById("chain-slider");
  if (chainId === 56) {
    slider.style.transform = "translateX(0)";
  } else {
    slider.style.transform = "translateX(100%)";
  }

  // Colors
  document.documentElement.style.setProperty("--accent", chain.color);

  // Texts
  document.getElementById("tagline").innerText = chain.name;
  document.getElementById("hero-sub").innerText = `Select dust tokens → One click → Get ${chain.symbol}`;
  document.getElementById("action-est").innerText = `Est. receive: 0.0000 ${chain.symbol} ≈ $0.00`;
  
  // Clear lists
  dustTokens = [];
  renderTokenList();
}

window.connectWallet = async function() {
  if (!window.ethereum) return showToast("Install MetaMask!", "error");

  try {
    const chainIdHex = await window.ethereum.request({ method: 'eth_chainId' });
    const cId = parseInt(chainIdHex, 16);
    
    if (cId !== activeChain && CHAINS[cId]) {
      await window.switchChain(cId);
    } else if (cId !== activeChain) {
      await window.switchChain(activeChain);
    }

    await window.ethereum.request({ method: 'eth_requestAccounts' });
    provider = new ethers.BrowserProvider(window.ethereum);
    signer = await provider.getSigner();
    userAddress = await signer.getAddress();

    const btnConnect = document.getElementById("btn-connect");
    btnConnect.innerHTML = `<span style="font-size: 18px; margin-right: 8px;">👤</span> ${formatAddress(userAddress)}`;
    btnConnect.classList.add("connected");

    showToast("Wallet connected", "success");
    
    // Auto scan since key is in env
    window.scanTokens();
  } catch (err) {
    console.error(err);
    showToast("Connection failed", "error");
  }
};

window.scanTokens = async function() {
  if (!userAddress) return showToast("Connect wallet first", "error");
  let apiKey;
  try {
    apiKey = import.meta.env.VITE_ALCHEMY_API_KEY;
  } catch (e) {
    return showToast("⚠️ Use 'npm run dev' to load the API key!", "error");
  }
  if (!apiKey) return showToast("Alchemy API Key is missing in .env", "error");

  const chain = CHAINS[activeChain];
  const alchemyUrl = chain.alchemy + apiKey;

  const btnScan = document.getElementById("btn-scan");
  btnScan.disabled = true;
  btnScan.innerText = "Scanning...";

  // show skeleton
  const tbody = document.getElementById("tokens-body");
  tbody.innerHTML = Array(5).fill(`
    <tr>
      <td><div class="skeleton" style="width:20px;"></div></td>
      <td>
        <div class="token-cell">
          <div class="skeleton circle"></div>
          <div class="token-name-sym" style="width: 100px;">
            <div class="skeleton" style="margin-bottom: 4px;"></div>
            <div class="skeleton" style="width: 60%;"></div>
          </div>
        </div>
      </td>
      <td class="hide-mobile"><div class="skeleton" style="width:80px;"></div></td>
      <td><div class="skeleton" style="width:60px;"></div></td>
    </tr>
  `).join("");

  async function alchemyPost(method, params) {
    const res = await fetch(alchemyUrl, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ jsonrpc: "2.0", method, params, id: 1 })
    });
    const json = await res.json();
    if (json.error) throw new Error(json.error.message);
    return json.result;
  }

  try {
    const balResult = await alchemyPost("alchemy_getTokenBalances", [userAddress]);
    const rawTokens = (balResult.tokenBalances || []).filter(t => t.tokenBalance && t.tokenBalance !== "0x0" && t.tokenBalance !== "0x");

    dustTokens = [];
    let totalFound = 0;
    
    for (const t of rawTokens) {
      let addr;
      try { addr = ethers.getAddress(t.contractAddress); } catch { continue; }
      if (addr.toLowerCase() === chain.weth.toLowerCase()) continue;

      let meta;
      try { meta = await alchemyPost("alchemy_getTokenMetadata", [t.contractAddress]); } catch { continue; }
      
      const decimals = meta.decimals ?? 18;
      const symbol = meta.symbol || "UNK";
      const name = meta.name || symbol;
      const logo = meta.logo || "";

      const rawHex = t.tokenBalance;
      const rawBigInt = BigInt(rawHex);
      if (rawBigInt === 0n) continue;
      const balNum = Number(rawBigInt) / Math.pow(10, decimals);
      if (balNum <= 0) continue;

      let priceUsd = 0;
      try {
        const dexRes = await fetch("https://api.dexscreener.com/latest/dex/tokens/" + addr);
        const dexData = await dexRes.json();
        const pairs = (dexData.pairs || []).filter(p => p.chainId === chain.dexChain && p.priceUsd);
        if (pairs.length > 0) priceUsd = parseFloat(pairs[0].priceUsd);
      } catch {}

      const valueUsd = balNum * priceUsd;
      
      if (priceUsd > 0 && valueUsd < 1.0) {
        totalFound++;
        dustTokens.push({
          address: addr, symbol, name, decimals, 
          balanceRaw: rawBigInt.toString(), balance: balNum, 
          priceUsd, valueUsd, logo
        });
      }
    }

    document.getElementById("stat-found").innerText = totalFound;
    renderTokenList();
    showToast(`Found ${totalFound} dust tokens!`, "success");

  } catch (err) {
    console.error(err);
    showToast("Scan failed: " + err.message, "error");
    tbody.innerHTML = `<tr><td colspan="4"><div class="empty-state">❌ Scan failed. Check API Key.</div></td></tr>`;
  } finally {
    btnScan.disabled = false;
    btnScan.innerText = "Scan Wallet";
  }
};

function renderTokenList() {
  const tbody = document.getElementById("tokens-body");
  if (dustTokens.length === 0) {
    tbody.innerHTML = `<tr><td colspan="4">
      <div class="empty-state">
        <div style="font-size: 40px; margin-bottom: 10px;">🧹</div>
        <p style="color: var(--text-dim); margin: 0;">No dust tokens found.</p>
      </div>
    </td></tr>`;
    updateStats();
    return;
  }

  tbody.innerHTML = "";
  dustTokens.forEach((t, i) => {
    const tr = document.createElement("tr");
    tr.innerHTML = `
      <td><input type="checkbox" class="t-chk" data-idx="${i}" onchange="window.updateStats()"></td>
      <td>
        <div class="token-cell">
          <div class="token-logo">
            ${t.logo ? `<img src="${t.logo}">` : t.symbol.substring(0,2).toUpperCase()}
          </div>
          <div class="token-name-sym">
            <span class="token-sym">${t.symbol}</span>
            <span class="token-name">${t.name}</span>
          </div>
        </div>
      </td>
      <td class="hide-mobile mono">${t.balance.toLocaleString(undefined, {maximumFractionDigits: 4})}</td>
      <td class="mono ${t.valueUsd < 1 ? 'value-low' : ''}">$${t.valueUsd.toFixed(3)}</td>
    `;
    tbody.appendChild(tr);
  });
  updateStats();
}

window.selectAll = function(check) {
  document.querySelectorAll(".t-chk").forEach(c => c.checked = check);
  window.updateStats();
};

window.updateStats = function() {
  const chks = document.querySelectorAll(".t-chk:checked");
  let val = 0;
  chks.forEach(c => {
    val += dustTokens[c.getAttribute("data-idx")].valueUsd;
  });

  const chain = CHAINS[activeChain];
  // rough conversion to native
  const ethPrice = activeChain === 56 ? 600 : 3000; 
  const nativeEst = val / ethPrice;

  document.getElementById("stat-selected").innerText = chks.length;
  document.getElementById("stat-value").innerText = `$${val.toFixed(2)}`;
  
  document.getElementById("action-selected").innerText = `${chks.length} tokens selected`;
  document.getElementById("action-est").innerText = `Est. receive: ${nativeEst.toFixed(4)} ${chain.symbol} ≈ $${val.toFixed(2)}`;

  const btn = document.getElementById("btn-sweep");
  btn.disabled = chks.length === 0;

  // Highlight rows
  document.querySelectorAll(".t-chk").forEach(c => {
    const tr = c.closest("tr");
    if (c.checked) tr.classList.add("selected");
    else tr.classList.remove("selected");
  });
};

function updateModal(stepId, state, textOverride) {
  const step = document.getElementById(stepId);
  if (!step) return;
  const icon = step.querySelector(".m-icon");
  const text = step.querySelector(".m-text");
  
  step.className = `modal-step ${state}`;
  if (state === "pending") {
    icon.innerText = "⏳";
    step.style.opacity = "0.5";
  } else if (state === "loading") {
    icon.innerHTML = `<div class="skeleton circle" style="width:16px;height:16px;border:2px solid var(--accent);border-top-color:transparent;background:transparent;border-radius:50%;animation:spin 1s linear infinite;"></div>`;
    step.style.opacity = "1";
    step.classList.add("active");
  } else if (state === "done") {
    icon.innerText = "✅";
    step.style.opacity = "1";
    step.classList.add("done");
  } else if (state === "skip") {
    icon.innerText = "⏭️";
    step.style.opacity = "1";
    step.classList.add("done");
  }
  
  if (textOverride) text.innerText = textOverride;
}

window.startSweepFlow = async function() {
  const chks = document.querySelectorAll(".t-chk:checked");
  if (chks.length === 0) return;

  const chain = CHAINS[activeChain];
  const tokens = [];
  const amounts = [];
  let totalUsd = 0;
  chks.forEach(c => {
    const idx = c.getAttribute("data-idx");
    tokens.push(dustTokens[idx].address);
    amounts.push(dustTokens[idx].balanceRaw);
    totalUsd += dustTokens[idx].valueUsd;
  });

  document.getElementById("sweep-modal").classList.add("active");
  updateModal("m-step1", "pending", "Step 1: Checking approvals");
  updateModal("m-step2", "pending", "Step 2: Batch approve TX");
  updateModal("m-step3", "pending", "Step 3: Selling tokens");
  updateModal("m-step4", "pending", `Step 4: ${chain.symbol} sent to wallet`);

  try {
    // Step 1: Check approvals
    updateModal("m-step1", "loading");
    const needsApproval = [];
    const mc = new ethers.Contract(MULTICALL3, MULTICALL_ABI, provider);
    const iface = new ethers.Interface(ERC20_ABI);
    
    const calls = tokens.map(t => ({
      target: t,
      allowFailure: true,
      callData: iface.encodeFunctionData("allowance", [userAddress, chain.dust_sweeper])
    }));
    
    const results = await mc.aggregate3(calls);
    for (let i = 0; i < tokens.length; i++) {
      let allowance = 0n;
      if (results[i].success && results[i].returnData !== "0x") {
        allowance = iface.decodeFunctionResult("allowance", results[i].returnData)[0];
      }
      if (allowance < BigInt(amounts[i])) {
        needsApproval.push(tokens[i]);
      }
    }
    updateModal("m-step1", "done");

    // Step 2: Sequential individual approvals (Multicall3 cannot approve on behalf of user)
    if (needsApproval.length > 0) {
      updateModal("m-step2", "loading", `Step 2: Approving ${needsApproval.length} token(s)…`);
      for (let i = 0; i < needsApproval.length; i++) {
        const tokenAddr = needsApproval[i];
        const tokenContract = new ethers.Contract(tokenAddr, ERC20_ABI, signer);
        updateModal("m-step2", "loading", `Step 2: Approve ${i + 1} / ${needsApproval.length}…`);
        try {
          // Build calldata and append ERC-8021 Builder Code suffix for Base
          const approveData = tokenContract.interface.encodeFunctionData("approve", [chain.dust_sweeper, ethers.MaxUint256]);
          const approveTx = await signer.sendTransaction({
            to: tokenAddr,
            data: withBuilderCode(approveData, activeChain)
          });
          await approveTx.wait();
        } catch (approveErr) {
          throw new Error(`Approval failed for token ${tokenAddr}: ${approveErr.reason || approveErr.message}`);
        }
      }
      updateModal("m-step2", "done");
    } else {
      updateModal("m-step2", "skip", "Already approved ✅");
    }

    // Step 3: Batch sell
    updateModal("m-step3", "loading");
    const sweeper = new ethers.Contract(chain.dust_sweeper, SWEEPER_ABI, signer);
    // Encode batchSweep calldata and append ERC-8021 Builder Code suffix for Base attribution
    const sweepData = sweeper.interface.encodeFunctionData("batchSweep", [tokens, amounts, 0]);
    const sellTx = await signer.sendTransaction({
      to: chain.dust_sweeper,
      data: withBuilderCode(sweepData, activeChain)
    });
    const receipt = await sellTx.wait();
    updateModal("m-step3", "done");

    // Step 4: Done
    document.getElementById("m-step4-text").innerText = `${chain.symbol} sent to wallet`;
    updateModal("m-step4", "done");

    setTimeout(() => {
      document.getElementById("sweep-modal").classList.remove("active");
      
      const ethPrice = activeChain === 56 ? 600 : 3000; 
      const nativeEst = totalUsd / ethPrice;
      
      showSuccessScreen(receipt, tokens.length, chain, nativeEst, totalUsd);
    }, 1000);

  } catch (err) {
    console.error(err);
    // Decode common revert reasons into user-friendly messages
    let msg = err.reason || err.message || "Unknown error";
    if (msg.includes("No ETH received") || msg.includes("No BNB received")) {
      msg = "Sweep failed: Selected tokens have no liquidity on this chain's DEX. Try selecting different tokens.";
    } else if (msg.includes("missing revert data") || msg.includes("CALL_EXCEPTION")) {
      msg = "Contract call failed. The contract address may be wrong for this chain, or tokens lack DEX liquidity.";
    } else if (msg.includes("Slippage")) {
      msg = "Slippage too high — market moved. Try again.";
    } else if (msg.includes("user rejected") || msg.includes("User denied")) {
      msg = "Transaction rejected by user.";
    }
    showToast("❌ " + msg, "error");
    document.getElementById("sweep-modal").classList.remove("active");
  }
};

function showSuccessScreen(receipt, count, chain, nativeReceived, usdReceived) {
  document.getElementById("success-modal").classList.add("active");
  document.getElementById("success-title").innerText = `${count} tokens swept!`;
  document.getElementById("success-received").innerText = `You received ~${nativeReceived.toFixed(4)} ${chain.symbol}`;
  document.getElementById("success-usd").innerText = `≈ $${usdReceived.toFixed(2)} USD`;
}

window.closeModal = function() {
  document.getElementById("sweep-modal").classList.remove("active");
}

window.closeSuccessAndRescan = function() {
  document.getElementById("success-modal").classList.remove("active");
  window.scanTokens();
}
