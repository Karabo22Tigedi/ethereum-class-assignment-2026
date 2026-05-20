// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// OrderBook lets users place buy and sell limit orders for two ERC20
// tokens and match them against each other. In this assignment tokenA
// is the base token (PNPT) and tokenB is the quote token (FNBT). The
// price on an order is how many tokenB units a trader pays or receives
// for one tokenA unit, and order sizes are always measured in tokenA.
//
// Both sides escrow upfront when they place an order, so settling a
// match is just two transfers from this contract.
contract OrderBook {
    using SafeERC20 for IERC20;

    // 0 = buy, 1 = sell. Used in storage and emitted in OrderPlaced.
    uint8 internal constant SIDE_BUY = 0;
    uint8 internal constant SIDE_SELL = 1;

    // Storage record for every order placed on the book. filled is
    // always in base (tokenA) units so remaining() works the same way
    // for buys and sells.
    struct Order {
        address trader;
        uint8 side;
        uint256 amount;
        uint256 filled;
        uint256 price;
        bool open;
    }

    IERC20 public immutable tokenA; // base token, PNPT
    IERC20 public immutable tokenB; // quote token, FNBT

    uint256 private _nextOrderId;
    mapping(uint256 => Order) private _orders;

    // Fired when a new order is added to the book. giveToken is the
    // token the trader just escrowed, takeToken is the one they get
    // back if the order fills.
    event OrderPlaced(
        uint256 indexed orderId,
        address indexed trader,
        uint8 side,
        address giveToken,
        address takeToken,
        uint256 amount,
        uint256 price
    );

    // Fired when a buy and a sell get crossed. filledAmount is the base
    // size that traded in this match.
    event OrderMatched(uint256 indexed buyOrderId, uint256 indexed sellOrderId, uint256 filledAmount, uint256 price);

    // Fired when the trader cancels what is left of their order and
    // gets their remaining escrow back.
    event OrderCanceled(uint256 indexed orderId, address indexed trader);

    error InvalidAmount();
    error InvalidPrice();
    error PriceMismatch();
    error UnauthorizedCancellation();
    error OrderNotOpen();
    error InvalidSidePairing();

    constructor(address _tokenA, address _tokenB) {
        tokenA = IERC20(_tokenA);
        tokenB = IERC20(_tokenB);
    }

    // Place a buy order for `amount` of tokenA at `price` tokenB each.
    // The caller has to approve this contract for amount * price of
    // tokenB beforehand, because the full quote cost is pulled in now
    // and held until either a match or a cancel.
    function placeBuyOrder(uint256 amount, uint256 price) external returns (uint256 orderId) {
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

        tokenB.safeTransferFrom(msg.sender, address(this), amount * price);

        emit OrderPlaced(orderId, msg.sender, SIDE_BUY, address(tokenB), address(tokenA), amount, price);
    }

    // Place a sell order for `amount` of tokenA at `price` tokenB each.
    // Mirror of placeBuyOrder, except the seller escrows tokenA.
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

        tokenA.safeTransferFrom(msg.sender, address(this), amount);

        emit OrderPlaced(orderId, msg.sender, SIDE_SELL, address(tokenA), address(tokenB), amount, price);
    }

    // Cross a buy with a sell. Caller passes the buy id first and the
    // sell id second, and the two orders must be at the exact same
    // price. The fill size is whichever side has less remaining, which
    // handles both full and partial fills with one code path.
    function matchOrders(uint256 buyOrderId, uint256 sellOrderId) external {
        Order storage buy = _orders[buyOrderId];
        Order storage sell = _orders[sellOrderId];

        if (buy.side != SIDE_BUY || sell.side != SIDE_SELL) revert InvalidSidePairing();
        if (!buy.open || !sell.open) revert OrderNotOpen();
        if (buy.price != sell.price) revert PriceMismatch();

        uint256 buyRemaining = buy.amount - buy.filled;
        uint256 sellRemaining = sell.amount - sell.filled;
        uint256 fillAmount = buyRemaining < sellRemaining ? buyRemaining : sellRemaining;

        uint256 quoteCost = fillAmount * buy.price;

        // Update bookkeeping before transferring anything out.
        buy.filled += fillAmount;
        sell.filled += fillAmount;
        if (buy.filled == buy.amount) buy.open = false;
        if (sell.filled == sell.amount) sell.open = false;

        tokenA.safeTransfer(buy.trader, fillAmount);  // base goes to buyer
        tokenB.safeTransfer(sell.trader, quoteCost);  // quote goes to seller

        emit OrderMatched(buyOrderId, sellOrderId, fillAmount, buy.price);
    }

    // Cancel an open order and refund the escrow on whatever has not
    // been filled yet. Only the original trader can cancel.
    function cancelOrder(uint256 orderId) external {
        Order storage order = _orders[orderId];

        // Authorisation check goes first so cancelling someone else's
        // already closed order still surfaces as Unauthorized.
        if (order.trader != msg.sender) revert UnauthorizedCancellation();
        if (!order.open) revert OrderNotOpen();

        uint256 baseRemaining = order.amount - order.filled;

        // Flip the flag before sending tokens so a token contract that
        // tries to reenter cannot drain the escrow twice.
        order.open = false;

        if (order.side == SIDE_BUY) {
            // Buyer escrowed quote, refund (remaining base) * price.
            uint256 quoteRefund = baseRemaining * order.price;
            if (quoteRefund > 0) {
                tokenB.safeTransfer(order.trader, quoteRefund);
            }
        } else {
            // Seller escrowed base directly, refund the unfilled part.
            if (baseRemaining > 0) {
                tokenA.safeTransfer(order.trader, baseRemaining);
            }
        }

        emit OrderCanceled(orderId, order.trader);
    }

    // How much base is still left to fill on this order.
    function remaining(uint256 orderId) external view returns (uint256) {
        Order storage order = _orders[orderId];
        return order.amount - order.filled;
    }

    // True while the order can still be filled or cancelled.
    function isOpen(uint256 orderId) external view returns (bool) {
        return _orders[orderId].open;
    }

    // Read the full order record. Useful for any UI or off chain code
    // that wants to display the state of the book.
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
