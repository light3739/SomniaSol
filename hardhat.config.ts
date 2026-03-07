import hardhatToolboxViemPlugin from "@nomicfoundation/hardhat-toolbox-viem";
import { defineConfig } from "hardhat/config";
import "dotenv/config";

const ACCOUNTS = [process.env.PRIVATE_KEY!].filter(Boolean);
const SOMNIA_MAINNET_RPC = process.env.SOMNIA_MAINNET_RPC_URL ?? "https://api.infra.mainnet.somnia.network/";
const SOMNIA_TESTNET_RPC = process.env.SOMNIA_TESTNET_RPC_URL ?? "https://dream-rpc.somnia.network/";
const AVALANCHE_FUJI_RPC = process.env.AVALANCHE_FUJI_RPC_URL ?? "https://api.avax-test.network/ext/bc/C/rpc";
const AVALANCHE_MAINNET_RPC = process.env.AVALANCHE_MAINNET_RPC_URL ?? "https://api.avax.network/ext/bc/C/rpc";

export default defineConfig({
  plugins: [hardhatToolboxViemPlugin],

  solidity: {
    version: "0.8.28",
    settings: {
      optimizer: {
        enabled: true,
        runs: 1,
      },
      viaIR: true,
    },
  },

  networks: {
    default: {
      type: "edr-simulated",
      allowUnlimitedContractSize: true,
    },
    somnia: {
      type: "http",
      url: SOMNIA_MAINNET_RPC,
      chainId: 5031,
      accounts: ACCOUNTS,
    },
    somnia_testnet: {
      type: "http",
      url: SOMNIA_TESTNET_RPC,
      chainId: 50312,
      accounts: ACCOUNTS,
    },
    avalanche_fuji: {
      type: "http",
      url: AVALANCHE_FUJI_RPC,
      chainId: 43113,
      accounts: ACCOUNTS,
    },
    avalanche: {
      type: "http",
      url: AVALANCHE_MAINNET_RPC,
      chainId: 43114,
      accounts: ACCOUNTS,
    },
  },

  chainDescriptors: {
    5031: {
      name: "somnia",
      blockExplorers: {
        etherscan: {
          name: "SomniaExplorer",
          url: "https://explorer.somnia.network",
          apiUrl: "https://explorer.somnia.network/api",
        },
      },
    },
    50312: {
      name: "somnia_testnet",
      blockExplorers: {
        blockscout: {
          name: "SomniaTestnetExplorer",
          url: "https://shannon-explorer.somnia.network",
          apiUrl: "https://shannon-explorer.somnia.network/api",
        },
      },
    },
    43113: {
      name: "avalanche_fuji",
      blockExplorers: {
        etherscan: {
          name: "SnowtraceFuji",
          url: "https://testnet.snowtrace.io",
          apiUrl: "https://api.routescan.io/v2/network/testnet/evm/43113/etherscan/api",
        },
      },
    },
    43114: {
      name: "avalanche",
      blockExplorers: {
        etherscan: {
          name: "Snowtrace",
          url: "https://snowtrace.io",
          apiUrl: "https://api.routescan.io/v2/network/mainnet/evm/43114/etherscan/api",
        },
      },
    },
  },

  verify: {
    etherscan: {
      apiKey: process.env.ETHERSCAN_API_KEY ?? process.env.SNOWTRACE_API_KEY ?? "",
    },
    sourcify: {
      enabled: false,
    },
  },
});
