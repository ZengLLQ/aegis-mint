#pragma version ^0.4.0

"""
@title PriceFeedOracle
@notice Robust Multi-Asset Price Oracle Registry for the AegisMint CDP Protocol.
@dev Supports direct fixed/testing quotes and oracle feed routing with staleness guards.
"""

# Events
event PriceUpdated:
    asset: indexed(address)
    price: uint256
    updated_at: uint256

event MaxAgeUpdated:
    asset: indexed(address)
    max_age: uint256

event OwnershipTransferred:
    previous_owner: indexed(address)
    new_owner: indexed(address)

# State Variables
owner: public(address)

struct PriceData:
    price: uint256
    updated_at: uint256
    max_age: uint256
    is_active: bool

prices: public(HashMap[address, PriceData])

@deploy
def __init__():
    self.owner = msg.sender
    log OwnershipTransferred(previous_owner=empty(address), new_owner=msg.sender)

@external
def transfer_ownership(new_owner: address):
    assert msg.sender == self.owner, "UNAUTHORIZED"
    assert new_owner != empty(address), "ZERO_ADDRESS"
    log OwnershipTransferred(previous_owner=self.owner, new_owner=new_owner)
    self.owner = new_owner

@external
def set_asset_price(asset: address, price: uint256, max_age: uint256):
    assert msg.sender == self.owner, "UNAUTHORIZED"
    assert asset != empty(address), "ZERO_ADDRESS"
    assert price > 0, "INVALID_PRICE"
    assert max_age > 0, "INVALID_MAX_AGE"

    self.prices[asset] = PriceData(
        price=price,
        updated_at=block.timestamp,
        max_age=max_age,
        is_active=True
    )
    log PriceUpdated(asset=asset, price=price, updated_at=block.timestamp)
    log MaxAgeUpdated(asset=asset, max_age=max_age)

@external
def update_price(asset: address, price: uint256):
    assert msg.sender == self.owner, "UNAUTHORIZED"
    assert self.prices[asset].is_active, "ASSET_NOT_ACTIVE"
    assert price > 0, "INVALID_PRICE"

    self.prices[asset].price = price
    self.prices[asset].updated_at = block.timestamp
    log PriceUpdated(asset=asset, price=price, updated_at=block.timestamp)

@view
@external
def get_price(asset: address) -> uint256:
    data: PriceData = self.prices[asset]
    assert data.is_active, "PRICE_NOT_REGISTERED"
    assert block.timestamp >= data.updated_at, "FUTURE_TIMESTAMP"
    assert block.timestamp - data.updated_at <= data.max_age, "STALE_PRICE"
    assert data.price > 0, "ZERO_PRICE"
    return data.price
