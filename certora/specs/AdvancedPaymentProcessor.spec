methods {
    // Core invoice + meta-invoice lifecycle
    function createSingleInvoice(calldataarg) external returns (uint216);
    function createMetaInvoice(calldataarg) external returns (uint216);
    function payInvoice(uint216, address) external;
    function payMetaInvoice(uint216, address) external;
    function createDispute(uint216) external;
    function handleDispute(uint216, uint8, uint256) external;
    function release(uint216) external;
    function refund(uint216, uint256) external;
    function cancelInvoice(uint216) external;
    function resolveDispute(uint216) external;

    // Chainlink automation
    function checkUpkeep(bytes) external;
    function performUpkeep(bytes) external;

    // Admin/config
    function setPriceFeed(address, address) external;
    function setInvoiceReleaseTime(uint216, uint256) external;
    function setForwarderAddress(address) external;

    // Views
    function getForwarder() external returns (address) envfree;
    function getTokenValueFromUsd(address, uint256) external returns (uint256) envfree;
    function getInvoice(uint216) external;
    function getMetaInvoice(uint216) external;
    function totalUniqueInvoiceCreated() external returns (uint216) envfree;
    function totalMetaInvoiceCreated() external returns (uint216) envfree;
    function getNextInvoiceNonce() external returns (uint216) envfree;
    function getNextMetaInvoiceNonce() external returns (uint216) envfree;
    function getItems() external;

    // Inherited EscrowFactory public methods
    function computeSalt(address, address, uint216) external returns (bytes32) envfree;
    function getPredictedAddress(bytes32) external returns (address) envfree;

    // Public immutable / state getters
    function ppStorage() external returns (address) envfree;

    // Public constants
    function CREATED() external returns (uint8) envfree;
    function PAID() external returns (uint8) envfree;
    function REFUNDED() external returns (uint8) envfree;
    function CANCELED() external returns (uint8) envfree;
    function DISPUTED() external returns (uint8) envfree;
    function DISPUTE_RESOLVED() external returns (uint8) envfree;
    function DISPUTE_DISMISSED() external returns (uint8) envfree;
    function DISPUTE_SETTLED() external returns (uint8) envfree;
    function RELEASED() external returns (uint8) envfree;
    function BASIS_POINTS() external returns (uint256) envfree;
    function DEFAULT_DECIMAL() external returns (uint8) envfree;
    function STALE_THRESHOLD() external returns (uint256) envfree;
}
