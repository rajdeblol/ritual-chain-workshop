// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PrecompileConsumer} from "./utils/PrecompileConsumer.sol";

/// @title CommitRevealAIJudge
/// @notice AI-judged bounty contract with a commit-reveal submission flow.
///         Participants publish only a hash of their answer during the
///         commit phase. Nobody (not even the bounty owner) can read an
///         answer until its author reveals it after the commit deadline,
///         so late entrants can no longer copy and resubmit an improved
///         version of someone else's idea.
///
/// Lifecycle for each bounty:
///   1. createBounty        -- owner funds the bounty, sets commitDeadline / revealDeadline
///   2. submitCommitment    -- participants post keccak256(answer, salt, sender, bountyId)
///   3. revealAnswer        -- after commitDeadline, participants reveal answer + salt
///   4. judgeAll            -- after revealDeadline, owner sends revealed answers to the
///                              Ritual LLM inference precompile for batch judging
///   5. finalizeWinner      -- owner picks the AI's chosen index, contract pays the winner
contract CommitRevealAIJudge is PrecompileConsumer {
    uint256 public constant MAX_SUBMISSIONS = 10;
    uint256 public constant MAX_ANSWER_LENGTH = 2_000;

    uint256 public nextBountyId = 1;

    struct Submission {
        address submitter;
        string answer;
    }

    struct Bounty {
        address owner;
        string title;
        string rubric;
        uint256 reward;
        uint256 commitDeadline; // submitCommitment allowed while block.timestamp < commitDeadline
        uint256 revealDeadline; // revealAnswer allowed while commitDeadline <= block.timestamp < revealDeadline
        bool judged;
        bool finalized;
        bytes aiReview;
        uint256 winnerIndex;
        uint256 commitCount;
        Submission[] submissions; // only verified, revealed answers land here
        mapping(address => bytes32) commitments;
        mapping(address => bool) hasRevealed;
    }

    struct ConvoHistory {
        string storageType;
        string path;
        string secretsName;
    }

    mapping(uint256 => Bounty) private bounties;

    event BountyCreated(
        uint256 indexed bountyId,
        address indexed owner,
        string title,
        uint256 reward,
        uint256 commitDeadline,
        uint256 revealDeadline
    );

    event CommitmentSubmitted(
        uint256 indexed bountyId,
        address indexed submitter,
        bytes32 commitment
    );

    event AnswerRevealed(
        uint256 indexed bountyId,
        uint256 indexed submissionIndex,
        address indexed submitter
    );

    event AllAnswersJudged(uint256 indexed bountyId, bytes aiReview);

    event WinnerFinalized(
        uint256 indexed bountyId,
        uint256 indexed winnerIndex,
        address indexed winner,
        uint256 reward
    );

    modifier onlyOwner(uint256 bountyId) {
        require(msg.sender == bounties[bountyId].owner, "not bounty owner");
        _;
    }

    modifier bountyExists(uint256 bountyId) {
        require(bounties[bountyId].owner != address(0), "bounty not found");
        _;
    }

    function createBounty(
        string calldata title,
        string calldata rubric,
        uint256 commitDeadline,
        uint256 revealDeadline
    ) external payable returns (uint256 bountyId) {
        require(msg.value > 0, "reward required");
        require(commitDeadline > block.timestamp, "commit deadline in past");
        require(revealDeadline > commitDeadline, "reveal must follow commit");

        bountyId = nextBountyId++;

        Bounty storage bounty = bounties[bountyId];

        bounty.owner = msg.sender;
        bounty.title = title;
        bounty.rubric = rubric;
        bounty.reward = msg.value;
        bounty.commitDeadline = commitDeadline;
        bounty.revealDeadline = revealDeadline;
        bounty.winnerIndex = type(uint256).max;

        emit BountyCreated(
            bountyId,
            msg.sender,
            title,
            msg.value,
            commitDeadline,
            revealDeadline
        );
    }

    /// @notice Phase 1: commit to an answer without revealing it.
    /// @param commitment keccak256(abi.encode(answer, salt, msg.sender, bountyId))
    function submitCommitment(
        uint256 bountyId,
        bytes32 commitment
    ) external bountyExists(bountyId) {
        Bounty storage bounty = bounties[bountyId];

        require(block.timestamp < bounty.commitDeadline, "commit phase over");
        require(commitment != bytes32(0), "empty commitment");
        require(
            bounty.commitments[msg.sender] == bytes32(0),
            "already committed"
        );
        require(
            bounty.commitCount < MAX_SUBMISSIONS,
            "too many commitments"
        );

        bounty.commitments[msg.sender] = commitment;
        bounty.commitCount += 1;

        emit CommitmentSubmitted(bountyId, msg.sender, commitment);
    }

    /// @notice Phase 2: reveal the answer + salt behind an earlier commitment.
    ///         Only added to the judged set if it matches the stored hash.
    function revealAnswer(
        uint256 bountyId,
        string calldata answer,
        bytes32 salt
    ) external bountyExists(bountyId) {
        Bounty storage bounty = bounties[bountyId];

        require(
            block.timestamp >= bounty.commitDeadline,
            "reveal phase not started"
        );
        require(block.timestamp < bounty.revealDeadline, "reveal phase over");
        require(
            bounty.commitments[msg.sender] != bytes32(0),
            "no commitment found"
        );
        require(!bounty.hasRevealed[msg.sender], "already revealed");
        require(bytes(answer).length <= MAX_ANSWER_LENGTH, "answer too long");

        bytes32 expected = keccak256(
            abi.encode(answer, salt, msg.sender, bountyId)
        );
        require(expected == bounty.commitments[msg.sender], "hash mismatch");

        bounty.hasRevealed[msg.sender] = true;
        bounty.submissions.push(
            Submission({submitter: msg.sender, answer: answer})
        );

        emit AnswerRevealed(
            bountyId,
            bounty.submissions.length - 1,
            msg.sender
        );
    }

    /// @notice Phase 3: send all *revealed* answers to the LLM precompile in
    ///         a single batch call. Anyone who never revealed is silently
    ///         excluded -- only verified plaintext reaches the judge.
    function judgeAll(
        uint256 bountyId,
        bytes calldata llmInput
    ) external bountyExists(bountyId) onlyOwner(bountyId) {
        Bounty storage bounty = bounties[bountyId];

        require(
            block.timestamp >= bounty.revealDeadline,
            "reveal phase not over"
        );
        require(!bounty.judged, "already judged");
        require(!bounty.finalized, "already finalized");
        require(bounty.submissions.length > 0, "no revealed submissions");

        bytes memory output = _executePrecompile(
            LLM_INFERENCE_PRECOMPILE,
            llmInput
        );

        (
            bool hasError,
            bytes memory completionData,
            ,
            string memory errorMessage,

        ) = abi.decode(output, (bool, bytes, bytes, string, ConvoHistory));

        require(!hasError, errorMessage);

        bounty.judged = true;
        bounty.aiReview = completionData;

        emit AllAnswersJudged(bountyId, completionData);
    }

    function finalizeWinner(
        uint256 bountyId,
        uint256 winnerIndex
    ) external bountyExists(bountyId) onlyOwner(bountyId) {
        Bounty storage bounty = bounties[bountyId];

        require(bounty.judged, "not judged yet");
        require(!bounty.finalized, "already finalized");
        require(winnerIndex < bounty.submissions.length, "invalid winner index");

        bounty.finalized = true;
        bounty.winnerIndex = winnerIndex;

        address winner = bounty.submissions[winnerIndex].submitter;
        uint256 reward = bounty.reward;
        bounty.reward = 0;

        (bool ok, ) = payable(winner).call{value: reward}("");
        require(ok, "payment failed");

        emit WinnerFinalized(bountyId, winnerIndex, winner, reward);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    /// @notice Core bounty parameters (split from getBountyStatus to avoid
    ///         a "stack too deep" compile error from too many return values).
    function getBounty(
        uint256 bountyId
    )
        external
        view
        bountyExists(bountyId)
        returns (
            address owner,
            string memory title,
            string memory rubric,
            uint256 reward,
            uint256 commitDeadline,
            uint256 revealDeadline
        )
    {
        Bounty storage bounty = bounties[bountyId];

        return (
            bounty.owner,
            bounty.title,
            bounty.rubric,
            bounty.reward,
            bounty.commitDeadline,
            bounty.revealDeadline
        );
    }

    /// @notice Judging/finalization status for a bounty.
    function getBountyStatus(
        uint256 bountyId
    )
        external
        view
        bountyExists(bountyId)
        returns (
            bool judged,
            bool finalized,
            uint256 commitCount,
            uint256 revealedCount,
            uint256 winnerIndex,
            bytes memory aiReview
        )
    {
        Bounty storage bounty = bounties[bountyId];

        return (
            bounty.judged,
            bounty.finalized,
            bounty.commitCount,
            bounty.submissions.length,
            bounty.winnerIndex,
            bounty.aiReview
        );
    }

    function getSubmission(
        uint256 bountyId,
        uint256 index
    )
        external
        view
        bountyExists(bountyId)
        returns (address submitter, string memory answer)
    {
        Bounty storage bounty = bounties[bountyId];

        require(index < bounty.submissions.length, "invalid index");

        Submission storage submission = bounty.submissions[index];

        return (submission.submitter, submission.answer);
    }

    function getCommitment(
        uint256 bountyId,
        address account
    ) external view bountyExists(bountyId) returns (bytes32) {
        return bounties[bountyId].commitments[account];
    }

    function hasRevealed(
        uint256 bountyId,
        address account
    ) external view bountyExists(bountyId) returns (bool) {
        return bounties[bountyId].hasRevealed[account];
    }

    /// @notice Helper so off-chain code (or a frontend) can compute the
    ///         exact commitment hash this contract expects.
    function computeCommitment(
        string calldata answer,
        bytes32 salt,
        address submitter,
        uint256 bountyId
    ) external pure returns (bytes32) {
        return keccak256(abi.encode(answer, salt, submitter, bountyId));
    }
}
