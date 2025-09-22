flowchart LR

%% ===== Exchange =====
subgraph Exchange
Factory --> Pair
Router  --> Pair
Router  --> Oracle
ZapV2   --> Router
end

%% ===== Payflow =====
subgraph Payflow
PayflowExecutorV2 --> BestExecutionV14
BestExecutionV14  --> Oracle
PayflowExecutorV2 --> Router
PayflowExecutorV2 --> LPRebate
PayflowExecutorV2 --> LockerCollector
PayflowExecutorV2 --> UsagePoints:::hook    %% onPayflowExecuted(user, vol, saved, ref)
end

%% ===== DAO / Tokenomics =====
subgraph DAO
VoterEscrow(veXPGN) --> GaugeController

%% Emissions path
GaugeController --> EmissionsMinter
EmissionsMinter  --> SimpleGauge
SimpleGauge      -->|rewards| GaugeStakers

%% Fee distribution path (protocol fees → ve holders)
TreasuryFees --> FeeDistributorERC20
FeeDistributorERC20 -->|uses snapshots in| VoterEscrow

%% Usage → auto lock path
UsagePoints -. points .-> TraderRewardsLocker
TraderRewardsLocker -->|create_lock_for| VoterEscrow

%% Farming / streaming (optional but supported)
RewardDripperEscrow -->|XPGN stream| ParagonFarmController
ParagonLockingVault -->|stakes LP into| ParagonFarmController
end

%% Admin touchpoints
Admin --- DAO
Admin --- Exchange
DAO   --- Payflow

classDef hook fill:#f6ffed,stroke:#52c41a,color:#102a0f,stroke-width:1px;
