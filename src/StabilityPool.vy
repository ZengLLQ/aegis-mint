#pragma version ^0.4.0

"""
@title StabilityPool
@notice O(1) Liquidation Loss Offset & Collateral Gain Distribution Engine for AegisMint in Vyper 0.4.3.
@dev Uses product-sum scaling factors (P and S) to eliminate loops during liquidation rewards.
"""

interface IERC20:
    def transfer(receiver: address, amount: uint256) -> bool: nonpayable
    def transferFrom(sender: address, receiver: address, amount: uint256) -> bool: nonpayable
    def balanceOf(account: address) -> uint256: view

interface IAegisToken:
    def burn(from_account: address, amount: uint256) -> bool: nonpayable
    def transfer(receiver: address, amount: uint256) -> bool: nonpayable
    def transferFrom(sender: address, receiver: address, amount: uint256) -> bool: nonpayable
    def balanceOf(account: address) -> uint256: view

# Events
event DepositProvided:
    depositor: indexed(address)
    amount: uint256
    new_deposit: uint256

event DepositWithdrawn:
    depositor: indexed(address)
    amount: uint256
    remaining_deposit: uint256

event CollateralGainClaimed:
    depositor: indexed(address)
    collateral_gain: uint256

event DebtOffsetOccurred:
    debt_offset: uint256
    collateral_reward: uint256
    new_total_deposits: uint256

event TroveManagerUpdated:
    trove_manager: address

event OwnershipTransferred:
    previous_owner: indexed(address)
    new_owner: indexed(address)

# Structs
struct Snapshots:
    S: uint256
    P: uint256

# Constants
SCALE: constant(uint256) = 1000000000000000000  # 1e18 precision

# State Variables
owner: public(address)
trove_manager: public(address)
aegis_token: public(address)
collateral_token: public(address)

total_aegis_deposits: public(uint256)
total_collateral_held: public(uint256)

# O(1) Scalable Accumulator
P: public(uint256)  # Product factor: starts at 1e18
S: public(uint256)  # Sum factor: accumulated collateral per unit deposit

deposits: public(HashMap[address, uint256])
deposit_snapshots: public(HashMap[address, Snapshots])

@deploy
def __init__(
    _aegis_token: address,
    _collateral_token: address,
    _trove_manager: address
):
    assert _aegis_token != empty(address), "INVALID_AEGIS"
    assert _collateral_token != empty(address), "INVALID_COLLATERAL"
    assert _trove_manager != empty(address), "INVALID_TROVE_MANAGER"

    self.owner = msg.sender
    self.aegis_token = _aegis_token
    self.collateral_token = _collateral_token
    self.trove_manager = _trove_manager

    self.P = SCALE
    self.S = 0

    log OwnershipTransferred(previous_owner=empty(address), new_owner=msg.sender)
    log TroveManagerUpdated(trove_manager=_trove_manager)

@external
def set_trove_manager(_new_manager: address):
    assert msg.sender == self.owner, "UNAUTHORIZED"
    assert _new_manager != empty(address), "ZERO_ADDRESS"
    self.trove_manager = _new_manager
    log TroveManagerUpdated(trove_manager=_new_manager)

@external
def transfer_ownership(new_owner: address):
    assert msg.sender == self.owner, "UNAUTHORIZED"
    assert new_owner != empty(address), "ZERO_ADDRESS"
    log OwnershipTransferred(previous_owner=self.owner, new_owner=new_owner)
    self.owner = new_owner

@view
@external
def get_compounded_aegis_deposit(depositor: address) -> uint256:
    initial_deposit: uint256 = self.deposits[depositor]
    if initial_deposit == 0:
        return 0
    snapshot_P: uint256 = self.deposit_snapshots[depositor].P
    if snapshot_P == 0:
        return 0
    return (initial_deposit * self.P) // snapshot_P

@view
@external
def get_depositor_collateral_gain(depositor: address) -> uint256:
    initial_deposit: uint256 = self.deposits[depositor]
    if initial_deposit == 0:
        return 0
    snapshot_S: uint256 = self.deposit_snapshots[depositor].S
    snapshot_P: uint256 = self.deposit_snapshots[depositor].P
    if snapshot_P == 0:
        return 0
    if self.S <= snapshot_S:
        return 0
    gain_per_unit: uint256 = self.S - snapshot_S
    return (initial_deposit * gain_per_unit) // snapshot_P

@internal
def _update_user_and_claim_collateral(depositor: address) -> uint256:
    gain: uint256 = 0
    initial_deposit: uint256 = self.deposits[depositor]
    
    if initial_deposit > 0:
        snapshot_S: uint256 = self.deposit_snapshots[depositor].S
        snapshot_P: uint256 = self.deposit_snapshots[depositor].P
        
        if snapshot_P > 0 and self.S > snapshot_S:
            gain = (initial_deposit * (self.S - snapshot_S)) // snapshot_P
        
        # Update user's deposit to compounded amount
        if snapshot_P > 0:
            self.deposits[depositor] = (initial_deposit * self.P) // snapshot_P

    # Reset snapshot to current P and S
    self.deposit_snapshots[depositor] = Snapshots(S=self.S, P=self.P)

    # Transfer collateral gain if any
    if gain > 0:
        self.total_collateral_held -= gain
        send_ok: bool = extcall IERC20(self.collateral_token).transfer(depositor, gain)
        assert send_ok, "COLLATERAL_GAIN_TRANSFER_FAILED"
        log CollateralGainClaimed(depositor=depositor, collateral_gain=gain)

    return gain

@external
@nonreentrant
def provide_to_sp(amount: uint256):
    assert amount > 0, "ZERO_AMOUNT"

    # Settle existing gains first
    self._update_user_and_claim_collateral(msg.sender)

    # Pull AEGIS from depositor
    pull_ok: bool = extcall IAegisToken(self.aegis_token).transferFrom(msg.sender, self, amount)
    assert pull_ok, "AEGIS_TRANSFER_FAILED"

    self.deposits[msg.sender] += amount
    self.total_aegis_deposits += amount

    log DepositProvided(
        depositor=msg.sender,
        amount=amount,
        new_deposit=self.deposits[msg.sender]
    )

@external
@nonreentrant
def withdraw_from_sp(amount: uint256):
    assert amount > 0, "ZERO_AMOUNT"

    # Settle existing gains and compute compounded deposit
    self._update_user_and_claim_collateral(msg.sender)

    compounded_deposit: uint256 = self.deposits[msg.sender]
    assert compounded_deposit >= amount, "WITHDRAW_EXCEEDS_DEPOSIT"

    new_deposit: uint256 = compounded_deposit - amount
    self.deposits[msg.sender] = new_deposit
    self.total_aegis_deposits -= amount

    # Transfer AEGIS back to user
    send_ok: bool = extcall IAegisToken(self.aegis_token).transfer(msg.sender, amount)
    assert send_ok, "AEGIS_SEND_FAILED"

    log DepositWithdrawn(
        depositor=msg.sender,
        amount=amount,
        remaining_deposit=new_deposit
    )

@external
@nonreentrant
def claim_rewards():
    assert self.deposits[msg.sender] > 0, "NO_DEPOSIT"
    self._update_user_and_claim_collateral(msg.sender)

@external
@nonreentrant
def offset_debt(debt_to_offset: uint256, collateral_to_reward: uint256) -> bool:
    assert msg.sender == self.trove_manager, "CALLER_NOT_TROVE_MANAGER"
    assert debt_to_offset > 0, "ZERO_DEBT_OFFSET"
    assert self.total_aegis_deposits >= debt_to_offset, "INSUFFICIENT_SP_LIQUIDITY"

    total_dep: uint256 = self.total_aegis_deposits

    # 1. Update S with new collateral reward per unit deposit
    # delta_S = (collateral_to_reward * SCALE) / total_dep
    # S += delta_S * P / SCALE
    delta_S: uint256 = (collateral_to_reward * SCALE) // total_dep
    self.S += (delta_S * self.P) // SCALE
    self.total_collateral_held += collateral_to_reward

    # 2. Update P product factor: P = P * (total_dep - debt_to_offset) / total_dep
    new_dep: uint256 = total_dep - debt_to_offset
    self.P = (self.P * new_dep) // total_dep
    self.total_aegis_deposits = new_dep

    # 3. Burn offset AEGIS tokens held by Stability Pool
    burn_ok: bool = extcall IAegisToken(self.aegis_token).burn(self, debt_to_offset)
    assert burn_ok, "SP_AEGIS_BURN_FAILED"

    log DebtOffsetOccurred(
        debt_offset=debt_to_offset,
        collateral_reward=collateral_to_reward,
        new_total_deposits=new_dep
    )
    return True
