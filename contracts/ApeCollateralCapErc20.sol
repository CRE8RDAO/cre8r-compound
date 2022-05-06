pragma solidity ^0.5.16;

import "./ApeToken.sol";
import "./ERC3156FlashLenderInterface.sol";
import "./ERC3156FlashBorrowerInterface.sol";

/**
 * @title ApeFinance's ApeCollateralCapErc20 Contract
 * @notice ApeTokens which wrap an EIP-20 underlying with collateral cap
 */
contract ApeCollateralCapErc20 is ApeToken, ApeCollateralCapErc20Interface {
    /**
     * @notice Initialize the new money market
     * @param underlying_ The address of the underlying asset
     * @param comptroller_ The address of the Comptroller
     * @param interestRateModel_ The address of the interest rate model
     * @param initialExchangeRateMantissa_ The initial exchange rate, scaled by 1e18
     * @param name_ ERC-20 name of this token
     * @param symbol_ ERC-20 symbol of this token
     * @param decimals_ ERC-20 decimal precision of this token
     */
    function initialize(
        address underlying_,
        ComptrollerInterface comptroller_,
        InterestRateModel interestRateModel_,
        uint256 initialExchangeRateMantissa_,
        string memory name_,
        string memory symbol_,
        uint8 decimals_
    ) public {
        // ApeToken initialize does the bulk of the work
        super.initialize(comptroller_, interestRateModel_, initialExchangeRateMantissa_, name_, symbol_, decimals_);

        // Set underlying, version and sanity check it
        underlying = underlying_;
        version = Version.COLLATERALCAP;
        EIP20Interface(underlying).totalSupply();
    }

    /*** User Interface ***/

    /**
     * @notice Sender supplies assets into the market and receives apeTokens in exchange
     * @dev Accrues interest whether or not the operation succeeds, unless reverted
     * @param minter the minter
     * @param mintAmount The amount of the underlying asset to supply
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function mint(address minter, uint256 mintAmount) external returns (uint256) {
        (uint256 err, ) = mintInternal(minter, mintAmount, false);
        require(err == 0, "mint failed");
    }

    /**
     * @notice Sender redeems apeTokens in exchange for the underlying asset
     * @dev Accrues interest whether or not the operation succeeds, unless reverted
     * @param redeemer The redeemer
     * @param redeemTokens The number of apeTokens to redeem into underlying
     * @param redeemAmount The amount of underlying to receive from redeeming apeTokens
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function redeem(
        address payable redeemer,
        uint256 redeemTokens,
        uint256 redeemAmount
    ) external returns (uint256) {
        require(redeemInternal(redeemer, redeemTokens, redeemAmount, false) == 0, "redeem failed");
    }

    /**
     * @notice Sender borrows assets from the protocol to their own address
     * @param borrower The borrower
     * @param borrowAmount The amount of the underlying asset to borrow
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function borrow(address payable borrower, uint256 borrowAmount) external returns (uint256) {
        require(borrowInternal(borrower, borrowAmount, false) == 0, "borrow failed");
    }

    /**
     * @notice Sender repays a borrow belonging to borrower
     * @param borrower the account with the debt being payed off
     * @param repayAmount The amount to repay
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function repayBorrow(address borrower, uint256 repayAmount) external returns (uint256) {
        (uint256 err, ) = repayBorrowInternal(borrower, repayAmount, false);
        require(err == 0, "repay failed");
    }

    /**
     * @notice The sender liquidates the borrowers collateral.
     *  The collateral seized is transferred to the liquidator.
     * @param borrower The borrower of this apeToken to be liquidated
     * @param repayAmount The amount of the underlying borrowed asset to repay
     * @param apeTokenCollateral The market in which to seize collateral from the borrower
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function liquidateBorrow(
        address borrower,
        uint256 repayAmount,
        ApeTokenInterface apeTokenCollateral
    ) external returns (uint256) {
        (uint256 err, ) = liquidateBorrowInternal(borrower, repayAmount, apeTokenCollateral, false);
        require(err == 0, "liquidate borrow failed");
    }

    /**
     * @notice The sender adds to reserves.
     * @param addAmount The amount fo underlying token to add as reserves
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function _addReserves(uint256 addAmount) external returns (uint256) {
        require(_addReservesInternal(addAmount, false) == 0, "add reserves failed");
    }

    /**
     * @notice Set the given collateral cap for the market.
     * @param newCollateralCap New collateral cap for this market. A value of 0 corresponds to no cap.
     */
    function _setCollateralCap(uint256 newCollateralCap) external {
        require(msg.sender == admin, "admin only");

        collateralCap = newCollateralCap;
        emit NewCollateralCap(address(this), newCollateralCap);
    }

    /**
     * @notice Absorb excess cash into reserves.
     */
    function gulp() external nonReentrant {
        uint256 cashOnChain = getCashOnChain();
        uint256 cashPrior = getCashPrior();

        uint256 excessCash = sub_(cashOnChain, cashPrior);
        totalReserves = add_(totalReserves, excessCash);
        internalCash = cashOnChain;
    }

    /**
     * @dev The amount of currency available to be lent.
     * @param token The loan currency.
     * @return The amount of `token` that can be borrowed.
     */
    function maxFlashLoan(address token) external view returns (uint256) {
        uint256 amount = 0;
        if (
            token == underlying &&
            ComptrollerInterfaceExtension(address(comptroller)).flashloanAllowed(address(this), address(0), amount, "")
        ) {
            amount = getCashPrior();
        }
        return amount;
    }

    /**
     * @notice Get the flash loan fees
     * @param token The loan currency. Must match the address of this contract's underlying.
     * @param amount amount of token to borrow
     * @return The amount of `token` to be charged for the loan, on top of the returned principal.
     */
    function flashFee(address token, uint256 amount) external view returns (uint256) {
        require(token == underlying, "unsupported currency");
        require(
            ComptrollerInterfaceExtension(address(comptroller)).flashloanAllowed(address(this), address(0), amount, ""),
            "flashloan is paused"
        );
        return _flashFee(token, amount);
    }

    /**
     * @notice Flash loan funds to a given account.
     * @param receiver The receiver address for the funds
     * @param token The loan currency. Must match the address of this contract's underlying.
     * @param amount The amount of the funds to be loaned
     * @param data The other data
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function flashLoan(
        ERC3156FlashBorrowerInterface receiver,
        address token,
        uint256 amount,
        bytes calldata data
    ) external nonReentrant returns (bool) {
        require(amount > 0, "invalid flashloan amount");
        require(token == underlying, "unsupported currency");
        accrueInterest();
        require(
            ComptrollerInterfaceExtension(address(comptroller)).flashloanAllowed(
                address(this),
                address(receiver),
                amount,
                data
            ),
            "flashloan is paused"
        );
        uint256 cashOnChainBefore = getCashOnChain();
        uint256 cashBefore = getCashPrior();
        require(cashBefore >= amount, "insufficient cash");

        // 1. calculate fee, 1 bips = 1/10000
        uint256 totalFee = _flashFee(token, amount);

        // 2. transfer fund to receiver
        doTransferOut(address(uint160(address(receiver))), amount, false);

        // 3. update totalBorrows
        totalBorrows = add_(totalBorrows, amount);

        // 4. execute receiver's callback function
        require(
            receiver.onFlashLoan(msg.sender, underlying, amount, totalFee, data) ==
                keccak256("ERC3156FlashBorrowerInterface.onFlashLoan"),
            "IERC3156: Callback failed"
        );

        // 5. take amount + fee from receiver, then check balance
        uint256 repaymentAmount = add_(amount, totalFee);
        doTransferIn(address(receiver), repaymentAmount, false);

        uint256 cashOnChainAfter = getCashOnChain();

        require(cashOnChainAfter == add_(cashOnChainBefore, totalFee), "inconsistent balance");

        // 6. update reserves and internal cash and totalBorrows
        uint256 reservesFee = mul_ScalarTruncate(Exp({mantissa: reserveFactorMantissa}), totalFee);
        totalReserves = add_(totalReserves, reservesFee);
        internalCash = add_(cashBefore, totalFee);
        totalBorrows = sub_(totalBorrows, amount);

        emit Flashloan(address(receiver), amount, totalFee, reservesFee);
        return true;
    }

    /**
     * @notice Get the flash loan fees
     * @param token The loan currency. Must match the address of this contract's underlying.
     * @param amount amount of token to borrow
     * @return The amount of `token` to be charged for the loan, on top of the returned principal.
     */
    function _flashFee(address token, uint256 amount) internal view returns (uint256) {
        return div_(mul_(amount, flashFeeBips), 10000);
    }

    /**
     * @notice Register account collateral tokens if there is space.
     * @param account The account to register
     * @dev This function could only be called by comptroller.
     * @return The actual registered amount of collateral
     */
    function registerCollateral(address account) external returns (uint256) {
        require(msg.sender == address(comptroller), "comptroller only");

        uint256 amount = sub_(accountTokens[account], accountCollateralTokens[account]);
        return increaseUserCollateralInternal(account, amount);
    }

    /**
     * @notice Unregister account collateral tokens if the account still has enough collateral.
     * @dev This function could only be called by comptroller.
     * @param account The account to unregister
     */
    function unregisterCollateral(address account) external {
        require(msg.sender == address(comptroller), "comptroller only");
        require(comptroller.redeemAllowed(address(this), account, accountCollateralTokens[account]) == 0, "rejected");

        decreaseUserCollateralInternal(account, accountCollateralTokens[account]);
    }

    /*** Safe Token ***/

    /**
     * @notice Gets internal balance of this contract in terms of the underlying.
     *  It excludes balance from direct transfer.
     * @dev This excludes the value of the current message, if any
     * @return The quantity of underlying tokens owned by this contract
     */
    function getCashPrior() internal view returns (uint256) {
        return internalCash;
    }

    /**
     * @notice Gets total balance of this contract in terms of the underlying
     * @dev This excludes the value of the current message, if any
     * @return The quantity of underlying tokens owned by this contract
     */
    function getCashOnChain() internal view returns (uint256) {
        EIP20Interface token = EIP20Interface(underlying);
        return token.balanceOf(address(this));
    }

    /**
     * @dev Similar to EIP20 transfer, except it handles a False result from `transferFrom` and reverts in that case.
     *      This will revert due to insufficient balance or insufficient allowance.
     *      This function returns the actual amount received,
     *      which may be less than `amount` if there is a fee attached to the transfer.
     *
     *      Note: This wrapper safely handles non-standard ERC-20 tokens that do not return a value.
     *            See here: https://medium.com/coinmonks/missing-return-value-bug-at-least-130-tokens-affected-d67bf08521ca
     */
    function doTransferIn(
        address from,
        uint256 amount,
        bool isNative
    ) internal returns (uint256) {
        isNative; // unused

        EIP20NonStandardInterface token = EIP20NonStandardInterface(underlying);
        uint256 balanceBefore = EIP20Interface(underlying).balanceOf(address(this));
        token.transferFrom(from, address(this), amount);

        bool success;
        assembly {
            switch returndatasize()
            case 0 {
                // This is a non-standard ERC-20
                success := not(0) // set success to true
            }
            case 32 {
                // This is a compliant ERC-20
                returndatacopy(0, 0, 32)
                success := mload(0) // Set `success = returndata` of external call
            }
            default {
                // This is an excessively non-compliant ERC-20, revert.
                revert(0, 0)
            }
        }
        require(success, "transfer failed");

        // Calculate the amount that was *actually* transferred
        uint256 balanceAfter = EIP20Interface(underlying).balanceOf(address(this));
        uint256 transferredIn = sub_(balanceAfter, balanceBefore);
        internalCash = add_(internalCash, transferredIn);
        return transferredIn;
    }

    /**
     * @dev Similar to EIP20 transfer, except it handles a False success from `transfer` and returns an explanatory
     *      error code rather than reverting. If caller has not called checked protocol's balance, this may revert due to
     *      insufficient cash held in this contract. If caller has checked protocol's balance prior to this call, and verified
     *      it is >= amount, this should not revert in normal conditions.
     *
     *      Note: This wrapper safely handles non-standard ERC-20 tokens that do not return a value.
     *            See here: https://medium.com/coinmonks/missing-return-value-bug-at-least-130-tokens-affected-d67bf08521ca
     */
    function doTransferOut(
        address payable to,
        uint256 amount,
        bool isNative
    ) internal {
        isNative; // unused

        EIP20NonStandardInterface token = EIP20NonStandardInterface(underlying);
        token.transfer(to, amount);

        bool success;
        assembly {
            switch returndatasize()
            case 0 {
                // This is a non-standard ERC-20
                success := not(0) // set success to true
            }
            case 32 {
                // This is a complaint ERC-20
                returndatacopy(0, 0, 32)
                success := mload(0) // Set `success = returndata` of external call
            }
            default {
                // This is an excessively non-compliant ERC-20, revert.
                revert(0, 0)
            }
        }
        require(success, "transfer failed");
        internalCash = sub_(internalCash, amount);
    }

    /**
     * @notice Get the account's apeToken collateral balances
     * @param account The address of the account
     */
    function getApeTokenBalanceInternal(address account) internal view returns (uint256) {
        return accountCollateralTokens[account];
    }

    /**
     * @notice Increase user's collateral. Increase as much as we can.
     * @param account The address of the account
     * @param amount The amount of collateral user wants to increase
     * @return The actual increased amount of collateral
     */
    function increaseUserCollateralInternal(address account, uint256 amount) internal returns (uint256) {
        uint256 totalCollateralTokensNew = add_(totalCollateralTokens, amount);
        if (collateralCap == 0 || (collateralCap != 0 && totalCollateralTokensNew <= collateralCap)) {
            // 1. If collateral cap is not set,
            // 2. If collateral cap is set but has enough space for this user,
            // give all the user needs.
            totalCollateralTokens = totalCollateralTokensNew;
            accountCollateralTokens[account] = add_(accountCollateralTokens[account], amount);

            emit UserCollateralChanged(account, accountCollateralTokens[account]);
            return amount;
        } else if (collateralCap > totalCollateralTokens) {
            // If the collateral cap is set but the remaining cap is not enough for this user,
            // give the remaining parts to the user.
            uint256 gap = sub_(collateralCap, totalCollateralTokens);
            totalCollateralTokens = add_(totalCollateralTokens, gap);
            accountCollateralTokens[account] = add_(accountCollateralTokens[account], gap);

            emit UserCollateralChanged(account, accountCollateralTokens[account]);
            return gap;
        }
        return 0;
    }

    /**
     * @notice Decrease user's collateral. Reject if the amount can't be fully decrease.
     * @param account The address of the account
     * @param amount The amount of collateral user wants to decrease
     */
    function decreaseUserCollateralInternal(address account, uint256 amount) internal {
        /*
         * Return if amount is zero.
         * Put behind `redeemAllowed` for accuring potential COMP rewards.
         */
        if (amount == 0) {
            return;
        }

        totalCollateralTokens = sub_(totalCollateralTokens, amount);
        accountCollateralTokens[account] = sub_(accountCollateralTokens[account], amount);

        emit UserCollateralChanged(account, accountCollateralTokens[account]);
    }

    struct MintLocalVars {
        uint256 exchangeRateMantissa;
        uint256 mintTokens;
        uint256 actualMintAmount;
    }

    /**
     * @notice User supplies assets into the market and receives apeTokens in exchange
     * @dev Assumes interest has already been accrued up to the current block
     * @param payer the account paying for the mint
     * @param minter The address of the account which is supplying the assets
     * @param mintAmount The amount of the underlying asset to supply
     * @param isNative The amount is in native or not
     * @return (uint, uint) An error code (0=success, otherwise a failure, see ErrorReporter.sol), and the actual mint amount.
     */
    function mintFresh(
        address payer,
        address minter,
        uint256 mintAmount,
        bool isNative
    ) internal returns (uint256, uint256) {
        /* Fail if mint not allowed */
        require(comptroller.mintAllowed(address(this), payer, minter, mintAmount) == 0, "rejected");

        /*
         * Return if mintAmount is zero.
         * Put behind `mintAllowed` for accuring potential COMP rewards.
         */
        if (mintAmount == 0) {
            return (uint256(Error.NO_ERROR), 0);
        }

        /* Verify market's block number equals current block number */
        require(accrualBlockNumber == getBlockNumber(), "market is stale");

        MintLocalVars memory vars;

        vars.exchangeRateMantissa = exchangeRateStoredInternal();

        /////////////////////////
        // EFFECTS & INTERACTIONS
        // (No safe failures beyond this point)

        /*
         *  We call `doTransferIn` for the payer and the mintAmount.
         *  Note: The apeToken must handle variations between ERC-20 and ETH underlying.
         *  `doTransferIn` reverts if anything goes wrong, since we can't be sure if
         *  side-effects occurred. The function returns the amount actually transferred,
         *  in case of a fee. On success, the apeToken holds an additional `actualMintAmount`
         *  of cash.
         */
        vars.actualMintAmount = doTransferIn(payer, mintAmount, isNative);

        /*
         * We get the current exchange rate and calculate the number of apeTokens to be minted:
         *  mintTokens = actualMintAmount / exchangeRate
         */
        vars.mintTokens = div_ScalarByExpTruncate(vars.actualMintAmount, Exp({mantissa: vars.exchangeRateMantissa}));

        /*
         * We calculate the new total supply of apeTokens and minter token balance, checking for overflow:
         *  totalSupply = totalSupply + mintTokens
         *  accountTokens[minter] = accountTokens[minter] + mintTokens
         */
        totalSupply = add_(totalSupply, vars.mintTokens);
        accountTokens[minter] = add_(accountTokens[minter], vars.mintTokens);

        /*
         * We only allocate collateral tokens if the minter has entered the market.
         */
        if (ComptrollerInterfaceExtension(address(comptroller)).checkMembership(minter, ApeToken(this))) {
            increaseUserCollateralInternal(minter, vars.mintTokens);
        }

        /* We emit a Mint event */
        emit Mint(payer, minter, vars.actualMintAmount, vars.mintTokens);

        /* We call the defense hook */
        comptroller.mintVerify(address(this), payer, minter, vars.actualMintAmount, vars.mintTokens);

        return (uint256(Error.NO_ERROR), vars.actualMintAmount);
    }

    struct RedeemLocalVars {
        uint256 exchangeRateMantissa;
        uint256 redeemTokens;
        uint256 redeemAmount;
    }

    /**
     * @notice User redeems apeTokens in exchange for the underlying asset
     * @dev Assumes interest has already been accrued up to the current block. Only one of redeemTokensIn or redeemAmountIn may be non-zero and it would do nothing if both are zero.
     * @param redeemer The address of the account which is redeeming the tokens
     * @param redeemTokensIn The number of apeTokens to redeem into underlying
     * @param redeemAmountIn The number of underlying tokens to receive from redeeming apeTokens
     * @param isNative The amount is in native or not
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function redeemFresh(
        address payable redeemer,
        uint256 redeemTokensIn,
        uint256 redeemAmountIn,
        bool isNative
    ) internal returns (uint256) {
        require(redeemTokensIn == 0 || redeemAmountIn == 0, "bad input");

        RedeemLocalVars memory vars;

        /* exchangeRate = invoke Exchange Rate Stored() */
        vars.exchangeRateMantissa = exchangeRateStoredInternal();

        /* If redeemTokensIn > 0: */
        if (redeemTokensIn > 0) {
            /*
             * We calculate the exchange rate and the amount of underlying to be redeemed:
             *  redeemTokens = redeemTokensIn
             *  redeemAmount = redeemTokensIn x exchangeRateCurrent
             */
            vars.redeemTokens = redeemTokensIn;
            vars.redeemAmount = mul_ScalarTruncate(Exp({mantissa: vars.exchangeRateMantissa}), redeemTokensIn);
        } else {
            /*
             * We get the current exchange rate and calculate the amount to be redeemed:
             *  redeemTokens = redeemAmountIn / exchangeRate
             *  redeemAmount = redeemAmountIn
             */
            vars.redeemTokens = div_ScalarByExpTruncate(redeemAmountIn, Exp({mantissa: vars.exchangeRateMantissa}));
            vars.redeemAmount = redeemAmountIn;
        }

        /**
         * For every user, accountTokens must be greater than or equal to accountCollateralTokens.
         * The buffer between the two values will be redeemed first.
         * bufferTokens = accountTokens[redeemer] - accountCollateralTokens[redeemer]
         * collateralTokens = redeemTokens - bufferTokens
         */
        uint256 bufferTokens = sub_(accountTokens[redeemer], accountCollateralTokens[redeemer]);
        uint256 collateralTokens = 0;
        if (vars.redeemTokens > bufferTokens) {
            collateralTokens = vars.redeemTokens - bufferTokens;
        }

        /* redeemAllowed might check more than user's liquidity. */
        require(comptroller.redeemAllowed(address(this), redeemer, collateralTokens) == 0, "rejected");

        /* Verify market's block number equals current block number */
        require(accrualBlockNumber == getBlockNumber(), "market is stale");

        /* Reverts if protocol has insufficient cash */
        require(getCashPrior() >= vars.redeemAmount, "insufficient cash");

        /////////////////////////
        // EFFECTS & INTERACTIONS
        // (No safe failures beyond this point)

        /*
         * We calculate the new total supply and redeemer balance, checking for underflow:
         *  totalSupplyNew = totalSupply - redeemTokens
         *  accountTokensNew = accountTokens[redeemer] - redeemTokens
         */
        totalSupply = sub_(totalSupply, vars.redeemTokens);
        accountTokens[redeemer] = sub_(accountTokens[redeemer], vars.redeemTokens);

        /*
         * We only deallocate collateral tokens if the redeemer needs to redeem them.
         */
        decreaseUserCollateralInternal(redeemer, collateralTokens);

        /*
         * We invoke doTransferOut for the redeemer and the redeemAmount.
         *  Note: The apeToken must handle variations between ERC-20 and ETH underlying.
         *  On success, the apeToken has redeemAmount less of cash.
         *  doTransferOut reverts if anything goes wrong, since we can't be sure if side effects occurred.
         */
        doTransferOut(redeemer, vars.redeemAmount, isNative);

        /* We emit a Redeem event */
        emit Redeem(redeemer, vars.redeemAmount, vars.redeemTokens);

        /* We call the defense hook */
        comptroller.redeemVerify(address(this), redeemer, vars.redeemAmount, vars.redeemTokens);

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice Transfers collateral tokens (this market) to the liquidator.
     * @dev Called only during an in-kind liquidation, or by liquidateBorrow during the liquidation of another ApeToken.
     *  Its absolutely critical to use msg.sender as the seizer apeToken and not a parameter.
     * @param seizerToken The contract seizing the collateral (i.e. borrowed apeToken)
     * @param liquidator The account receiving seized collateral
     * @param borrower The account having collateral seized
     * @param seizeTokens The number of apeTokens to seize
     * @param feeTokens The number of apeTokens as fee
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function seizeInternal(
        address seizerToken,
        address liquidator,
        address borrower,
        uint256 seizeTokens,
        uint256 feeTokens
    ) internal returns (uint256) {
        /* Fail if seize not allowed */
        require(
            comptroller.seizeAllowed(address(this), seizerToken, liquidator, borrower, seizeTokens) == 0,
            "rejected"
        );

        /*
         * Return if seizeTokens is zero.
         * Put behind `seizeAllowed` for accuring potential COMP rewards.
         */
        if (seizeTokens == 0) {
            return uint256(Error.NO_ERROR);
        }

        /* Fail if borrower = liquidator */
        require(borrower != liquidator, "invalid account pair");

        /* We take half of the liquidation incentive as fee */
        uint256 bonusTokens = sub_(seizeTokens, feeTokens);

        /**
         * For every user, accountTokens must be greater than or equal to accountCollateralTokens.
         * The buffer between the two values will be seized first.
         * bufferTokens = accountTokens[borrower] - accountCollateralTokens[borrower]
         * collateralTokens = seizeTokens - bufferTokens
         */
        uint256 bufferTokens = sub_(accountTokens[borrower], accountCollateralTokens[borrower]);
        uint256 collateralTokens = 0;
        if (seizeTokens > bufferTokens) {
            collateralTokens = seizeTokens - bufferTokens;
        }

        /*
         * We calculate the new borrower and liquidator token balances and token collateral balances, failing on underflow/overflow:
         *  accountTokens[borrower] = accountTokens[borrower] - seizeTokens
         *  accountTokens[liquidator] = accountTokens[liquidator] + bonusTokens
         *  accountTokens[admin] = accountTokens[admin] + feeTokens
         *  accountCollateralTokens[borrower] = accountCollateralTokens[borrower] - collateralTokens
         *  accountCollateralTokens[liquidator] = accountCollateralTokens[liquidator] + min(collateralTokens, bonusTokens)
         *  accountCollateralTokens[admin] = accountCollateralTokens[admin] + max(collateralTokens - bonusTokens, 0)
         */
        accountTokens[borrower] = sub_(accountTokens[borrower], seizeTokens);
        accountTokens[liquidator] = add_(accountTokens[liquidator], bonusTokens);
        accountTokens[admin] = add_(accountTokens[admin], feeTokens);
        if (collateralTokens > 0) {
            accountCollateralTokens[borrower] = sub_(accountCollateralTokens[borrower], collateralTokens);
            if (collateralTokens <= bonusTokens) {
                // All collateral tokens go to liquidator.
                accountCollateralTokens[liquidator] = add_(accountCollateralTokens[liquidator], collateralTokens);
            } else {
                accountCollateralTokens[liquidator] = add_(accountCollateralTokens[liquidator], bonusTokens);
                accountCollateralTokens[admin] = add_(accountCollateralTokens[admin], collateralTokens - bonusTokens);
                emit UserCollateralChanged(admin, accountCollateralTokens[admin]);
            }

            /* Emit UserCollateralChanged events */
            emit UserCollateralChanged(borrower, accountCollateralTokens[borrower]);
            emit UserCollateralChanged(liquidator, accountCollateralTokens[liquidator]);
        }

        /* We call the defense hook */
        comptroller.seizeVerify(address(this), seizerToken, liquidator, borrower, seizeTokens);

        return uint256(Error.NO_ERROR);
    }
}
