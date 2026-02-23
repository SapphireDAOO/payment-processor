definition exist(uint256 id) returns bool = id != 0;

definition clock(env e) returns mathint = e.block.timestamp;

definition nonpayable(env e) returns bool = e.msg.value == 0;
