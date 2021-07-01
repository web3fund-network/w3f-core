const { accounts, contract } = require('@openzeppelin/test-environment');
const { expect } = require('chai');
const { toBN } = require('web3-utils');
const { BN, expectEvent, expectRevert, time, constants, balance } = require('@openzeppelin/test-helpers');

const [ admin, deployer, user, foundation ] = accounts;

const { ethers } =  require("ethers")

const W3F = contract.fromArtifact('W3F');


describe("W3F", function() {
  const BASE = new BN('10').pow(new BN('9'))
  const INITIAL_SUPPLY = toBN('10').pow(toBN('9')).mul(toBN('1400000000'))
  const ONE = "0x0000000000000000000000000000000000000001";


  beforeEach(async () => {
    this.W3F = await W3F.new({ from: admin });
    await this.W3F.setFoundation(foundation, { from: admin })

  });

  it("W3F:totalSupply", async() => {
    let totalSupply = await this.W3F.totalSupply()

    expect(totalSupply.toString()).to.eq(INITIAL_SUPPLY.toString())

    let balance  =  await this.W3F.balanceOf(ONE)
    expect(balance.toString()).to.eq(INITIAL_SUPPLY.toString())

  })

  it("W3F:rebase", async() => {
    await this.W3F.rebase(0, BASE.mul(toBN('10')), { from: foundation})
    let newSupply = await this.W3F.totalSupply()
    expect(newSupply.toString()).to.eq(INITIAL_SUPPLY.add(BASE.mul(toBN('10'))).toString())
  })

  it("W3F:rebase after mint", async() => {
    let epochAddr = await this.W3F.getEpochAddress(1)
    await this.W3F.mint(epochAddr, BASE.mul(toBN('100000')), { from: foundation })

    await this.W3F.rebase(0, BASE.mul(toBN('100000')), { from: foundation })

    let newSupply = await this.W3F.totalSupply()
    expect(newSupply.toString()).to.eq(INITIAL_SUPPLY.add(BASE.mul(toBN('100000'))).toString())

    let balance = await this.W3F.balanceOf(epochAddr)

    expect(balance.toString()).eq(newSupply.mul(BASE.mul(toBN('100000'))).div(INITIAL_SUPPLY).toString())

  })

  it("W3F:mint", async() => {
    let epochAddr = await this.W3F.getEpochAddress(1)
    await this.W3F.mint(epochAddr, BASE.mul(toBN('10')), { from: foundation })

    let newSupply = await this.W3F.totalSupply()
    expect(newSupply.toString()).to.eq(INITIAL_SUPPLY.toString())

    let b = await this.W3F.balanceOf(epochAddr)
    expect(b.toString()).to.eq(BASE.mul(toBN('10')).toString())
  })

  it("W3F:burn", async() => {
    let epochAddr = await this.W3F.getEpochAddress(1)
    await this.W3F.mint(epochAddr, BASE.mul(toBN('10')), { from: foundation })

    let b = await this.W3F.balanceOf(epochAddr)
    expect(b.toString()).to.eq(BASE.mul(toBN('10')).toString())

    await this.W3F.burn(epochAddr, toBN('5').mul(BASE), { from: foundation })
    let after = await this.W3F.balanceOf(epochAddr)

    expect(after.toString()).to.eq(toBN('5').mul(BASE).toString())
  })

  it("W3F:specialTransferFrom", async() => {
    let epochAddr = await this.W3F.getEpochAddress(1)
    await this.W3F.mint(epochAddr, BASE.mul(toBN('10')), { from: foundation })

    this.W3F.specialTransferFrom(1, user, toBN('3').mul(BASE),  { from: foundation })

    let after = await this.W3F.balanceOf(epochAddr)
    expect(after.toString()).to.eq(toBN('7').mul(BASE).toString())

    let b = await this.W3F.balanceOf(user)
    expect(b.toString()).to.eq(toBN('3').mul(BASE).toString())
  })
});