/*

  Copyright 2019 Guo Qinghua.

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
 * The Defi is the hub of all business logic governing how and when
 * debt orders can be filled and cancelled.  All logic that determines
 * whether a debt order is valid & consensual is contained herein,
 * as well as the mechanisms that transfer fees to keepers and
 * principal payments to debtors.
 *
 * Author: Guo Qinghua
 */
contract Defi is Pausable {
    using SafeMath for uint;


    address public TOKEN_ADDRESS;

    mapping(uint => DebtOrder) public orderIdToDebtOrder;
    uint public latest_orderId;

    event LogDebtOrderPublished(
        uint indexed orderId,
        address debtor,
        uint debtNum,
        uint interestRate,
        uint debtPeriod,
        uint collateralNum
    );
    
    event LogDebtOrderFilled(
        uint indexed orderId,        
        address debtor,
        address creditor,
        uint debtNum,
        uint interestRate,
        uint debtPeriod,
        uint collateralNum
    );
    
    event LogDebtOrderRepaid(
        uint indexed orderId,
        address debtor,
        address creditor,
        uint debtNum,
        uint interestRate,
        uint debtPeriod,
        uint collateralNum
    );


    struct DebtOrder {
        address debtor;
        address creditor;
        uint debtNum;
        uint interestRate;
        uint debtPeriod;
        uint collateralNum;
        bool repaid;
        uint orderId;
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
     * Publishs a debt order by debtor.
     */
    function publishDebtOrder(
        uint debtNum,
        uint interestRate,
        uint debtPeriod,
        uint collateralNum
    )     
        public
        whenNotPaused
        returns (uint orderId)
    {
        require (msg.value == collateralNum);
        
        DebtOrder memory order = getDebtOrder(msg.sender, debtNum, interestRate, debtPeriod, collateralNum);

        orderIdToDebtOrder[order.orderId] = order;


        emit LogDebtOrderPublished(
            order.orderId,
            msg.sender,
            debtNum,
            interestRate,
            debtPeriod,
            collateralNum
        );
        
        return order.orderId;
    }


 /**
     * Fills a given debt order if it is valid and consensual by creditor.
     */
    function fillDebtOrder(
        uint orderId
    )     
        public
        payable
        whenNotPaused
        returns (uint _orderId)
    {
        
        DebtOrder storage order = orderIdToDebtOrder[orderId];
        
        require (order.debtor != address(0));
        require (order.creditor == address(0));
        
        // Assert order's validity & consensuality
        if (!assertExternalBalanceAndAllowanceInvariants(msg.sender, order.debtNum)) {
           return 0;
        }

        order.creditor = msg.sender;
        
        // Transfer principal to debtor
        if (order.debtNum > 0) {
            require(transferTokensFrom(
                TOKEN_ADDRESS,
                order.creditor,
                order.debtor,
                order.debtNum
            ));
        }


        emit LogDebtOrderFilled(
            order.orderId,
            order.debtor,
            order.creditor,
            order.debtNum,
            order.interestRate,
            order.debtPeriod,
            order.collateralNum
        );

        return order.orderId;
    }
    
    /**
     * Repays a given debt order if it is valid and consensual.
     */
    function repayDebtOrder(
        uint orderId
    )     
        public
        whenNotPaused
        returns (uint _orderId)
    {
        
        DebtOrder storage order = orderIdToDebtOrder[orderId];
        
        require(msg.sender == order.debtor);
        require(!order.repaid);
        
        uint totalToken = calculateTotalPrincipalPlusInterest(order);

        
        if (!assertExternalBalanceAndAllowanceInvariants(order.debtor, totalToken)) {
            return 0;
        }
        // Transfer principal to debtor
        if (order.debtNum > 0) {
            require(transferTokensFrom(
                TOKEN_ADDRESS,
                order.debtor,
                order.creditor,
                totalToken
            ));
        }
        
        msg.sender.transfer(order.collateralNum);

        order.repaid = true;

        emit LogDebtOrderRepaid(
            order.orderId,
            order.debtor,
            order.creditor,
            order.debtNum,
            order.interestRate,
            order.debtPeriod,
            order.collateralNum
        );


        return order.orderId;
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
    function getDebtOrder(
        address debtor,
        uint    debtNum,
        uint    interestRate,
        uint    debtPeriod,
        uint    collateralNum
    )
        internal
        returns (DebtOrder memory _debtOrder)
    {
        DebtOrder memory debtOrder = DebtOrder({
            debtor: debtor,
            creditor: address(0),
            debtNum: debtNum,
            interestRate: interestRate,
            debtPeriod: debtPeriod,
            collateralNum: collateralNum,
            repaid: false,
            orderId: latest_orderId++
        });

        return debtOrder;
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
        return ERC20(token).balanceOf(owner);
    }

    
    function calculateTotalPrincipalPlusInterest(
        DebtOrder memory _debtOrder
    )
        internal
        returns (uint _principalPlusInterest)
    {
        // Since we represent decimal interest rates using their
        // scaled-up, fixed point representation, we have to
        // downscale the result of the interest payment computation
        // by the multiplier scaling factor we choose for interest rates.
        uint totalInterest = _debtOrder.debtNum
            .mul(_debtOrder.interestRate)
            .div(100);

        return _debtOrder.debtNum.add(totalInterest);
    }
}
