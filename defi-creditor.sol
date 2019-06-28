/*

  Copyright 2017 Dharma Labs Inc.

  Licensed under the Apache License, Version 2.0 (the "License");
  you may not use this file except in compliance with the License.
  You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

  Unless required by applicable law or agreed to in writing, software
  distributed under the License is distributed on an "AS IS" BASIS,
  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
  See the License for the specific language governing permissions and
  limitations under the License.

*/

pragma solidity ^0.5.1;
import "./ERC201.sol";
import "https://github.com/OpenZeppelin/openzeppelin-solidity/contracts/lifecycle/Pausable.sol";
import "https://github.com/OpenZeppelin/openzeppelin-solidity/contracts/math/SafeMath.sol";
import "https://github.com/OpenZeppelin/openzeppelin-solidity/contracts/token/ERC20/ERC20.sol";


/**
 * The DebtKernel is the hub of all business logic governing how and when
 * debt orders can be filled and cancelled.  All logic that determines
 * whether a debt order is valid & consensual is contained herein,
 * as well as the mechanisms that transfer fees to keepers and
 * principal payments to debtors.
 *
 * Author: Nadav Hollander -- Github: nadavhollanderm 
 */
contract Defi is Pausable {
    using SafeMath for uint;


    // solhint-disable-next-line var-name-mixedcase
    address public TOKEN_ADDRESS;
    bytes32 constant public NULL_ISSUANCE_HASH = bytes32(0);

    /* NOTE(kayvon): Currently, the `view` keyword does not actually enforce the
    static nature of the method; this will change in the future, but for now, in
    order to prevent reentrancy we'll need to arbitrarily set an upper bound on
    the gas limit allotted for certain method calls. */
    uint16 constant public EXTERNAL_QUERY_GAS_LIMIT = 8000;

    mapping(uint => Issuance) public agreementToIssuance;
    uint public latest_agreemendId;

    event LogIssuancePublished(
        uint indexed _agreementId,
        address creditor,
        uint debtNum,
        uint interestRate,
        uint debtPeriod
    );
    
    event LogIssuanceFilled(
        uint indexed _agreementId,
        address creditor,
        address debtor,
        uint debtNum,
        uint interestRate,
        uint debtPeriod,
        uint collateralNum
    );
    
    event LogIssuanceRepaid(
        uint indexed _agreementId,
        address creditor,
        address debtor,
        uint debtNum,
        uint interestRate,
        uint debtPeriod,
        uint collateralNum
    );


    struct Issuance {
        address creditor;
        address debtor;
        uint debtNum;
        uint interestRate;
        uint debtPeriod;
        uint collateralNum;
        bool repaid;
        uint agreementId;
    }


    constructor(address tokenAddress)
        public
    {
        TOKEN_ADDRESS = tokenAddress;
    }

    ////////////////////////
    // EXTERNAL FUNCTIONS //
    ////////////////////////

    /**
     * Fills a given debt order if it is valid and consensual.
     */
    function publishCreditIssuance(
        uint debtNum,
        uint interestRate,
        uint debtPeriod
    )     
        public
        whenNotPaused
        returns (uint _agreementId)
    {
        Issuance memory issuance = getIssuance(msg.sender, debtNum, interestRate, debtPeriod);

        // Assert order's validity & consensuality
        if (!assertExternalBalanceAndAllowanceInvariants(msg.sender, debtNum)) {
            return 0;
        }

        agreementToIssuance[issuance.agreementId] = issuance;


        emit LogIssuancePublished(
            issuance.agreementId,
            msg.sender,
            debtNum,
            interestRate,
            debtPeriod
        );
        
        return issuance.agreementId;
    }


 /**
     * Fills a given debt order if it is valid and consensual.
     */
    function fillCreditIssuance(
        uint agreementId,
        uint collateralNum
    )     
        public
        payable
        whenNotPaused
        returns (uint _agreementId)
    {
        require (msg.value == collateralNum);
        
        Issuance storage issuance = agreementToIssuance[agreementId];
        
        require (issuance.creditor != address(0));

        issuance.debtor = msg.sender;
        issuance.collateralNum = collateralNum;
        
        // Transfer principal to debtor
        if (issuance.debtNum > 0) {
            require(transferTokensFrom(
                TOKEN_ADDRESS,
                issuance.creditor,
                issuance.debtor,
                issuance.debtNum
            ));
        }


        emit LogIssuanceFilled(
            issuance.agreementId,
            issuance.creditor,
            issuance.debtor,
            issuance.debtNum,
            issuance.interestRate,
            issuance.debtPeriod,
            issuance.collateralNum
        );

        return issuance.agreementId;
    }
    
    /**
     * Fills a given debt order if it is valid and consensual.
     */
    function repayCreditIssuance(
        uint agreementId
    )     
        public
        whenNotPaused
        returns (uint _agreementId)
    {
        
        Issuance storage issuance = agreementToIssuance[agreementId];
        
        require(msg.sender == issuance.debtor);
        require(!issuance.repaid);
        
        uint totalToken = calculateTotalPrincipalPlusInterest(issuance);

        
        if (!assertExternalBalanceAndAllowanceInvariants(issuance.debtor, totalToken)) {
            return 0;
        }
        // Transfer principal to debtor
        if (issuance.debtNum > 0) {
            require(transferTokensFrom(
                TOKEN_ADDRESS,
                issuance.debtor,
                address(this),
                totalToken
            ));
        }
        
        msg.sender.transfer(issuance.collateralNum);

        issuance.repaid = true;

        emit LogIssuanceRepaid(
            issuance.agreementId,
            issuance.creditor,
            issuance.debtor,
            issuance.debtNum,
            issuance.interestRate,
            issuance.debtPeriod,
            issuance.collateralNum
        );


        return issuance.agreementId;
    }
    

    ////////////////////////
    // INTERNAL FUNCTIONS //
    ////////////////////////


    /**
     * Assert that the creditor has a sufficient token balance and has
     * granted the token transfer proxy contract sufficient allowance to suffice for the principal
     * and creditor fee.
     */
    function assertExternalBalanceAndAllowanceInvariants(
        address creditor,
        uint debtNum 
    )
        internal
        returns (bool _isBalanceAndAllowanceSufficient) 
    {

        if (getBalance(TOKEN_ADDRESS, creditor) < debtNum) {
            //LogError(uint8(Errors.CREDITOR_BALANCE_OR_ALLOWANCE_INSUFFICIENT));
            return false;
        }

        return true;
    }

    /**
     * Helper function transfers a specified amount of tokens between two parties
     * using the token transfer proxy contract.
     */
    function transferTokensFrom(
        address token,
        address from,
        address to,
        uint amount
    )
        internal
        returns (bool success)
    {
        return QHToken(token).transferFrom(from, to, amount);
    }

    /**
     * Helper function that constructs a hashed issuance structs from the given
     * parameters.
     */
    function getIssuance(
        address creditor,
        uint    debtNum,
        uint    interestRate,
        uint    debtPeriod
    )
        internal
        returns (Issuance memory _issuance)
    {
        Issuance memory issuance = Issuance({
            creditor: creditor,
            debtor: address(0),
            debtNum: debtNum,
            interestRate: interestRate,
            debtPeriod: debtPeriod,
            collateralNum: 0,
            repaid: false,
            agreementId: latest_agreemendId++
        });

        return issuance;
    }

   
    /**
     * Helper function for querying an address' balance on a given token.
     */
    function getBalance(
        address token,
        address owner
    )
        internal
        returns (uint _balance)
    {
        // Limit gas to prevent reentrancy.
        return ERC20(token).balanceOf.gas(EXTERNAL_QUERY_GAS_LIMIT)(owner);
    }

    
    function calculateTotalPrincipalPlusInterest(
        Issuance memory _issuance
    )
        internal
        returns (uint _principalPlusInterest)
    {
        // Since we represent decimal interest rates using their
        // scaled-up, fixed point representation, we have to
        // downscale the result of the interest payment computation
        // by the multiplier scaling factor we choose for interest rates.
        uint totalInterest = _issuance.debtNum
            .mul(_issuance.interestRate)
            .div(100);

        return _issuance.debtNum.add(totalInterest);
    }
}
