// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

contract SimplePerp is ReentrancyGuard, AccessControl {
    IERC20 public immutable collateralToken;

    uint256 public constant DECIMALS = 1e18;
    uint256 public constant MAX_LEVERAGE = 100e18;
    uint8 public collateralDecimals;

    uint256 public maintenanceMarginRatio = 5e15;
    uint256 public liquidationFeeRatio = 5e16;

    uint256 public orderCounter = 1;
    uint256 public positionCounter = 1;

    bytes32 public constant LIQUIDATOR_ROLE = keccak256("LIQUIDATOR_ROLE");

    struct Position {
        address owner;
        address asset;
        bool isLong;
        uint256 size;
        uint256 entryPrice;
        uint256 margin;
        uint256 lastFundingPaid;
        uint256 leverage;
        bool exists;
    }

    struct Order {
        address owner;
        address asset;
        bool isLong;
        uint256 price;
        uint256 size;
        uint256 margin;
        uint256 leverage;
        bool active;
    }

    modifier onlyLiquidator() {
        require(hasRole(LIQUIDATOR_ROLE, msg.sender), "Not a liquidator");
        _;
    }

    mapping(address => uint256) public collateralBalance;
    mapping(uint256 => Position) public positions;
    mapping(address => uint256[]) public userPositions;
    mapping(uint256 => Order) public orders;
    mapping(address => AggregatorV3Interface) public priceFeeds;

    event Deposit(address indexed user, uint256 amount);
    event Withdraw(address indexed user, uint256 amount);
    event OpenPosition(
        uint256 indexed posId,
        address indexed asset,
        address indexed user,
        bool isLong,
        uint256 size,
        uint256 entryPrice,
        uint256 margin,
        uint256 leverage
    );
    event ClosePosition(uint256 indexed posId, address indexed user, uint256 exitPrice, int256 finalBalance);
    event Liquidate(uint256 indexed posId, address indexed liqBy, uint256 liquidationFee, int256 finalBalance);
    event CreateOrder(
        uint256 indexed orderId,
        address indexed asset,
        address indexed user,
        bool isLong,
        uint256 price,
        uint256 size,
        uint256 leverage,
        uint256 margin
    );
    event CancelOrder(uint256 indexed orderId, address indexed user);
    event ExecuteOrder(uint256 indexed orderId, address indexed executor, uint256 fillPrice);

    constructor(address _collateralToken, address _defaultAdmin) {
        require(_collateralToken != address(0), "zero token");
        collateralToken = IERC20(_collateralToken);
        collateralDecimals = IERC20Metadata(_collateralToken).decimals();

        _grantRole(DEFAULT_ADMIN_ROLE, _defaultAdmin);
        _grantRole(LIQUIDATOR_ROLE, _defaultAdmin);
    }

    // ---------------- Decimal Convert Helper ----------------
    function _tokenToInternal(uint256 tokenAmount) internal view returns (uint256) {
        return tokenAmount * DECIMALS / (10 ** uint256(collateralDecimals));
    }

    function _internalToToken(uint256 internalAmount) internal view returns (uint256) {
        return internalAmount * (10 ** uint256(collateralDecimals)) / DECIMALS;
    }

    // ---------------- Deposits & Withdrawals ----------------
    function deposit(uint256 amount) external nonReentrant {
        require(amount > 0, "zero");
        uint256 tokenAmount = _internalToToken(amount);
        require(tokenAmount > 0, "token amount zero (too small)");

        collateralToken.transferFrom(msg.sender, address(this), tokenAmount);
        collateralBalance[msg.sender] += amount;
        emit Deposit(msg.sender, amount);
    }

    function withdraw(uint256 amount) external nonReentrant {
        require(amount > 0, "zero");
        require(collateralBalance[msg.sender] >= amount, "insufficient balance");

        collateralBalance[msg.sender] -= amount;
        uint256 tokenAmount = _internalToToken(amount);
        collateralToken.transfer(msg.sender, tokenAmount);
        emit Withdraw(msg.sender, amount);
    }

    // ---------------- Oracle helper ----------------
    function getPriceInUsd(address asset) public view returns (uint256) {
        require(asset != address(0), "asset address is 0");
        AggregatorV3Interface feed = priceFeeds[asset];
        require(address(feed) != address(0), "no feed for asset");

        uint8 feedDecimals = AggregatorV3Interface(address(feed)).decimals();

        (, int256 price,,,) = feed.latestRoundData();
        require(price > 0, "invalid price");

        if (feedDecimals < 18) {
            return uint256(price) * (10 ** (18 - feedDecimals));
        } else if (feedDecimals > 18) {
            return uint256(price) / (10 ** (feedDecimals - 18));
        } else {
            return uint256(price);
        }
    }

    // ---------------- Math helpers ----------------
    function _initialMargin(uint256 size, uint256 leverage) internal pure returns (uint256) {
        require(leverage > 0, "zero leverage");
        return (size * DECIMALS) / leverage;
    }

    function _unrealizedPnl(Position memory pos, uint256 price) internal pure returns (int256) {
        if (pos.entryPrice == 0) return 0;
        int256 diff = int256(price) - int256(pos.entryPrice);
        int256 pnl = int256(pos.size) * diff / int256(pos.entryPrice);
        return pos.isLong ? pnl : -pnl;
    }

    function _equity(Position memory pos, uint256 price) internal pure returns (int256) {
        int256 pnl = _unrealizedPnl(pos, price);
        return int256(pos.margin) + pnl;
    }

    function _maintenanceMargin(uint256 size) public view returns (uint256) {
        return (size * maintenanceMarginRatio) / DECIMALS;
    }

    // ---------------- Open market position ----------------
    function openMarketPosition(address asset, bool isLong, uint256 size, uint256 leverage) external nonReentrant {
        require(asset != address(0), "asset address is 0");
        require(leverage >= 1e18 && leverage <= MAX_LEVERAGE, "bad leverage");
        require(size > 0, "bad size");

        uint256 price = getPriceInUsd(asset);
        uint256 reqMarginInternal = _initialMargin(size, leverage);
        require(collateralBalance[msg.sender] >= reqMarginInternal, "insufficient collateral");

        collateralBalance[msg.sender] -= reqMarginInternal;

        uint256 pid = positionCounter++;
        positions[pid] = Position({
            owner: msg.sender,
            asset: asset,
            isLong: isLong,
            size: size,
            leverage: leverage,
            entryPrice: price,
            margin: reqMarginInternal,
            lastFundingPaid: block.timestamp,
            exists: true
        });
        userPositions[msg.sender].push(pid);

        emit OpenPosition(pid, asset, msg.sender, isLong, size, price, reqMarginInternal, leverage);
    }

    // ---------------- On-chain limit order ----------------
    function createLimitOrder(address asset, bool isLong, uint256 price, uint256 size, uint256 leverage)
        external
        nonReentrant
        returns (uint256)
    {
        require(asset != address(0), "asset address is 0");
        require(leverage >= 1e18 && leverage <= MAX_LEVERAGE, "bad leverage");
        require(price > 0 && size > 0, "bad params");

        uint256 reqMargin = _initialMargin(size, leverage);
        require(collateralBalance[msg.sender] >= reqMargin, "insufficient collateral for order");

        collateralBalance[msg.sender] -= reqMargin;

        uint256 oid = orderCounter++;
        orders[oid] = Order({
            owner: msg.sender,
            asset: asset,
            isLong: isLong,
            price: price,
            size: size,
            leverage: leverage,
            active: true,
            margin: reqMargin
        });

        emit CreateOrder(oid, asset, msg.sender, isLong, price, size, leverage, reqMargin);
        return oid;
    }

    function cancelOrder(uint256 orderId) external nonReentrant {
        Order storage o = orders[orderId];
        require(o.active, "not active");
        require(o.owner == msg.sender, "not owner");
        o.active = false;

        uint256 refund = o.margin;
        collateralBalance[msg.sender] += refund;

        emit CancelOrder(orderId, msg.sender);
    }

    function executeOrder(uint256 orderId) external nonReentrant onlyLiquidator {
        Order storage o = orders[orderId];
        require(o.active, "not active");
        uint256 marketPrice = getPriceInUsd(o.asset);

        if (o.isLong) {
            require(marketPrice <= o.price, "market price above long limit");
        } else {
            require(marketPrice >= o.price, "market price below short limit");
        }

        o.active = false;

        uint256 pid = positionCounter++;
        uint256 lockedMargin = o.margin;
        positions[pid] = Position({
            owner: o.owner,
            asset: o.asset,
            isLong: o.isLong,
            size: o.size,
            leverage: o.leverage,
            entryPrice: marketPrice,
            margin: lockedMargin,
            lastFundingPaid: block.timestamp,
            exists: true
        });
        userPositions[o.owner].push(pid);

        emit ExecuteOrder(orderId, msg.sender, marketPrice);
        emit OpenPosition(pid, o.asset, o.owner, o.isLong, o.size, marketPrice, lockedMargin, o.leverage);
    }

    // ---------------- Close position ----------------
    function closePosition(uint256 posId) external nonReentrant {
        Position storage pos = positions[posId];
        require(pos.exists, "no position");
        require(pos.owner == msg.sender, "not owner");

        uint256 price = getPriceInUsd(pos.asset);
        int256 finalBal = _equity(pos, price);

        if (finalBal > 0) {
            collateralBalance[msg.sender] += uint256(finalBal);
        } else {}

        emit ClosePosition(posId, msg.sender, price, finalBal);
        delete positions[posId];
    }

    // ---------------- Liquidation ----------------
    function isLiquidatable(uint256 posId) public view returns (bool) {
        Position memory pos = positions[posId];
        require(pos.exists, "no pos");
        uint256 price = getPriceInUsd(pos.asset);
        int256 equity = _equity(pos, price);
        uint256 maint = _maintenanceMargin(pos.size);
        return equity < int256(maint);
    }

    function liquidate(uint256 posId) external nonReentrant onlyLiquidator {
        Position storage pos = positions[posId];
        require(pos.exists, "no pos");
        require(isLiquidatable(posId), "not liquidatable");

        uint256 price = getPriceInUsd(pos.asset);
        int256 finalBal = _equity(pos, price);
        uint256 liqFee = 0;

        if (finalBal > 0) {
            uint256 remainder = uint256(finalBal);
            liqFee = (remainder * liquidationFeeRatio) / DECIMALS;
            collateralBalance[pos.owner] += (remainder - liqFee);
            collateralBalance[msg.sender] += liqFee;
            emit Liquidate(posId, msg.sender, liqFee, finalBal);
        } else {
            emit Liquidate(posId, msg.sender, 0, finalBal);
        }

        delete positions[posId];
    }

    // ---------------- Admin ----------------
    function setMaintenanceMarginRatio(uint256 v) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(v <= DECIMALS / 10, "too large"); // <=10%
        maintenanceMarginRatio = v;
    }

    function setPriceFeed(address asset, address feed) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(asset != address(0) && feed != address(0), "zero address");
        priceFeeds[asset] = AggregatorV3Interface(feed);
    }

    function setLiquidationFeeRatio(uint256 v) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(v <= DECIMALS, "too large");
        liquidationFeeRatio = v;
    }

    function addAdmin(address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(account != address(0), "zero address");
        _grantRole(DEFAULT_ADMIN_ROLE, account);
    }

    function addLiquidator(address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(account != address(0), "zero address");
        _grantRole(LIQUIDATOR_ROLE, account);
    }

    // ---------------- View helpers ----------------
    function getUserPositions(address user) external view returns (uint256[] memory) {
        return userPositions[user];
    }

    function getOrder(uint256 oid) external view returns (Order memory) {
        return orders[oid];
    }

    function getFeed(address asset) external view returns (address) {
        return address(priceFeeds[asset]);
    }
}
