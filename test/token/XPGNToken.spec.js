// test/token/XPGNToken.spec.js
const { expect } = require("chai");
const { ethers } = require("hardhat");
const { loadFixture, time, mine } =
  require("@nomicfoundation/hardhat-toolbox/network-helpers");

const E18 = (n) => ethers.parseEther(n.toString());
const BI  = (x) => (typeof x === "bigint" ? x : BigInt(x)); // normalize to BigInt

// Match contract constants
const GENESIS = E18(10_000_000);
const FARMING_CAP   = E18(150_000_000);
const VALIDATOR_CAP = E18(250_000_000);
const ECOSYS_CAP    = E18(40_000_001);
const TREASURY_CAP  = E18(33_999_999);
const TEAM_CAP      = E18(55_000_000);
const ADVISOR_CAP   = E18(11_000_000);

// Use BigInt for time constants
const ECOSYSTEM_START_TIME    = 1760486400n;               // Oct 15, 2025 UTC
const ECOSYSTEM_MONTHLY_LIMIT = E18(450_000);              // already BigInt
const ECOSYSTEM_PERIOD        = 30n * 24n * 60n * 60n;     // 30 days

// roles: keccak256("...") as in the contract
const R = {
  FARMING:  ethers.id("FARMING_MINTER_ROLE"),
  VALIDATOR:ethers.id("VALIDATOR_MINTER_ROLE"),
  ECOSYS:   ethers.id("ECOSYSTEM_MINTER_ROLE"),
  TREASURY: ethers.id("TREASURY_MINTER_ROLE"),
  TEAM:     ethers.id("TEAM_MINTER_ROLE"),
  ADVISOR:  ethers.id("ADVISOR_MINTER_ROLE"),
};

async function deploy() {
  const [dao, farmingCtl, validatorDist, teamVesting, advisorVesting, genesisRecipient, alice, bob] =
    await ethers.getSigners();

  const XPGN = await ethers.getContractFactory("XPGNToken");
  const token = await XPGN.deploy(
    dao.address,
    farmingCtl.address,
    validatorDist.address,
    teamVesting.address,
    advisorVesting.address,
    genesisRecipient.address
  );

  return {
    token, dao, farmingCtl, validatorDist, teamVesting, advisorVesting, genesisRecipient, alice, bob
  };
}

describe("XPGNToken", () => {
  it("constructor wires roles and genesis mint", async () => {
    const { token, genesisRecipient, dao, farmingCtl, validatorDist } = await loadFixture(deploy);

    expect(await token.balanceOf(genesisRecipient.address)).to.equal(GENESIS);

    // Roles
    expect(await token.hasRole(await token.DEFAULT_ADMIN_ROLE(), dao.address)).to.equal(true);
    expect(await token.hasRole(R.FARMING,   farmingCtl.address)).to.equal(true);
    expect(await token.hasRole(R.VALIDATOR, validatorDist.address)).to.equal(true);
    expect(await token.hasRole(R.ECOSYS,    dao.address)).to.equal(true);
    expect(await token.hasRole(R.TREASURY,  dao.address)).to.equal(true);
    expect(await token.hasRole(R.TEAM,      dao.address)).to.equal(true);
    expect(await token.hasRole(R.ADVISOR,   dao.address)).to.equal(true);
  });

  it("reverts unauthorized mint & enforces per-bucket caps and recipients", async () => {
    const { token, dao, farmingCtl, validatorDist, teamVesting, advisorVesting, alice } = await loadFixture(deploy);

    // Non-minter cannot mint
    await expect(token.connect(alice).mint(alice.address, 1n, R.TREASURY))
      .to.be.revertedWith("CALLER_NOT_MINTER");

    // Farming minter OK within cap
    await expect(token.connect(farmingCtl).mint(alice.address, E18(123), R.FARMING))
      .to.emit(token, "Mint").withArgs(alice.address, E18(123), R.FARMING);

    // Team mints must go to teamVesting
    await expect(token.connect(dao).mint(alice.address, E18(1), R.TEAM))
      .to.be.revertedWith("TEAM_TO_MUST_BE_VESTING");
    await token.connect(dao).mint(teamVesting.address, E18(1), R.TEAM);

    // Advisor mints must go to advisorVesting
    await expect(token.connect(dao).mint(alice.address, E18(1), R.ADVISOR))
      .to.be.revertedWith("ADVISOR_TO_MUST_BE_VESTING");
    await token.connect(dao).mint(advisorVesting.address, E18(1), R.ADVISOR);

    // Cap per bucket enforced (we already minted 1e18 above -> mint remaining, then +1 should revert)
    await expect(
      token.connect(dao).mint(teamVesting.address, TEAM_CAP - E18(1), R.TEAM)
    ).to.not.be.reverted;
    await expect(
      token.connect(dao).mint(teamVesting.address, 1n, R.TEAM)
    ).to.be.revertedWith("TEAM_CAP_EXCEEDED");
  });

  it("validator minting is gated by enable/disable toggle", async () => {
    const { token, validatorDist, alice, dao } = await loadFixture(deploy);

    // Disabled by default
    await expect(token.connect(validatorDist).mint(alice.address, E18(1), R.VALIDATOR))
      .to.be.revertedWith("VALIDATOR_DISABLED");

    await token.connect(dao).enableValidatorMinting();

    await expect(token.connect(validatorDist).mint(alice.address, E18(2), R.VALIDATOR))
      .to.emit(token, "Mint").withArgs(alice.address, E18(2), R.VALIDATOR);

    await token.connect(dao).disableValidatorMinting();

    await expect(token.connect(validatorDist).mint(alice.address, E18(1), R.VALIDATOR))
      .to.be.revertedWith("VALIDATOR_DISABLED");
  });

  it("ecosystem mint: not before start, ≤ monthly limit, one mint / 30 days window", async () => {
    const { token, dao, alice } = await loadFixture(deploy);

    const start = ECOSYSTEM_START_TIME;              // BigInt
    const now0  = BI(await time.latest());           // normalize

    // Only run "before start" check if chain time is actually before the configured start
    if (now0 < start) {
      await time.setNextBlockTimestamp(Number(start - 10n)); // cast for helper
      await mine();
      await expect(token.connect(dao).mint(alice.address, E18(1), R.ECOSYS))
        .to.be.revertedWith("ECOSYSTEM_NOT_STARTED");
    }

    // Move to/start at ≥ start time
    const now1 = BI(await time.latest());
    if (now1 < start) {
      await time.setNextBlockTimestamp(Number(start));
      await mine();
    }

    // Mint up to monthly limit
    await token.connect(dao).mint(alice.address, ECOSYSTEM_MONTHLY_LIMIT, R.ECOSYS);

    // Still within cooldown window -> mint should revert with cooldown
    const now2 = BI(await time.latest());
    await time.setNextBlockTimestamp(Number(now2 + 60n));
    await mine();
    await expect(token.connect(dao).mint(alice.address, 1n, R.ECOSYS))
      .to.be.revertedWith("ECOSYSTEM_COOLDOWN");

    // After 30d -> cannot exceed monthly limit; exactly limit is OK
    await time.increase(Number(ECOSYSTEM_PERIOD + 1n));
    await expect(token.connect(dao).mint(alice.address, ECOSYSTEM_MONTHLY_LIMIT + 1n, R.ECOSYS))
      .to.be.revertedWith("ECOSYSTEM_MONTHLY_LIMIT");
    await token.connect(dao).mint(alice.address, ECOSYSTEM_MONTHLY_LIMIT, R.ECOSYS);
  });

  it("pause blocks transfers but allows minting", async () => {
    const { token, dao, alice, bob } = await loadFixture(deploy);

    // Pause
    await token.connect(dao).pause();

    // Mint while paused (allowed)
    await token.connect(dao).mint(alice.address, E18(5), R.TREASURY);
    expect(await token.balanceOf(alice.address)).to.equal(E18(5));

    // Transfer while paused (blocked)
    await expect(token.connect(alice).transfer(bob.address, E18(1)))
      .to.be.revertedWith("PAUSED");

    // Unpause -> transfers OK
    await token.connect(dao).unpause();
    await expect(token.connect(alice).transfer(bob.address, E18(1))).to.not.be.reverted;
  });

  it("EIP-2612 permit updates allowance and nonce", async () => {
    const { token, alice, bob } = await loadFixture(deploy);

    // Use chain time (BigInt) for deadline to avoid drift
    const deadline = BI(await time.latest()) + 3600n;
    const value = E18(42);

    // Ethers v6 returns BigInt chainId; cast to Number for the domain
    const chainId = Number((await ethers.provider.getNetwork()).chainId);

    const domain = {
      name: await token.name(),
      version: "1",
      chainId,
      verifyingContract: await token.getAddress(),
    };
    const types = {
      Permit: [
        { name: "owner",   type: "address" },
        { name: "spender", type: "address" },
        { name: "value",   type: "uint256" },
        { name: "nonce",   type: "uint256" },
        { name: "deadline",type: "uint256" },
      ],
    };
    const message = {
      owner:   alice.address,
      spender: bob.address,
      value,
      nonce: await token.nonces(alice.address), // BigInt OK
      deadline,                                 // BigInt OK
    };

    const sig = await alice.signTypedData(domain, types, message);
    const { v, r, s } = ethers.Signature.from(sig);

    await expect(token.permit(alice.address, bob.address, value, deadline, v, r, s)).to.not.be.reverted;
    expect(await token.allowance(alice.address, bob.address)).to.equal(value);
    expect(await token.nonces(alice.address)).to.equal(1n);
  });

  it("ERC20Votes tracks delegated votes on mint", async () => {
    const { token, dao, alice, bob } = await loadFixture(deploy);

    // Delegate before mint
    await token.connect(alice).delegate(bob.address);

    // DAO has TREASURY role -> mint to Alice
    await token.connect(dao).mint(alice.address, E18(3), R.TREASURY);

    // Advance a block to solidify checkpoint
    await mine();

    expect(await token.getVotes(bob.address)).to.equal(E18(3));
  });
});
