import "../helpers/helper.spec";

methods {
    // Core invoice lifecycle
    function createInvoice(uint256, bytes, bool) external returns (uint216);
    function pay(uint216, bytes, bool) external returns (address);
    function acceptPayment(uint216) external;
    function rejectPayment(uint216) external;
    function cancelInvoice(uint216) external;
    function release(uint216) external;
    function refundBuyer(uint216) external;

    // Chainlink automation
    function checkUpkeep(bytes) external;
    function performUpkeep(bytes) external;

    // Admin/config
    function setInvoiceReleaseTime(uint216, uint32) external;
    function setMinimumInvoiceValue(uint256) external;
    function setForwarderAddress(address) external;
    function setDecisionWindow(uint256) external;

    // Views
    function calculateFee(uint256) external returns (uint256) envfree;
    function getForwarder() external returns (address) envfree;
    function getNextInvoiceNonce() external returns (uint216) envfree;
    function getInvoiceData(uint216) external;
    function getMinimumInvoiceValue() external returns (uint256) envfree;
    function getItems() external;

    // Public immutable / state getters
    function ppStorage() external returns (address) envfree;
    function decisionWindow() external returns (uint256) envfree;

    // Public constants
    function CREATED() external returns (uint8) envfree;
    function PAID() external returns (uint8) envfree;
    function ACCEPTED() external returns (uint8) envfree;
    function REJECTED() external returns (uint8) envfree;
    function CANCELLED() external returns (uint8) envfree;
    function REFUNDED() external returns (uint8) envfree;
    function RELEASED() external returns (uint8) envfree;
    function BASIS_POINTS() external returns (uint256) envfree;
    function DEFAULT_SELLER_DECISION_WINDOW() external returns (uint256) envfree;
}
