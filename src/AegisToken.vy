#pragma version ^0.4.0

"""
@title AegisToken (AEGIS)
@notice Decentralized Synthetic Dollar for the AegisMint CDP Protocol.
@dev Compliant ERC-20 token with authorized minting and burning roles.
"""

# Events
event Transfer:
    sender: indexed(address)
    receiver: indexed(address)
    value: uint256

event Approval:
    owner: indexed(address)
    spender: indexed(address)
    value: uint256

event MinterUpdated:
    minter: indexed(address)
    status: bool

event OwnershipTransferred:
    previous_owner: indexed(address)
    new_owner: indexed(address)

# State Variables
name: public(String[32])
symbol: public(String[32])
decimals: public(uint8)
totalSupply: public(uint256)

balanceOf: public(HashMap[address, uint256])
allowance: public(HashMap[address, HashMap[address, uint256]])

owner: public(address)
minters: public(HashMap[address, bool])

@deploy
def __init__():
    self.name = "Aegis Dollar"
    self.symbol = "AEGIS"
    self.decimals = 18
    self.owner = msg.sender
    log OwnershipTransferred(previous_owner=empty(address), new_owner=msg.sender)

@external
def set_minter(minter: address, status: bool):
    assert msg.sender == self.owner, "UNAUTHORIZED"
    assert minter != empty(address), "ZERO_ADDRESS"
    self.minters[minter] = status
    log MinterUpdated(minter=minter, status=status)

@external
def transfer_ownership(new_owner: address):
    assert msg.sender == self.owner, "UNAUTHORIZED"
    assert new_owner != empty(address), "ZERO_ADDRESS"
    log OwnershipTransferred(previous_owner=self.owner, new_owner=new_owner)
    self.owner = new_owner

@external
def mint(to: address, amount: uint256) -> bool:
    assert self.minters[msg.sender] or msg.sender == self.owner, "NOT_MINTER"
    assert to != empty(address), "MINT_TO_ZERO"
    self.totalSupply += amount
    self.balanceOf[to] += amount
    log Transfer(sender=empty(address), receiver=to, value=amount)
    return True

@external
def burn(from_account: address, amount: uint256) -> bool:
    assert self.minters[msg.sender] or msg.sender == self.owner, "NOT_MINTER"
    assert self.balanceOf[from_account] >= amount, "INSUFFICIENT_BALANCE"
    self.balanceOf[from_account] -= amount
    self.totalSupply -= amount
    log Transfer(sender=from_account, receiver=empty(address), value=amount)
    return True

@external
def transfer(receiver: address, amount: uint256) -> bool:
    assert receiver != empty(address), "TRANSFER_TO_ZERO"
    assert self.balanceOf[msg.sender] >= amount, "INSUFFICIENT_BALANCE"
    self.balanceOf[msg.sender] -= amount
    self.balanceOf[receiver] += amount
    log Transfer(sender=msg.sender, receiver=receiver, value=amount)
    return True

@external
def transferFrom(sender: address, receiver: address, amount: uint256) -> bool:
    assert receiver != empty(address), "TRANSFER_TO_ZERO"
    assert self.balanceOf[sender] >= amount, "INSUFFICIENT_BALANCE"
    
    current_allowance: uint256 = self.allowance[sender][msg.sender]
    if current_allowance != max_value(uint256):
        assert current_allowance >= amount, "INSUFFICIENT_ALLOWANCE"
        self.allowance[sender][msg.sender] = current_allowance - amount
        log Approval(owner=sender, spender=msg.sender, value=current_allowance - amount)

    self.balanceOf[sender] -= amount
    self.balanceOf[receiver] += amount
    log Transfer(sender=sender, receiver=receiver, value=amount)
    return True

@external
def approve(spender: address, amount: uint256) -> bool:
    assert spender != empty(address), "APPROVE_TO_ZERO"
    self.allowance[msg.sender][spender] = amount
    log Approval(owner=msg.sender, spender=spender, value=amount)
    return True
