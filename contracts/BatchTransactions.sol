// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";

/**
 * @title BatchTransactions
 * @dev A contract for executing multiple transactions in a single batch
 * @author Swift v2 Team
 */
contract BatchTransactions is ReentrancyGuard, Ownable {
    using Counters for Counters.Counter;

    // Events
    event BatchExecuted(
        uint256 indexed batchId,
        address indexed executor,
        uint256 transactionCount,
        uint256 totalGasUsed,
        uint256 timestamp,
        bool success
    );

    event TransactionExecuted(
        uint256 indexed batchId,
        uint256 indexed transactionIndex,
        address indexed target,
        bool success,
        bytes returnData
    );

    event BatchCreated(
        uint256 indexed batchId,
        address indexed creator,
        uint256 transactionCount,
        uint256 estimatedGas
    );

    event BatchCancelled(
        uint256 indexed batchId,
        address indexed creator
    );

    // Structs
    struct Transaction {
        address target;
        uint256 value;
        bytes data;
        uint256 gasLimit;
        bool isExecuted;
        bool success;
        bytes returnData;
    }

    struct Batch {
        uint256 id;
        address creator;
        Transaction[] transactions;
        uint256 createdAt;
        uint256 executedAt;
        bool isExecuted;
        bool isCancelled;
        uint256 totalGasUsed;
        uint256 estimatedGas;
    }

    struct GasOptimization {
        uint256 originalGas;
        uint256 optimizedGas;
        uint256 savings;
        uint256 savingsPercentage;
    }

    // State variables
    Counters.Counter private _batchIdCounter;
    
    mapping(uint256 => Batch) public batches;
    mapping(address => uint256[]) public userBatches;
    mapping(address => uint256) public userGasSavings;
    mapping(address => bool) public authorizedExecutors;
    
    // Constants
    uint256 public constant MAX_TRANSACTIONS_PER_BATCH = 100;
    uint256 public constant MAX_BATCH_VALUE = 10 ether;
    uint256 public constant BATCH_EXECUTION_FEE = 0.000003 ether; // ~$0.009 at $3000 ETH
    uint256 public constant GAS_LIMIT_MULTIPLIER = 120; // 20% buffer
    uint256 public constant BATCH_TIMEOUT = 1 hours;

    // Modifiers
    modifier validBatch(uint256 _batchId) {
        require(_batchId > 0 && _batchId <= _batchIdCounter.current(), "Invalid batch ID");
        _;
    }

    modifier batchNotExecuted(uint256 _batchId) {
        require(!batches[_batchId].isExecuted, "Batch already executed");
        require(!batches[_batchId].isCancelled, "Batch cancelled");
        _;
    }

    modifier onlyBatchCreator(uint256 _batchId) {
        require(batches[_batchId].creator == msg.sender, "Only batch creator can perform this action");
        _;
    }

    modifier onlyAuthorizedExecutor() {
        require(
            authorizedExecutors[msg.sender] || msg.sender == owner(),
            "Not authorized to execute batches"
        );
        _;
    }

    modifier validTransaction(Transaction memory _transaction) {
        require(_transaction.target != address(0), "Invalid target address");
        require(_transaction.gasLimit > 0, "Invalid gas limit");
        require(_transaction.gasLimit <= block.gaslimit, "Gas limit too high");
        _;
    }

    constructor() {
        _batchIdCounter.increment();
        authorizedExecutors[msg.sender] = true;
    }

    /**
     * @dev Create a new batch of transactions
     * @param _transactions Array of transactions to include in the batch
     * @return batchId ID of the created batch
     */
    function createBatch(Transaction[] memory _transactions) 
        external 
        payable 
        returns (uint256 batchId) 
    {
        require(_transactions.length > 0, "No transactions provided");
        require(_transactions.length <= MAX_TRANSACTIONS_PER_BATCH, "Too many transactions");
        require(msg.value >= BATCH_EXECUTION_FEE, "Insufficient execution fee");

        batchId = _batchIdCounter.current();
        _batchIdCounter.increment();

        Batch storage batch = batches[batchId];
        batch.id = batchId;
        batch.creator = msg.sender;
        batch.createdAt = block.timestamp;
        batch.isExecuted = false;
        batch.isCancelled = false;

        uint256 totalValue = 0;
        uint256 estimatedGas = 0;

        for (uint256 i = 0; i < _transactions.length; i++) {
            Transaction memory transaction = _transactions[i];
            require(transaction.target != address(0), "Invalid target address");
            require(transaction.gasLimit > 0, "Invalid gas limit");
            
            totalValue += transaction.value;
            estimatedGas += transaction.gasLimit;
            
            batch.transactions.push(transaction);
        }

        require(totalValue <= MAX_BATCH_VALUE, "Batch value too high");
        batch.estimatedGas = estimatedGas;

        userBatches[msg.sender].push(batchId);

        emit BatchCreated(batchId, msg.sender, _transactions.length, estimatedGas);
    }

    /**
     * @dev Execute a batch of transactions
     * @param _batchId ID of the batch to execute
     */
    function executeBatch(uint256 _batchId) 
        external 
        nonReentrant 
        validBatch(_batchId)
        batchNotExecuted(_batchId)
        onlyAuthorizedExecutor
    {
        Batch storage batch = batches[_batchId];
        require(block.timestamp <= batch.createdAt + BATCH_TIMEOUT, "Batch expired");

        uint256 gasStart = gasleft();
        uint256 successfulTransactions = 0;

        for (uint256 i = 0; i < batch.transactions.length; i++) {
            Transaction storage transaction = batch.transactions[i];
            
            if (transaction.isExecuted) {
                continue;
            }

            bool success = false;
            bytes memory returnData;

            try this.executeSingleTransaction(transaction) returns (bytes memory data) {
                success = true;
                returnData = data;
            } catch {
                success = false;
                returnData = "";
            }

            transaction.isExecuted = true;
            transaction.success = success;
            transaction.returnData = returnData;

            if (success) {
                successfulTransactions++;
            }

            emit TransactionExecuted(_batchId, i, transaction.target, success, returnData);
        }

        uint256 gasUsed = gasStart - gasleft();
        batch.totalGasUsed = gasUsed;
        batch.executedAt = block.timestamp;
        batch.isExecuted = true;

        // Calculate gas savings
        uint256 individualGasEstimate = batch.estimatedGas;
        uint256 actualGasUsed = gasUsed;
        uint256 gasSavings = individualGasEstimate > actualGasUsed ? 
            individualGasEstimate - actualGasUsed : 0;

        if (gasSavings > 0) {
            userGasSavings[batch.creator] += gasSavings;
        }

        emit BatchExecuted(
            _batchId,
            batch.creator,
            batch.transactions.length,
            gasUsed,
            block.timestamp,
            successfulTransactions == batch.transactions.length
        );
    }

    /**
     * @dev Execute a single transaction (internal function)
     * @param _transaction Transaction to execute
     * @return returnData Return data from the transaction
     */
    function executeSingleTransaction(Transaction memory _transaction) 
        external 
        returns (bytes memory returnData) 
    {
        require(msg.sender == address(this), "Only contract can call this function");
        
        (bool success, bytes memory data) = _transaction.target.call{
            value: _transaction.value,
            gas: _transaction.gasLimit
        }(_transaction.data);

        require(success, "Transaction execution failed");
        return data;
    }

    /**
     * @dev Cancel a batch (only creator can cancel)
     * @param _batchId ID of the batch to cancel
     */
    function cancelBatch(uint256 _batchId) 
        external 
        validBatch(_batchId)
        batchNotExecuted(_batchId)
        onlyBatchCreator(_batchId)
    {
        batches[_batchId].isCancelled = true;
        emit BatchCancelled(_batchId, msg.sender);
    }

    /**
     * @dev Add transaction to existing batch
     * @param _batchId ID of the batch
     * @param _transaction Transaction to add
     */
    function addTransactionToBatch(
        uint256 _batchId,
        Transaction memory _transaction
    ) 
        external 
        validBatch(_batchId)
        batchNotExecuted(_batchId)
        onlyBatchCreator(_batchId)
        validTransaction(_transaction)
    {
        Batch storage batch = batches[_batchId];
        require(batch.transactions.length < MAX_TRANSACTIONS_PER_BATCH, "Batch full");
        
        batch.transactions.push(_transaction);
        batch.estimatedGas += _transaction.gasLimit;
    }

    /**
     * @dev Remove transaction from batch
     * @param _batchId ID of the batch
     * @param _transactionIndex Index of transaction to remove
     */
    function removeTransactionFromBatch(
        uint256 _batchId,
        uint256 _transactionIndex
    ) 
        external 
        validBatch(_batchId)
        batchNotExecuted(_batchId)
        onlyBatchCreator(_batchId)
    {
        Batch storage batch = batches[_batchId];
        require(_transactionIndex < batch.transactions.length, "Invalid transaction index");
        
        Transaction storage transaction = batch.transactions[_transactionIndex];
        batch.estimatedGas -= transaction.gasLimit;
        
        // Remove transaction by swapping with last element
        batch.transactions[_transactionIndex] = batch.transactions[batch.transactions.length - 1];
        batch.transactions.pop();
    }

    /**
     * @dev Get batch details
     * @param _batchId ID of the batch
     */
    function getBatch(uint256 _batchId) 
        external 
        view 
        validBatch(_batchId)
        returns (
            uint256 id,
            address creator,
            uint256 transactionCount,
            uint256 createdAt,
            uint256 executedAt,
            bool isExecuted,
            bool isCancelled,
            uint256 totalGasUsed,
            uint256 estimatedGas
        )
    {
        Batch storage batch = batches[_batchId];
        return (
            batch.id,
            batch.creator,
            batch.transactions.length,
            batch.createdAt,
            batch.executedAt,
            batch.isExecuted,
            batch.isCancelled,
            batch.totalGasUsed,
            batch.estimatedGas
        );
    }

    /**
     * @dev Get transaction details
     * @param _batchId ID of the batch
     * @param _transactionIndex Index of the transaction
     */
    function getTransaction(uint256 _batchId, uint256 _transactionIndex) 
        external 
        view 
        validBatch(_batchId)
        returns (
            address target,
            uint256 value,
            bytes memory data,
            uint256 gasLimit,
            bool isExecuted,
            bool success,
            bytes memory returnData
        )
    {
        Batch storage batch = batches[_batchId];
        require(_transactionIndex < batch.transactions.length, "Invalid transaction index");
        
        Transaction storage transaction = batch.transactions[_transactionIndex];
        return (
            transaction.target,
            transaction.value,
            transaction.data,
            transaction.gasLimit,
            transaction.isExecuted,
            transaction.success,
            transaction.returnData
        );
    }

    /**
     * @dev Get user's batches
     * @param _user Address of the user
     * @param _offset Starting index
     * @param _limit Number of batches to return
     * @return Array of batch IDs
     */
    function getUserBatches(
        address _user,
        uint256 _offset,
        uint256 _limit
    ) external view returns (uint256[] memory) {
        uint256[] memory userBatchIds = userBatches[_user];
        uint256 length = userBatchIds.length;
        
        if (_offset >= length) {
            return new uint256[](0);
        }

        uint256 end = _offset + _limit;
        if (end > length) {
            end = length;
        }

        uint256[] memory result = new uint256[](end - _offset);
        for (uint256 i = _offset; i < end; i++) {
            result[i - _offset] = userBatchIds[i];
        }

        return result;
    }

    /**
     * @dev Get gas optimization statistics
     * @param _user Address of the user
     * @return Gas optimization data
     */
    function getGasOptimizationStats(address _user) 
        external 
        view 
        returns (GasOptimization memory) 
    {
        uint256 totalSavings = userGasSavings[_user];
        uint256 userBatchCount = userBatches[_user].length;
        
        // Calculate average savings per batch
        uint256 averageSavings = userBatchCount > 0 ? totalSavings / userBatchCount : 0;
        
        return GasOptimization({
            originalGas: 0, // Would need to track this separately
            optimizedGas: 0, // Would need to track this separately
            savings: totalSavings,
            savingsPercentage: 0 // Would need to calculate based on original vs optimized
        });
    }

    /**
     * @dev Authorize an executor
     * @param _executor Address to authorize
     */
    function authorizeExecutor(address _executor) external onlyOwner {
        authorizedExecutors[_executor] = true;
    }

    /**
     * @dev Revoke executor authorization
     * @param _executor Address to revoke authorization from
     */
    function revokeExecutor(address _executor) external onlyOwner {
        authorizedExecutors[_executor] = false;
    }

    /**
     * @dev Get total batch count
     * @return Total number of batches
     */
    function getTotalBatchCount() external view returns (uint256) {
        return _batchIdCounter.current() - 1;
    }

    /**
     * @dev Withdraw contract balance (only owner)
     */
    function withdraw() external onlyOwner nonReentrant {
        uint256 balance = address(this).balance;
        require(balance > 0, "No balance to withdraw");

        (bool success, ) = payable(owner()).call{value: balance}("");
        require(success, "Withdraw failed");
    }

    /**
     * @dev Emergency function to pause contract (only owner)
     */
    function emergencyPause() external onlyOwner {
        // Implementation would depend on OpenZeppelin's Pausable contract
        // This is a placeholder for emergency functionality
    }
}
