// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";

/**
 * @title DDAttestation
 * @dev On-chain due diligence attestations for pitch scoring
 * @notice Authorized oracles can attest to pitch scores with immutable records
 * @author Axiom Ventures
 */
contract DDAttestation is Ownable {
    
    /// @notice Due diligence attestation structure
    struct Attestation {
        uint8 compositeScore;        // Overall score 0-100
        uint8[6] categoryScores;     // [revenue, codeQuality, onChainHistory, marketPosition, teamQuality, askReasonableness]
        bytes32 reportIPFS;          // IPFS hash of full DD report
        address oracle;              // Oracle that submitted attestation
        uint256 attestedAt;          // Timestamp of attestation
    }
    
    /// @notice Category weights (sum to 100%)
    /// revenue(25%), codeQuality(20%), onChainHistory(20%), marketPosition(15%), teamQuality(10%), askReasonableness(10%)
    
    /// @notice Maximum score value
    uint8 public constant MAX_SCORE = 100;
    
    /// @notice Mapping from oracle address to authorization status
    mapping(address => bool) public authorizedOracles;
    
    /// @notice Mapping from pitch ID to attestation
    mapping(uint256 => Attestation) public attestations;
    
    /// @notice Mapping from pitch ID to whether it has been attested
    mapping(uint256 => bool) public hasAttestation;

    /// @dev Emitted when an attestation is posted
    event AttestationPosted(
        uint256 indexed pitchId,
        uint8 compositeScore,
        address indexed oracle
    );
    
    /// @dev Emitted when an oracle is authorized
    event OracleAdded(address indexed oracle);
    
    /// @dev Emitted when an oracle authorization is revoked
    event OracleRemoved(address indexed oracle);

    /// @dev Only authorized oracles can call this function
    error OracleNotAuthorized();
    
    /// @dev Attestation already exists for this pitch
    error AttestationAlreadyExists();
    
    /// @dev Invalid score provided (must be 0-100)
    error InvalidScore();
    
    /// @dev Empty IPFS hash provided
    error EmptyReportHash();
    
    /// @dev Oracle is already authorized
    error OracleAlreadyAuthorized();
    
    /// @dev Oracle is not currently authorized
    error OracleNotCurrentlyAuthorized();
    
    /// @dev No attestation exists for this pitch
    error NoAttestationFound();

    modifier onlyOracle() {
        if (!authorizedOracles[msg.sender]) revert OracleNotAuthorized();
        _;
    }

    /**
     * @notice Initialize the attestation contract
     * @param initialOwner Address to set as owner (typically multisig)
     */
    constructor(address initialOwner) Ownable(initialOwner) {}

    /**
     * @notice Submit a due diligence attestation for a pitch
     * @param pitchId The pitch ID to attest
     * @param compositeScore Overall score 0-100
     * @param categoryScores Array of 6 category scores [revenue, codeQuality, onChainHistory, marketPosition, teamQuality, askReasonableness]
     * @param reportIPFS IPFS hash of the full DD report
     */
    function attest(
        uint256 pitchId,
        uint8 compositeScore,
        uint8[6] memory categoryScores,
        bytes32 reportIPFS
    ) external onlyOracle {
        if (hasAttestation[pitchId]) revert AttestationAlreadyExists();
        if (compositeScore > MAX_SCORE) revert InvalidScore();
        if (reportIPFS == bytes32(0)) revert EmptyReportHash();

        // Validate all category scores
        for (uint256 i = 0; i < 6; i++) {
            if (categoryScores[i] > MAX_SCORE) revert InvalidScore();
        }

        // Store the attestation
        attestations[pitchId] = Attestation({
            compositeScore: compositeScore,
            categoryScores: categoryScores,
            reportIPFS: reportIPFS,
            oracle: msg.sender,
            attestedAt: block.timestamp
        });
        
        hasAttestation[pitchId] = true;

        emit AttestationPosted(pitchId, compositeScore, msg.sender);
    }

    /**
     * @notice Get full attestation for a pitch
     * @param pitchId The pitch ID to query
     * @return attestation The attestation struct
     */
    function getAttestation(uint256 pitchId) 
        external 
        view 
        returns (Attestation memory attestation) 
    {
        if (!hasAttestation[pitchId]) revert NoAttestationFound();
        return attestations[pitchId];
    }

    /**
     * @notice Check if a pitch has a passing score
     * @param pitchId The pitch ID to check
     * @param minScore Minimum score required for passing
     * @return True if pitch has attestation with score >= minScore
     */
    function hasPassingScore(uint256 pitchId, uint8 minScore) 
        external 
        view 
        returns (bool) 
    {
        if (!hasAttestation[pitchId]) return false;
        return attestations[pitchId].compositeScore >= minScore;
    }

    /**
     * @notice Get just the score for a pitch (convenience function)
     * @param pitchId The pitch ID to query
     * @return score The composite score (0 if no attestation)
     */
    function getScore(uint256 pitchId) external view returns (uint8 score) {
        if (!hasAttestation[pitchId]) return 0;
        return attestations[pitchId].compositeScore;
    }

    /**
     * @notice Get category scores for a pitch
     * @param pitchId The pitch ID to query
     * @return categoryScores Array of 6 category scores
     */
    function getCategoryScores(uint256 pitchId) 
        external 
        view 
        returns (uint8[6] memory categoryScores) 
    {
        if (!hasAttestation[pitchId]) revert NoAttestationFound();
        return attestations[pitchId].categoryScores;
    }

    /**
     * @notice Add an authorized oracle (owner only)
     * @param oracle Address to authorize
     */
    function addOracle(address oracle) external onlyOwner {
        if (authorizedOracles[oracle]) revert OracleAlreadyAuthorized();
        
        authorizedOracles[oracle] = true;
        emit OracleAdded(oracle);
    }

    /**
     * @notice Remove oracle authorization (owner only)
     * @param oracle Address to remove authorization from
     */
    function removeOracle(address oracle) external onlyOwner {
        if (!authorizedOracles[oracle]) revert OracleNotCurrentlyAuthorized();
        
        authorizedOracles[oracle] = false;
        emit OracleRemoved(oracle);
    }

    /**
     * @notice Check if an address is an authorized oracle
     * @param oracle Address to check
     * @return True if oracle is authorized
     */
    function isAuthorizedOracle(address oracle) external view returns (bool) {
        return authorizedOracles[oracle];
    }

    /**
     * @notice Calculate weighted composite score from category scores
     * @param categoryScores Array of 6 category scores
     * @return compositeScore Calculated weighted composite score
     * @dev This is a helper function for oracles to calculate composite scores
     */
    function calculateCompositeScore(uint8[6] memory categoryScores) 
        external 
        pure 
        returns (uint8 compositeScore) 
    {
        uint256 weightedSum = 0;
        uint256[6] memory weights = [uint256(25), uint256(20), uint256(20), uint256(15), uint256(10), uint256(10)];
        
        for (uint256 i = 0; i < 6; i++) {
            if (categoryScores[i] > 100) revert InvalidScore(); // Use literal instead of MAX_SCORE
            weightedSum += uint256(categoryScores[i]) * weights[i];
        }
        
        // Divide by 100 since weights sum to 100%
        uint256 result = weightedSum / 100;
        require(result <= 100, "Result too large");
        return uint8(result);
    }

    /**
     * @notice Get category weight for a specific index
     * @param categoryIndex Index (0-5)
     * @return weight The weight percentage for that category
     */
    function getCategoryWeight(uint256 categoryIndex) 
        external 
        pure 
        returns (uint8 weight) 
    {
        require(categoryIndex < 6, "Invalid category index");
        uint8[6] memory weights = [25, 20, 20, 15, 10, 10];
        return weights[categoryIndex];
    }

    /**
     * @notice Get all category weights
     * @return weights Array of all category weights
     */
    function getAllCategoryWeights() external pure returns (uint8[6] memory weights) {
        return [25, 20, 20, 15, 10, 10];
    }
}