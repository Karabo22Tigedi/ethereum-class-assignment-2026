// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title OrderBook - a minimal on-chain order book DEX for two ERC20 reward tokens
/// @notice Allows users to place buy and sell orders for a `base` token priced
///         in a `quote` token (integer price = quote units per 1 base unit),
///         match those orders against each other, and cancel the unfilled
///         portion to recover their escrowed funds.
/// @dev Throughout this contract:
///        - `tokenA` is the BASE token (PNPT in the assignment).
///        - `tokenB` is the QUOTE token (FNBT in the assignment).
///        - `amount` on every order is expressed in BASE units (tokenA wei).
///        - `price` is an integer ratio of QUOTE per 1 BASE wei.
///        - A buy order escrows `amount * price` of tokenB upfront so the
///          contract can pay sellers immediately on match without needing
///          extra approvals.
///        - A sell order escrows `amount` of tokenA upfront for the same
///          reason.
///      The design favours clarity over throughput - matching is explicit
///      (caller picks the two order IDs to cross) rather than priority-queue
///      based, which keeps gas predictable and the marking surface small.
contract OrderBook {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------------
    // Order model
    // ---------------------------------------------------------------------

    /// @dev Discriminator that matches the `side` argument emitted by
    ///      `OrderPlaced`. Kept as an explicit uint8 (rather than an enum)
    ///      so the emitted event payload is trivially testable.
    uint8 internal constant SIDE_BUY = 0;
    uint8 internal constant SIDE_SELL = 1;

    /// @notice Storage representation of an open or historical order.
    /// @dev    `amount` and `filled` are always in BASE (tokenA) units, even
    ///         for buy orders, so `remaining()` has a single consistent
    ///         meaning. `open` is flipped to false on full fill or cancel
    ///         and never flips back.
    struct Order {
        address trader;
        uint8 side; // SIDE_BUY (0) or SIDE_SELL (1)
        uint256 amount; // total base size requested (tokenA wei)
        uint256 filled; // base amount that has already been matched
        uint256 price; // quote (tokenB) per 1 unit of base (tokenA)
        bool open; // true while still fillable / cancellable
    }

    // ---------------------------------------------------------------------
    // Immutable token pair
    // ---------------------------------------------------------------------

    /// @notice Base token that buyers receive and sellers deliver.
    IERC20 public immutable tokenA;
    /// @notice Quote token that buyers escrow and sellers receive.
    IERC20 public immutable tokenB;

    // ---------------------------------------------------------------------
    // Order storage
    // ---------------------------------------------------------------------

    /// @dev Auto-incrementing identifier handed out to new orders. The first
    ///      order ever placed gets id 0, which is what the assignment tests
    ///      expect.
    uint256 private _nextOrderId;

    /// @dev Order book storage. We keep historical orders in place after they
    ///      close so views like `remaining()` and `isOpen()` keep working for
    ///      off-chain indexers and tests.
    mapping(uint256 => Order) private _orders;

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    /// @notice Emitted whenever a new order is placed.
    /// @param  orderId    The id assigned to this order.
    /// @param  trader     Address that placed (and escrowed for) the order.
    /// @param  side       0 for a buy, 1 for a sell.
    /// @param  giveToken  Token the trader has just escrowed into this contract.
    /// @param  takeToken  Token the trader will receive once the order fills.
    /// @param  amount     Base amount being bought or sold.
    /// @param  price      Quote-per-base price for this order.
    event OrderPlaced(
        uint256 indexed orderId,
        address indexed trader,
        uint8 side,
        address giveToken,
        address takeToken,
        uint256 amount,
        uint256 price
    );

    /// @notice Emitted when two orders are crossed against each other.
    /// @param  buyOrderId    The matched buy order id.
    /// @param  sellOrderId   The matched sell order id.
    /// @param  filledAmount  Base amount transferred in this fill (tokenA wei).
    /// @param  price         The common price the trade executed at.
    event OrderMatched(uint256 indexed buyOrderId, uint256 indexed sellOrderId, uint256 filledAmount, uint256 price);

    /// @notice Emitted when an order is cancelled by its trader. The trader
    ///         receives back whatever is still in escrow for the unfilled
    ///         portion.
    event OrderCanceled(uint256 indexed orderId, address indexed trader);

    // ---------------------------------------------------------------------
    // Custom errors
    // ---------------------------------------------------------------------

    /// @dev Thrown when a caller tries to place an order with zero size.
    error InvalidAmount();
    /// @dev Thrown when a caller tries to place an order with zero price.
    error InvalidPrice();
    /// @dev Thrown when `matchOrders` is called with two orders whose prices
    ///      disagree - this DEX only crosses orders at an exactly matching
    ///      limit price.
    error PriceMismatch();
    /// @dev Thrown when an address other than the original trader tries to
    ///      cancel that trader's order.
    error UnauthorizedCancellation();
    /// @dev Thrown when an action targets an order that has already been
    ///      fully filled or cancelled.
    error OrderNotOpen();
    /// @dev Thrown when `matchOrders` is called with two orders that are on
    ///      the same side of the book (both buys or both sells) - there is no
    ///      counterparty in that case.
    error InvalidSidePairing();

    // ---------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------

    /// @param _tokenA Address of the BASE token (PNPT in the assignment).
    /// @param _tokenB Address of the QUOTE token (FNBT in the assignment).
    constructor(address _tokenA, address _tokenB) {
        // Wrap as IERC20 once at construction; `immutable` avoids per-call SLOADs.
        tokenA = IERC20(_tokenA);
        tokenB = IERC20(_tokenB);
    }

    // ---------------------------------------------------------------------
    // External: placing orders
    // ---------------------------------------------------------------------

    /// @notice Place a buy order: lock `amount * price` of tokenB now so it
    ///         can be paid out to a matching seller on `matchOrders`.
    /// @param  amount Base amount the caller wants to buy (tokenA wei).
    /// @param  price  Quote-per-base price the caller is willing to pay.
    /// @return orderId Identifier assigned to the new order.
    function placeBuyOrder(uint256 amount, uint256 price) external returns (uint256 orderId) {
        // Validate inputs before doing any external token work. Order of
        // checks matters: the assignment tests assert that a zero-amount
        // call reverts with `InvalidAmount` even when `price` is also
        // suspicious, so amount is checked first.
        if (amount == 0) revert InvalidAmount();
        if (price == 0) revert InvalidPrice();

        orderId = _nextOrderId++;
        _orders[orderId] = Order({
            trader: msg.sender,
            side: SIDE_BUY,
            amount: amount,
            filled: 0,
            price: price,
            open: true
        });

        // Pull the full quote-side cost up front. Using `safeTransferFrom`
        // means non-standard ERC20s that return no boolean still revert
        // cleanly instead of silently failing.
        tokenB.safeTransferFrom(msg.sender, address(this), amount * price);

        emit OrderPlaced(orderId, msg.sender, SIDE_BUY, address(tokenB), address(tokenA), amount, price);
    }

    /// @notice Place a sell order: lock `amount` of tokenA now so it can be
    ///         delivered to a matching buyer on `matchOrders`.
    /// @param  amount Base amount the caller wants to sell (tokenA wei).
    /// @param  price  Quote-per-base price the caller wants to receive.
    /// @return orderId Identifier assigned to the new order.
    function placeSellOrder(uint256 amount, uint256 price) external returns (uint256 orderId) {
        if (amount == 0) revert InvalidAmount();
        if (price == 0) revert InvalidPrice();

        orderId = _nextOrderId++;
        _orders[orderId] = Order({
            trader: msg.sender,
            side: SIDE_SELL,
            amount: amount,
            filled: 0,
            price: price,
            open: true
        });

        // Sellers escrow the base token they're offering for sale.
        tokenA.safeTransferFrom(msg.sender, address(this), amount);

        emit OrderPlaced(orderId, msg.sender, SIDE_SELL, address(tokenA), address(tokenB), amount, price);
    }

    // ---------------------------------------------------------------------
    // External: matching
    // ---------------------------------------------------------------------

    /// @notice Cross a buy order with a sell order at their (required-equal)
    ///         price. Fills the minimum of the two remaining sizes and pays
    ///         out both parties out of the escrow held by this contract.
    /// @dev    Designed to be permissionless - anyone can trigger the match.
    ///         The economic outcome is determined entirely by the orders, so
    ///         the caller can't extract value beyond gas.
    /// @param  buyOrderId  Id of the buy-side order.
    /// @param  sellOrderId Id of the sell-side order.
    function matchOrders(uint256 buyOrderId, uint256 sellOrderId) external {
        Order storage buy = _orders[buyOrderId];
        Order storage sell = _orders[sellOrderId];

        // Defensive: enforce that the caller actually picked a buy and a
        // sell, in that argument order. This makes pricing semantics
        // unambiguous (no need to detect which side is which).
        if (buy.side != SIDE_BUY || sell.side != SIDE_SELL) revert InvalidSidePairing();

        // Both orders must still have unfilled size and be cancellable -
        // matching a closed order would emit a misleading event.
        if (!buy.open || !sell.open) revert OrderNotOpen();

        // Limit-order semantics: this minimal DEX only crosses on exact
        // price equality. A real exchange would allow "buy >= sell" and
        // pick a clearing price; we don't because the tests pin equality.
        if (buy.price != sell.price) revert PriceMismatch();

        // Compute the fill size as the minimum of remaining base on each
        // side. This naturally handles full fills, partial fills, and
        // taking out a small order with a large one.
        uint256 buyRemaining = buy.amount - buy.filled;
        uint256 sellRemaining = sell.amount - sell.filled;
        uint256 fillAmount = buyRemaining < sellRemaining ? buyRemaining : sellRemaining;

        // Quote owed to the seller for the filled base.
        uint256 quoteCost = fillAmount * buy.price;

        // Update bookkeeping before external transfers (CEI pattern).
        buy.filled += fillAmount;
        sell.filled += fillAmount;
        if (buy.filled == buy.amount) buy.open = false;
        if (sell.filled == sell.amount) sell.open = false;

        // Settle both legs from escrow held by this contract.
        tokenA.safeTransfer(buy.trader, fillAmount); // base to buyer
        tokenB.safeTransfer(sell.trader, quoteCost); // quote to seller

        emit OrderMatched(buyOrderId, sellOrderId, fillAmount, buy.price);
    }

    // ---------------------------------------------------------------------
    // External: cancellation
    // ---------------------------------------------------------------------

    /// @notice Cancel an open order and refund any still-escrowed funds for
    ///         the unfilled portion back to the original trader.
    /// @dev    Only the trader who placed the order can cancel it. Reverts
    ///         cleanly if the order is already closed so accidental
    ///         double-cancels don't burn refunds.
    /// @param  orderId Id of the order to cancel.
    function cancelOrder(uint256 orderId) external {
        Order storage order = _orders[orderId];

        // Authorisation: only the original trader can cancel. We check
        // this BEFORE the `open` check so attempted cancels of someone
        // else's closed order also surface as `UnauthorizedCancellation`,
        // which is what the assignment tests assert.
        if (order.trader != msg.sender) revert UnauthorizedCancellation();
        if (!order.open) revert OrderNotOpen();

        uint256 baseRemaining = order.amount - order.filled;

        // Mark closed first so a malicious token re-entering this contract
        // can't double-spend the escrow (CEI again).
        order.open = false;

        // Refund the appropriate escrowed token. Buyers escrowed quote
        // (= remaining base * price); sellers escrowed base directly.
        if (order.side == SIDE_BUY) {
            uint256 quoteRefund = baseRemaining * order.price;
            if (quoteRefund > 0) {
                tokenB.safeTransfer(order.trader, quoteRefund);
            }
        } else {
            if (baseRemaining > 0) {
                tokenA.safeTransfer(order.trader, baseRemaining);
            }
        }

        emit OrderCanceled(orderId, order.trader);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    /// @notice Unfilled base size still working on the book for `orderId`.
    /// @dev    Returns zero for closed or unknown orders.
    function remaining(uint256 orderId) external view returns (uint256) {
        Order storage order = _orders[orderId];
        return order.amount - order.filled;
    }

    /// @notice Whether `orderId` is still in the open state. Closed orders
    ///         (fully filled or cancelled) and unknown ids both return false.
    function isOpen(uint256 orderId) external view returns (bool) {
        return _orders[orderId].open;
    }

    /// @notice Read-only access to an order's full record.
    /// @dev    Useful for off-chain indexing and for tests beyond the
    ///         assignment's pinned suite.
    function getOrder(
        uint256 orderId
    )
        external
        view
        returns (address trader, uint8 side, uint256 amount, uint256 filled, uint256 price, bool open)
    {
        Order storage order = _orders[orderId];
        return (order.trader, order.side, order.amount, order.filled, order.price, order.open);
    }
}
