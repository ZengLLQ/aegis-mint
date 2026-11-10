#pragma version ^0.4.0

"""
@title RedemptionEngine
@notice Direct 1:1 Collateral Redemption Engine defending the $1.00 USD Peg Floor in Vyper 0.4.3.
@dev Allows AEGIS holders to redeem 1 AEGIS for $1 of collateral from lowest-collateralized troves.
"""

interface IAegisToken:
    def burn(from_account: address, amount: uint256) -> bool: nonpayable
    def balanceOf(account: address) -> uint256: view

interface ITroveManager:
    def collateral_token() -> address: view
    def aegis_token() -> address: view
    def treasury() -> address: view
    def total_debt() -> uint256: view
    def execute_redemption(
        target_trove: address,
        debt_to_redeem: uint256,
        recipient: address,
        fee_bps: uint256
    ) -> (uint256, uint256): nonpayable

# Events
event RedemptionExecuted:
    redeemer: indexed(address)
    target_trove: indexed(address)
    aegis_redeemed: uint256
    collateral_received: uint256
    redemption_fee: uint256

event BaseRateUpdated:
    old_base_rate: uint256
    new_base_rate: uint256

event OwnershipTransferred:
    previous_owner: indexed(address)
    new_owner: indexed(address)

# Constants
BPS: constant(uint256) = 10000
MIN_REDEMPTION_FEE_BPS: constant(uint256) = 50   # 0.5% minimum redemption fee
MAX_REDEMPTION_FEE_BPS: constant(uint256) = 500  # 5.0% maximum redemption fee
DECAY_HALF_LIFE: constant(uint256) = 43200       # 12 hours decay half-life

# State Variables
owner: public(address)
trove_manager: public(address)
base_rate: public(uint256)
last_redemption_timestamp: public(uint256)

@deploy
def __init__(_trove_manager: address):
    assert _trove_manager != empty(address), "INVALID_TROVE_MANAGER"
    self.owner = msg.sender
    self.trove_manager = _trove_manager
    self.base_rate = MIN_REDEMPTION_FEE_BPS
    self.last_redemption_timestamp = block.timestamp
    log OwnershipTransferred(previous_owner=empty(address), new_owner=msg.sender)

@external
def transfer_ownership(new_owner: address):
    assert msg.sender == self.owner, "UNAUTHORIZED"
    assert new_owner != empty(address), "ZERO_ADDRESS"
    log OwnershipTransferred(previous_owner=self.owner, new_owner=new_owner)
    self.owner = new_owner

@view
@external
def get_decayed_base_rate() -> uint256:
    return self._calc_decayed_base_rate()

@internal
@view
def _calc_decayed_base_rate() -> uint256:
    elapsed: uint256 = block.timestamp - self.last_redemption_timestamp
    if elapsed == 0:
        return self.base_rate
    halvings: uint256 = elapsed // DECAY_HALF_LIFE
    if halvings >= 10:
        return MIN_REDEMPTION_FEE_BPS
    decayed: uint256 = self.base_rate // (2 ** halvings)
    if decayed < MIN_REDEMPTION_FEE_BPS:
        return MIN_REDEMPTION_FEE_BPS
    return decayed

@external
@nonreentrant
def redeem_collateral_single(
    target_trove: address,
    aegis_amount: uint256,
    max_fee_bps: uint256
) -> (uint256, uint256):
    assert aegis_amount > 0, "ZERO_AMOUNT"
    assert target_trove != empty(address), "INVALID_TARGET"

    current_fee_bps: uint256 = self._calc_decayed_base_rate()
    assert current_fee_bps <= max_fee_bps, "FEE_EXCEEDS_MAX"

    aegis_token: address = staticcall ITroveManager(self.trove_manager).aegis_token()

    # Burn AEGIS from redeemer
    burn_ok: bool = extcall IAegisToken(aegis_token).burn(msg.sender, aegis_amount)
    assert burn_ok, "AEGIS_BURN_FAILED"

    # Execute redemption in TroveManager
    net_col: uint256 = 0
    fee_col: uint256 = 0
    net_col, fee_col = extcall ITroveManager(self.trove_manager).execute_redemption(
        target_trove,
        aegis_amount,
        msg.sender,
        current_fee_bps
    )

    # Surge base rate proportionally
    tot_debt: uint256 = staticcall ITroveManager(self.trove_manager).total_debt()
    if tot_debt > 0:
        fraction_bps: uint256 = (aegis_amount * BPS) // tot_debt
        new_base_rate: uint256 = current_fee_bps + (fraction_bps // 2)
        if new_base_rate > MAX_REDEMPTION_FEE_BPS:
            new_base_rate = MAX_REDEMPTION_FEE_BPS
        self.base_rate = new_base_rate
        log BaseRateUpdated(old_base_rate=current_fee_bps, new_base_rate=new_base_rate)

    self.last_redemption_timestamp = block.timestamp

    log RedemptionExecuted(
        redeemer=msg.sender,
        target_trove=target_trove,
        aegis_redeemed=aegis_amount,
        collateral_received=net_col,
        redemption_fee=fee_col
    )

    return (net_col, fee_col)
