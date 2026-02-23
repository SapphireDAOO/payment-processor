import "helpers/helper.spec";

methods {
    function updateInvoiceNonce(uint216) external returns (uint216);

    function getNextInvoiceNonce() external returns (uint216) envfree;
    function totalInvoiceCreated() external returns (uint216) envfree;
    function authorized(address) external returns (bool) envfree;
}

definition mustIgnoreSomeCallToOwnable(method f) returns bool = f.selector != sig:cancelOwnershipHandover().selector && f.selector != sig:requestOwnershipHandover().selector && f.selector != sig:completeOwnershipHandover(address).selector && f.selector != sig:ownershipHandoverExpiresAt(address).selector;

ghost mathint next_invoice_nonce {
    init_state axiom next_invoice_nonce == 1;
}

ghost mathint sum_invoice_created {
    init_state axiom sum_invoice_created == 0;
}

hook Sload uint216 nonce nextInvoiceNonce {
    require nonce <= max_uint216, "stored nonce must fit into uint216";
}

hook Sstore nextInvoiceNonce uint216 newNonce (uint216 oldNonce) {
    next_invoice_nonce = newNonce;
    sum_invoice_created = newNonce - 1;
}

invariant totalInvoiceCreatedEqSum()
    sum_invoice_created == totalInvoiceCreated()
    filtered { f -> mustIgnoreSomeCallToOwnable(f) }

invariant nextInvoiceNonceIsNotZero()
    next_invoice_nonce == getNextInvoiceNonce()
    filtered { f -> mustIgnoreSomeCallToOwnable(f) }

invariant InvoiceNonceAtleastOne()
    next_invoice_nonce >= 1
    filtered { f -> mustIgnoreSomeCallToOwnable(f) }

rule updateInvoiceNonce_shouldIncreaseInvoiceNonce(env e, uint216 amount) {
    requireInvariant nextInvoiceNonceIsNotZero();

    mathint nonceBefore = getNextInvoiceNonce();

    require nonceBefore + amount <= max_uint216, "must not exceed maximum uint216";

    require authorized(e.msg.sender), "caller must be authorized";
    mathint newNonce = updateInvoiceNonce(e, amount);

    mathint nonceAfter = getNextInvoiceNonce();

    assert nonceAfter == nonceBefore + amount;
    assert newNonce == totalInvoiceCreated(), "current nonce must equal the total invoice created";
}

rule updateInvoiceNonce_reverts(env e, uint216 amount) {
    require nonpayable(e), "value must be zero";
    mathint nonceBefore = getNextInvoiceNonce();
    require nonceBefore >= 1, "invoice nonce must be at least one";

    updateInvoiceNonce@withrevert(e, amount);
    bool isReverted = lastReverted;

    assert lastReverted <=> !authorized(e.msg.sender) || nonceBefore + amount > max_uint216, "sender is not authorized or nonce exceed maximum uint216";
}

rule onlyUpdateInvoiceNonceCanIncreaseCounters(env e, method f, calldataarg args) filtered { f -> mustIgnoreSomeCallToOwnable(f) } {
    requireInvariant nextInvoiceNonceIsNotZero();

    mathint totalInvoiceBefore = totalInvoiceCreated();
    mathint nextInvoiceNonceBefore = getNextInvoiceNonce();

    f@withrevert(e, args);
    bool isReverted = lastReverted;

    mathint totalInvoiceAfter = totalInvoiceCreated();
    mathint nextInvoiceNonceAfter = getNextInvoiceNonce();

    if (isReverted) {
        assert totalInvoiceAfter == totalInvoiceBefore;
        assert nextInvoiceNonceAfter == nextInvoiceNonceBefore;
    } else {
        bool increased = totalInvoiceAfter > totalInvoiceBefore && nextInvoiceNonceAfter > nextInvoiceNonceBefore;
        assert increased => (f.selector == sig:updateInvoiceNonce(uint216).selector);
    }
}
