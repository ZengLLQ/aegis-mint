#pragma version ^0.4.0

"""
@title TroveManager
@notice Core CDP Management, Risk Engine & Liquidation Controller for AegisMint in Vyper 0.4.3.
@dev Handles Collateralized Debt Positions, Solvency Ratios, Liquidations, and Borrowing Fees.
"""

interface IERC20:
    def transfer(receiver: address, amount: uint256) -> bool: nonpayable
    def transferFrom(sender: address, receiver: address, amount: uint256) -> bool: nonpayable
    def balanceOf(account: address) -> uint256: view

interface IAegisToken:
    def mint(to: address, amount: uint256) -> bool: nonpayable
    def burn(from_account: address, amount: uint256) -> bool: nonpayable
    def transfer(receiver: address, amount: uint256) -> bool: nonpayable
    def transferFrom(sender: address, receiver: address, amount: uint256) -> bool: nonpayable
    def balanceOf(account: address) -> uint256: view

interface IPriceFeedOracle:
    def get_price(asset: address) -> uint256: view

interface IStabilityPool:
    def offset_debt(debt_to_offset: uint256, collateral_to_reward: uint256) -> bool: nonpayable
    def total_aegis_deposits() -> uint256: view

# Events
event TroveOpened:
    borrower: indexed(address)
    collateral: uint256
    debt: uint256
    fee: uint256

event TroveUpdated:
    borrower: indexed(address)
    collateral: uint256
    debt: uint256
    operation: String[32]

event TroveClosed:
    borrower: indexed(address)

event TroveLiquidated:
    borrower: indexed(address)
    liquidator: indexed(address)
    debt_offset: uint256
    collateral_seized: uint256
    liquidated_by_sp: bool

event TroveRedeemed:
    borrower: indexed(address)
    redeemer: indexed(address)
    debt_redeemed: uint256
    collateral_redeemed: uint256
    fee_collateral: uint256

event BorrowingFeeUpdated:
    old_fee_bps: uint256
    new_fee_bps: uint256

event StabilityPoolUpdated:
    stability_pool: address

event RedemptionEngineUpdated:
    redemption_engine: address

event OwnershipTransferred:
    previous_owner: indexed(address)
    new_owner: indexed(address)

# Structs
struct Trove:
    collateral: uint256
    debt: uint256
    is_active: bool

# Constants
WAD: constant(uint256) = 1000000000000000000
BPS: constant(uint256) = 10000
MCR: constant(uint256) = 11000               # 110% Minimum Collateral Ratio
CCR: constant(uint256) = 15000               # 150% Critical Collateral Ratio
MIN_NET_DEBT: constant(uint256) = 100 * WAD  # 100 AEGIS minimum net debt
LIQUIDATION_BONUS_BPS: constant(uint256) = 500  # 5% Liquidator Bonus
MAX_BORROWING_FEE_BPS: constant(uint256) = 500  # Max 5% Borrowing Fee

# State Variables
owner: public(address)
collateral_token: public(address)
aegis_token: public(address)
price_oracle: public(address)
stability_pool: public(address)
redemption_engine: public(address)
treasury: public(address)

borrowing_fee_bps: public(uint256)
total_collateral: public(uint256)
total_debt: public(uint256)

troves: public(HashMap[address, Trove])
trove_count: public(uint256)

@deploy
def __init__(
    _collateral_token: address,
    _aegis_token: address,
    _price_oracle: address,
    _treasury: address,
    _borrowing_fee_bps: uint256
):
    assert _collateral_token != empty(address), "INVALID_COLLATERAL"
    assert _aegis_token != empty(address), "INVALID_AEGIS"
    assert _price_oracle != empty(address), "INVALID_ORACLE"
    assert _treasury != empty(address), "INVALID_TREASURY"
    assert _borrowing_fee_bps <= MAX_BORROWING_FEE_BPS, "EXCESSIVE_FEE"

    self.owner = msg.sender
    self.collateral_token = _collateral_token
    self.aegis_token = _aegis_token
    self.price_oracle = _price_oracle
    self.treasury = _treasury
    self.borrowing_fee_bps = _borrowing_fee_bps

    log OwnershipTransferred(previous_owner=empty(address), new_owner=msg.sender)
    log BorrowingFeeUpdated(old_fee_bps=0, new_fee_bps=_borrowing_fee_bps)

@external
def set_stability_pool(_stability_pool: address):
    assert msg.sender == self.owner, "UNAUTHORIZED"
    assert _stability_pool != empty(address), "ZERO_ADDRESS"
    self.stability_pool = _stability_pool
    log StabilityPoolUpdated(stability_pool=_stability_pool)

@external
def set_redemption_engine(_redemption_engine: address):
    assert msg.sender == self.owner, "UNAUTHORIZED"
    assert _redemption_engine != empty(address), "ZERO_ADDRESS"
    self.redemption_engine = _redemption_engine
    log RedemptionEngineUpdated(redemption_engine=_redemption_engine)

@external
def set_borrowing_fee_bps(_fee_bps: uint256):
    assert msg.sender == self.owner, "UNAUTHORIZED"
    assert _fee_bps <= MAX_BORROWING_FEE_BPS, "EXCESSIVE_FEE"
    old_fee: uint256 = self.borrowing_fee_bps
    self.borrowing_fee_bps = _fee_bps
    log BorrowingFeeUpdated(old_fee_bps=old_fee, new_fee_bps=_fee_bps)

@external
def transfer_ownership(new_owner: address):
    assert msg.sender == self.owner, "UNAUTHORIZED"
    assert new_owner != empty(address), "ZERO_ADDRESS"
    log OwnershipTransferred(previous_owner=self.owner, new_owner=new_owner)
    self.owner = new_owner

@view
@external
def get_collateral_price() -> uint256:
    return staticcall IPriceFeedOracle(self.price_oracle).get_price(self.collateral_token)

@view
@external
def get_icr(borrower: address) -> uint256:
    t: Trove = self.troves[borrower]
    if not t.is_active or t.debt == 0:
        return max_value(uint256)
    price: uint256 = staticcall IPriceFeedOracle(self.price_oracle).get_price(self.collateral_token)
    return (t.collateral * price * BPS) // (t.debt * WAD)

@view
@external
def get_tcr() -> uint256:
    if self.total_debt == 0:
        return max_value(uint256)
    price: uint256 = staticcall IPriceFeedOracle(self.price_oracle).get_price(self.collateral_token)
    return (self.total_collateral * price * BPS) // (self.total_debt * WAD)

@view
@external
def is_solvent(borrower: address) -> bool:
    t: Trove = self.troves[borrower]
    if not t.is_active or t.debt == 0:
        return True
    price: uint256 = staticcall IPriceFeedOracle(self.price_oracle).get_price(self.collateral_token)
    icr: uint256 = (t.collateral * price * BPS) // (t.debt * WAD)
    return icr >= MCR

@external
@nonreentrant
def open_trove(collateral_amount: uint256, debt_amount: uint256):
    assert not self.troves[msg.sender].is_active, "TROVE_ALREADY_EXISTS"
    assert collateral_amount > 0, "ZERO_COLLATERAL"
    assert debt_amount >= MIN_NET_DEBT, "DEBT_BELOW_MINIMUM"

    fee: uint256 = (debt_amount * self.borrowing_fee_bps) // BPS
    total_debt_issued: uint256 = debt_amount + fee

    price: uint256 = staticcall IPriceFeedOracle(self.price_oracle).get_price(self.collateral_token)
    icr: uint256 = (collateral_amount * price * BPS) // (total_debt_issued * WAD)
    assert icr >= MCR, "INSUFFICIENT_COLLATERAL_RATIO"

    # Transfer collateral in
    collateral_ok: bool = extcall IERC20(self.collateral_token).transferFrom(msg.sender, self, collateral_amount)
    assert collateral_ok, "COLLATERAL_TRANSFER_FAILED"

    # Mint AEGIS to borrower and fee to treasury
    mint_ok: bool = extcall IAegisToken(self.aegis_token).mint(msg.sender, debt_amount)
    assert mint_ok, "AEGIS_MINT_FAILED"
    if fee > 0:
        fee_ok: bool = extcall IAegisToken(self.aegis_token).mint(self.treasury, fee)
        assert fee_ok, "FEE_MINT_FAILED"

    self.troves[msg.sender] = Trove(
        collateral=collateral_amount,
        debt=total_debt_issued,
        is_active=True
    )
    self.trove_count += 1
    self.total_collateral += collateral_amount
    self.total_debt += total_debt_issued

    log TroveOpened(
        borrower=msg.sender,
        collateral=collateral_amount,
        debt=total_debt_issued,
        fee=fee
    )

@external
@nonreentrant
def add_collateral(amount: uint256):
    assert self.troves[msg.sender].is_active, "TROVE_DOES_NOT_EXIST"
    assert amount > 0, "ZERO_AMOUNT"

    ok: bool = extcall IERC20(self.collateral_token).transferFrom(msg.sender, self, amount)
    assert ok, "COLLATERAL_TRANSFER_FAILED"

    self.troves[msg.sender].collateral += amount
    self.total_collateral += amount

    log TroveUpdated(
        borrower=msg.sender,
        collateral=self.troves[msg.sender].collateral,
        debt=self.troves[msg.sender].debt,
        operation="ADD_COLLATERAL"
    )

@external
@nonreentrant
def withdraw_collateral(amount: uint256):
    assert self.troves[msg.sender].is_active, "TROVE_DOES_NOT_EXIST"
    assert amount > 0, "ZERO_AMOUNT"
    assert self.troves[msg.sender].collateral >= amount, "EXCEEDS_COLLATERAL"

    new_collateral: uint256 = self.troves[msg.sender].collateral - amount
    current_debt: uint256 = self.troves[msg.sender].debt

    if current_debt > 0:
        price: uint256 = staticcall IPriceFeedOracle(self.price_oracle).get_price(self.collateral_token)
        new_icr: uint256 = (new_collateral * price * BPS) // (current_debt * WAD)
        assert new_icr >= MCR, "INSUFFICIENT_COLLATERAL_RATIO"

    self.troves[msg.sender].collateral = new_collateral
    self.total_collateral -= amount

    transfer_ok: bool = extcall IERC20(self.collateral_token).transfer(msg.sender, amount)
    assert transfer_ok, "COLLATERAL_TRANSFER_FAILED"

    log TroveUpdated(
        borrower=msg.sender,
        collateral=new_collateral,
        debt=current_debt,
        operation="WITHDRAW_COLLATERAL"
    )

@external
@nonreentrant
def mint_more_debt(amount: uint256):
    assert self.troves[msg.sender].is_active, "TROVE_DOES_NOT_EXIST"
    assert amount > 0, "ZERO_AMOUNT"

    fee: uint256 = (amount * self.borrowing_fee_bps) // BPS
    total_added_debt: uint256 = amount + fee
    new_debt: uint256 = self.troves[msg.sender].debt + total_added_debt

    price: uint256 = staticcall IPriceFeedOracle(self.price_oracle).get_price(self.collateral_token)
    current_collateral: uint256 = self.troves[msg.sender].collateral
    new_icr: uint256 = (current_collateral * price * BPS) // (new_debt * WAD)
    assert new_icr >= MCR, "INSUFFICIENT_COLLATERAL_RATIO"

    self.troves[msg.sender].debt = new_debt
    self.total_debt += total_added_debt

    mint_ok: bool = extcall IAegisToken(self.aegis_token).mint(msg.sender, amount)
    assert mint_ok, "AEGIS_MINT_FAILED"
    if fee > 0:
        fee_ok: bool = extcall IAegisToken(self.aegis_token).mint(self.treasury, fee)
        assert fee_ok, "FEE_MINT_FAILED"

    log TroveUpdated(
        borrower=msg.sender,
        collateral=current_collateral,
        debt=new_debt,
        operation="MINT_MORE_DEBT"
    )

@external
@nonreentrant
def repay_debt(amount: uint256):
    assert self.troves[msg.sender].is_active, "TROVE_DOES_NOT_EXIST"
    assert amount > 0, "ZERO_AMOUNT"
    assert self.troves[msg.sender].debt >= amount, "EXCEEDS_DEBT"

    new_debt: uint256 = self.troves[msg.sender].debt - amount
    if new_debt > 0:
        assert new_debt >= MIN_NET_DEBT, "REMAINING_DEBT_BELOW_MIN"

    burn_ok: bool = extcall IAegisToken(self.aegis_token).burn(msg.sender, amount)
    assert burn_ok, "AEGIS_BURN_FAILED"

    self.troves[msg.sender].debt = new_debt
    self.total_debt -= amount

    log TroveUpdated(
        borrower=msg.sender,
        collateral=self.troves[msg.sender].collateral,
        debt=new_debt,
        operation="REPAY_DEBT"
    )

@external
@nonreentrant
def close_trove():
    assert self.troves[msg.sender].is_active, "TROVE_DOES_NOT_EXIST"
    
    current_debt: uint256 = self.troves[msg.sender].debt
    current_collateral: uint256 = self.troves[msg.sender].collateral

    if current_debt > 0:
        burn_ok: bool = extcall IAegisToken(self.aegis_token).burn(msg.sender, current_debt)
        assert burn_ok, "AEGIS_BURN_FAILED"

    self.total_debt -= current_debt
    self.total_collateral -= current_collateral
    self.troves[msg.sender] = Trove(collateral=0, debt=0, is_active=False)
    self.trove_count -= 1

    if current_collateral > 0:
        collateral_ok: bool = extcall IERC20(self.collateral_token).transfer(msg.sender, current_collateral)
        assert collateral_ok, "COLLATERAL_TRANSFER_FAILED"

    log TroveClosed(borrower=msg.sender)

@external
@nonreentrant
def liquidate(borrower: address):
    assert self.troves[borrower].is_active, "TROVE_DOES_NOT_EXIST"

    price: uint256 = staticcall IPriceFeedOracle(self.price_oracle).get_price(self.collateral_token)
    t: Trove = self.troves[borrower]
    icr: uint256 = (t.collateral * price * BPS) // (t.debt * WAD)
    assert icr < MCR, "TROVE_IS_SOLVENT"

    debt_to_offset: uint256 = t.debt
    collateral_to_liquidate: uint256 = t.collateral

    sp_aegis: uint256 = 0
    if self.stability_pool != empty(address):
        sp_aegis = staticcall IStabilityPool(self.stability_pool).total_aegis_deposits()

    if sp_aegis >= debt_to_offset:
        self.troves[borrower] = Trove(collateral=0, debt=0, is_active=False)
        self.trove_count -= 1
        self.total_debt -= debt_to_offset
        self.total_collateral -= collateral_to_liquidate

        collateral_ok: bool = extcall IERC20(self.collateral_token).transfer(self.stability_pool, collateral_to_liquidate)
        assert collateral_ok, "COLLATERAL_TO_SP_FAILED"

        sp_ok: bool = extcall IStabilityPool(self.stability_pool).offset_debt(debt_to_offset, collateral_to_liquidate)
        assert sp_ok, "SP_OFFSET_FAILED"

        log TroveLiquidated(
            borrower=borrower,
            liquidator=self.stability_pool,
            debt_offset=debt_to_offset,
            collateral_seized=collateral_to_liquidate,
            liquidated_by_sp=True
        )
    else:
        burn_ok: bool = extcall IAegisToken(self.aegis_token).burn(msg.sender, debt_to_offset)
        assert burn_ok, "LIQUIDATOR_BURN_FAILED"

        collateral_for_debt: uint256 = (debt_to_offset * WAD) // price
        collateral_with_bonus: uint256 = (collateral_for_debt * (BPS + LIQUIDATION_BONUS_BPS)) // BPS

        collateral_to_seize: uint256 = collateral_with_bonus
        collateral_surplus: uint256 = 0
        if collateral_to_seize > collateral_to_liquidate:
            collateral_to_seize = collateral_to_liquidate
        else:
            collateral_surplus = collateral_to_liquidate - collateral_to_seize

        self.troves[borrower] = Trove(collateral=0, debt=0, is_active=False)
        self.trove_count -= 1
        self.total_debt -= debt_to_offset
        self.total_collateral -= collateral_to_liquidate

        send_liq_ok: bool = extcall IERC20(self.collateral_token).transfer(msg.sender, collateral_to_seize)
        assert send_liq_ok, "LIQUIDATOR_COLLATERAL_FAILED"

        if collateral_surplus > 0:
            surplus_ok: bool = extcall IERC20(self.collateral_token).transfer(borrower, collateral_surplus)
            assert surplus_ok, "SURPLUS_COLLATERAL_FAILED"

        log TroveLiquidated(
            borrower=borrower,
            liquidator=msg.sender,
            debt_offset=debt_to_offset,
            collateral_seized=collateral_to_seize,
            liquidated_by_sp=False
        )

@external
@nonreentrant
def execute_redemption(
    target_trove: address,
    debt_to_redeem: uint256,
    recipient: address,
    fee_bps: uint256
) -> (uint256, uint256):
    assert msg.sender == self.redemption_engine, "CALLER_NOT_REDEMPTION_ENGINE"
    assert self.troves[target_trove].is_active, "TROVE_INACTIVE"
    assert debt_to_redeem > 0, "ZERO_DEBT"

    t: Trove = self.troves[target_trove]
    actual_debt_redeemed: uint256 = debt_to_redeem
    if actual_debt_redeemed > t.debt:
        actual_debt_redeemed = t.debt

    price: uint256 = staticcall IPriceFeedOracle(self.price_oracle).get_price(self.collateral_token)
    gross_collateral: uint256 = (actual_debt_redeemed * WAD) // price
    assert gross_collateral <= t.collateral, "COLLATERAL_EXCEEDS_TROVE"

    fee_collateral: uint256 = (gross_collateral * fee_bps) // BPS
    net_collateral: uint256 = gross_collateral - fee_collateral

    new_debt: uint256 = t.debt - actual_debt_redeemed
    new_collateral: uint256 = t.collateral - gross_collateral

    self.total_debt -= actual_debt_redeemed
    self.total_collateral -= gross_collateral

    if new_debt == 0:
        self.troves[target_trove] = Trove(collateral=0, debt=0, is_active=False)
        self.trove_count -= 1
        if new_collateral > 0:
            # refund leftover collateral to borrower
            refund_ok: bool = extcall IERC20(self.collateral_token).transfer(target_trove, new_collateral)
            assert refund_ok, "REFUND_FAILED"
    else:
        self.troves[target_trove] = Trove(collateral=new_collateral, debt=new_debt, is_active=True)

    # Transfer collateral: net to recipient, fee to treasury
    send_recipient_ok: bool = extcall IERC20(self.collateral_token).transfer(recipient, net_collateral)
    assert send_recipient_ok, "SEND_RECIPIENT_FAILED"

    if fee_collateral > 0:
        send_fee_ok: bool = extcall IERC20(self.collateral_token).transfer(self.treasury, fee_collateral)
        assert send_fee_ok, "SEND_FEE_FAILED"

    log TroveRedeemed(
        borrower=target_trove,
        redeemer=recipient,
        debt_redeemed=actual_debt_redeemed,
        collateral_redeemed=net_collateral,
        fee_collateral=fee_collateral
    )

    return (net_collateral, fee_collateral)
